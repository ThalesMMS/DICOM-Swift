#!/usr/bin/env python3
"""Offline, independent FHIR R4 oracle: JSON stdin or argv[1], JSON stdout.

Roles:
  examine  - parse/validate/serialize instances with fhir.resources (R4B models, pydantic v2),
             returning validity, resource type, canonical JSON SHA-256 and XML parse verdicts.
  server   - loopback FHIR REST server (http.server + fhir.resources validation) with create,
             read, vread, history, update (If-Match), delete, conditional create, search
             (_id, identifier, subject/patient, status, code, name[:exact|:contains], date/birthdate
             prefixes, _count paging, _include, _revinclude, _sort, _total), batch/transaction and
             Subscription rest-hook delivery. Ephemeral port published via ready_path.

No imports from the Swift implementation, no network beyond loopback, no narrative or patient
values in stdout: diagnostics carry paths and codes only.
"""
import base64
import hashlib
import importlib.metadata
import ipaddress
import json
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

EXPECTED = {"fhir.resources": "8.3.0", "fhirpathpy": "2.2.4"}


def dependencies():
    found, unavailable = {}, []
    for name, expected in EXPECTED.items():
        try:
            version = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            unavailable.append(name)
            continue
        found[name] = version
        if version != expected:
            unavailable.append(name)
    return found, unavailable


def canonical_hash(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()


def model_for(resource_type):
    from fhir.resources.R4B import get_fhir_model_class
    return get_fhir_model_class(resource_type)


def validate(obj):
    """Returns (valid, [path codes]) without content."""
    from pydantic import ValidationError
    resource_type = obj.get("resourceType") if isinstance(obj, dict) else None
    if not resource_type:
        return False, ["resourceType:missing"]
    try:
        cls = model_for(resource_type)
    except Exception:
        return False, ["resourceType:unknown"]
    try:
        cls.model_validate(obj)
        return True, []
    except ValidationError as error:
        issues = []
        for item in error.errors()[:20]:
            location = ".".join(str(part) for part in item.get("loc", ()))
            issues.append((location or "resource") + ":" + str(item.get("type", "invalid")))
        return False, issues


def examine(item):
    result = {"id": item["id"]}
    raw = base64.b64decode(item["base64"]) if "base64" in item else Path(item["path"]).read_bytes()
    fmt = item.get("format", "json")
    try:
        if fmt == "xml":
            if b"<!DOCTYPE" in raw or b"<!ENTITY" in raw:
                result["refused"] = "dtd"
                return result
            root_match = re.search(rb"<([A-Z][A-Za-z]+)[\s>]", raw)
            resource_type = root_match.group(1).decode() if root_match else None
            if not resource_type:
                result["refused"] = "malformed"
                return result
            model = model_for(resource_type).model_validate_xml(raw)
            obj = json.loads(model.model_dump_json(exclude_none=True))
            result["valid"] = True
        else:
            obj = json.loads(raw.decode("utf-8"))
            valid, issues = validate(obj)
            result["valid"] = valid
            if issues:
                result["issues"] = issues
    except Exception as error:
        result["refused"] = type(error).__name__
        return result
    result["resourceType"] = obj.get("resourceType")
    result["canonicalSHA256"] = canonical_hash(obj)
    if result.get("valid") and item.get("reserialize", True):
        try:
            model = model_for(obj["resourceType"]).model_validate(obj)
            dumped = json.loads(model.model_dump_json(exclude_none=True))
            result["reserializedSHA256"] = canonical_hash(dumped)
            result["reserializedEqualsInput"] = dumped == obj
        except Exception as error:
            result["reserializeError"] = type(error).__name__
    return result


# ---------------------------------------------------------------- server


class Store:
    def __init__(self):
        self.lock = threading.RLock()
        self.resources = {}   # (type, id) -> list of versions [(version, resource dict or None(deleted), timestamp)]
        self.counter = 0

    def new_id(self):
        with self.lock:
            self.counter += 1
            return str(self.counter)

    def current(self, rtype, rid):
        with self.lock:
            versions = self.resources.get((rtype, rid))
            return versions[-1] if versions else (None, None, None)

    def put(self, rtype, rid, resource):
        with self.lock:
            versions = self.resources.setdefault((rtype, rid), [])
            version = str(len(versions) + 1)
            stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
            if resource is not None:
                resource = dict(resource)
                resource["id"] = rid
                meta = dict(resource.get("meta", {}))
                meta["versionId"] = version
                meta["lastUpdated"] = stamp
                resource["meta"] = meta
            versions.append((version, resource, stamp))
            return version, resource, stamp

    def all_current(self, rtype):
        out = []
        with self.lock:
            for (t, rid), versions in self.resources.items():
                if t == rtype and versions[-1][1] is not None:
                    out.append(versions[-1][1])
        return out


STORE = Store()
SUBSCRIPTIONS = {}
SMART = {"codes": {}, "tokens": {}, "refresh": {}, "log": [], "revoked": set()}


def smart_config(behaviors):
    return behaviors.get("smart") or {}


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_id_token(base, config, client_id, nonce, subject="user-1"):
    import hmac
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = {"iss": config.get("issuer_override") or base, "sub": subject, "aud": client_id,
               "exp": int(time.time()) + 3600, "iat": int(time.time()), "fhirUser": base + "/Practitioner/" + subject}
    if nonce:
        payload["nonce"] = nonce
    body = b64url(json.dumps(payload).encode())
    signature = b64url(hmac.new(b"oracle-test-secret", (header + "." + body).encode(), hashlib.sha256).digest())
    return header + "." + body + "." + signature


def patient_matches(resource, patient, base):
    if resource.get("resourceType") == "Patient":
        return resource.get("id") == patient
    references = [resource.get(key, {}).get("reference") for key in ("subject", "patient") if isinstance(resource.get(key), dict)]
    allowed = {"Patient/" + patient, base + "/Patient/" + patient}
    return bool(references) and all(reference in allowed for reference in references)


def scope_allows(scopes, resource_type, action="read", resource=None, patient=None, base=""):
    permission = {"read": "r", "search": "s", "create": "c", "update": "u", "delete": "d"}.get(action)
    for scope in scopes.split():
        scope = scope.split("?", 1)[0]
        if "/" not in scope or "." not in scope:
            continue
        context, rest = scope.split("/", 1)
        rtype, perms = rest.split(".", 1)
        perms = {"read": "rs", "write": "cud", "*": "cruds"}.get(perms, perms)
        if context not in ("patient", "user", "system") or rtype not in ("*", resource_type) or not permission or permission not in perms or not set(perms) <= set("cruds"):
            continue
        if context == "patient" and (not patient or (resource is not None and not patient_matches(resource, patient, base))):
            continue
        return True
    return False


def loopback_origin(url):
    try:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("http", "https") or parsed.username is not None or parsed.password is not None or parsed.fragment:
            return None
        address = ipaddress.ip_address(parsed.hostname or "")
        if not address.is_loopback:
            return None
        port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
        return parsed.scheme, str(address), port
    except ValueError:
        return None


def redirect_allowed(redirect, configured):
    try:
        target, expected = urllib.parse.urlsplit(redirect), urllib.parse.urlsplit(configured)
        if any(url.username is not None or url.password is not None or url.fragment for url in (target, expected)):
            return False
        default_port = {"http": 80, "https": 443}.get(expected.scheme)
        target_port = target.port if target.port is not None else default_port
        expected_port = expected.port if expected.port is not None else default_port
        flexible_loopback_port = expected.port is None and loopback_origin(configured) is not None
        return (bool(expected.scheme) and target.scheme == expected.scheme and target.hostname == expected.hostname
                and (flexible_loopback_port or target_port == expected_port)
                and (not expected.path or target.path == expected.path)
                and (not expected.query or target.query == expected.query))
    except ValueError:
        return False


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def outcome(severity, code, diagnostics, status):
    body = {"resourceType": "OperationOutcome", "issue": [{"severity": severity, "code": code, "diagnostics": diagnostics}]}
    return status, body


def matches_param(resource, name, values):
    """Subset search semantics; returns True when the resource matches any OR value."""
    base, _, modifier = name.partition(":")
    for value in values.split(","):
        if base == "_id":
            if resource.get("id") == value:
                return True
        elif base == "identifier":
            for ident in resource.get("identifier", []):
                system, _, code = value.rpartition("|")
                if ident.get("value") == (code or value) and (not system or ident.get("system") == system):
                    return True
        elif base in ("subject", "patient"):
            ref = resource.get("subject", resource.get("patient", {}))
            target = ref.get("reference", "") if isinstance(ref, dict) else ""
            if target == value or target.endswith("/" + value) or target == "Patient/" + value:
                return True
        elif base == "status":
            if resource.get("status") == value:
                return True
        elif base == "code":
            system, _, code = value.rpartition("|")
            for coding in resource.get("code", {}).get("coding", []):
                if coding.get("code") == (code or value) and (not system or coding.get("system") == system):
                    return True
        elif base in ("name", "family", "given"):
            for human in resource.get("name", []):
                parts = [human.get("family", "")] + human.get("given", []) if base == "name" else \
                    ([human.get("family", "")] if base == "family" else human.get("given", []))
                for part in parts:
                    if modifier == "exact" and part == value:
                        return True
                    if modifier == "contains" and value.lower() in part.lower():
                        return True
                    if not modifier and part.lower().startswith(value.lower()):
                        return True
        elif base in ("birthdate", "date"):
            field = "birthDate" if base == "birthdate" else None
            if field is None:
                for candidate in ("effectiveDateTime", "date", "issued", "started"):
                    if candidate in resource:
                        field = candidate
                        break
            actual = resource.get(field or "", "")
            if not isinstance(actual, str):
                continue
            prefix, number = value[:2], value[2:]
            if prefix not in ("eq", "ne", "gt", "lt", "ge", "le", "sa", "eb", "ap"):
                prefix, number = "eq", value
            comparable = actual[:len(number)]
            if (prefix == "eq" and comparable == number) or (prefix == "ne" and comparable != number) or \
               (prefix in ("gt", "sa") and comparable > number) or (prefix in ("lt", "eb") and comparable < number) or \
               (prefix == "ge" and comparable >= number) or (prefix == "le" and comparable <= number) or prefix == "ap":
                return True
        else:
            return False
    return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    behaviors = {}

    def log_message(self, *args):
        pass

    # -- helpers
    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def send_json(self, status, body, extra=None):
        data = json.dumps(body, separators=(",", ":")).encode("utf-8") if body is not None else b""
        self.send_response(status)
        if data:
            self.send_header("Content-Type", "application/fhir+json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def parse_resource(self):
        raw = self.read_body()
        try:
            obj = json.loads(raw.decode("utf-8"))
        except Exception:
            return None, outcome("error", "structure", "body is not JSON", 400)
        valid, issues = validate(obj)
        if not valid:
            return None, outcome("error", "invalid", "; ".join(issues), 400)
        return obj, self.webhook_error(obj)

    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def webhook_allowed(self, endpoint):
        origin = loopback_origin(endpoint)
        return origin is not None and origin in [loopback_origin(value) for value in self.behaviors.get("webhook_origins", [])]

    def webhook_error(self, resource):
        channel = resource.get("channel", {})
        if resource.get("resourceType") == "Subscription" and channel.get("type") == "rest-hook" and not self.webhook_allowed(channel.get("endpoint", "")):
            return outcome("error", "invalid", "webhook origin is not permitted", 400)
        return None

    def deliver_notifications(self, resource):
        for sid, sub in list(SUBSCRIPTIONS.items()):
            criteria = sub.get("criteria", "")
            rtype = criteria.split("?")[0]
            if rtype != resource.get("resourceType") or sub.get("status") != "active":
                continue
            channel = sub.get("channel", {})
            endpoint = channel.get("endpoint")
            if not endpoint or channel.get("type") != "rest-hook":
                continue
            payload = channel.get("payload")
            body = json.dumps(resource).encode("utf-8") if payload else b""
            headers = {"Content-Type": payload} if payload else {}
            for line in channel.get("header", []):
                key, _, value = line.partition(":")
                headers[key.strip()] = value.strip()
            try:
                if not self.webhook_allowed(endpoint):
                    raise ValueError("webhook origin is not permitted")
                request = urllib.request.Request(endpoint, data=body, method="POST" if payload else "PUT", headers=headers)
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
                with opener.open(request, timeout=5) as reply:
                    reply.read()
            except Exception as error:
                sub["status"] = "error"
                sub["error"] = type(error).__name__

    # -- SMART authorization server (loopback test issuer)
    def smart_authorize(self, query):
        config = smart_config(self.behaviors)
        get = lambda name: query.get(name, [""])[0]
        redirect = get("redirect_uri")
        if get("client_id") != config.get("client_id", "isis-app") or not redirect_allowed(redirect, config.get("redirect_prefix", "http://127.0.0.1")):
            return self.send_json(400, {"error": "invalid_client"})
        if get("response_type") != "code" or get("code_challenge_method") != "S256" or not get("code_challenge") or not get("state"):
            return self.send_json(400, {"error": "invalid_request"})
        if get("aud") and get("aud").rstrip("/") != self.base():
            return self.send_json(400, {"error": "invalid_request", "error_description": "aud"})
        separator = "&" if "?" in redirect else "?"
        if config.get("deny"):
            location = redirect + separator + urllib.parse.urlencode({"error": "access_denied", "state": get("state")})
        else:
            code = b64url(hashlib.sha256(str(time.time()).encode() + get("state").encode()).digest())[:32]
            SMART["codes"][code] = {"challenge": get("code_challenge"), "redirect": redirect, "scope": get("scope"), "nonce": get("nonce"),
                                    "client_id": get("client_id"), "expires": time.time() + 120}
            location = redirect + separator + urllib.parse.urlencode({"code": code, "state": get("state"), "iss": config.get("issuer_override") or self.base()})
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def smart_issue(self, scope, patient, nonce, client_id, config):
        access = b64url(hashlib.sha256(str(time.time_ns()).encode() + b"a").digest())
        refresh = b64url(hashlib.sha256(str(time.time_ns()).encode() + b"r").digest())
        ttl = int(config.get("token_ttl", 3600))
        SMART["tokens"][access] = {"scope": scope, "exp": time.time() + ttl, "patient": patient}
        SMART["refresh"][refresh] = {"scope": scope, "patient": patient, "client_id": client_id}
        body = {"access_token": access, "token_type": "Bearer", "expires_in": ttl, "scope": scope, "refresh_token": refresh, "patient": patient}
        if "openid" in scope.split():
            body["id_token"] = make_id_token(self.base(), config, client_id, nonce)
        return body

    def smart_request_log(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        secret = smart_config(self.behaviors).get("confidential_secret")
        return {"path": parsed.path, "query_keys": sorted(query.keys()),
                "secret_in_query": bool(secret and secret in urllib.parse.unquote_plus(parsed.query))}

    def smart_token(self):
        config = smart_config(self.behaviors)
        if config.get("token_delay"):
            time.sleep(float(config["token_delay"]))
        form = urllib.parse.parse_qs(self.read_body().decode("utf-8"))
        get = lambda name: form.get(name, [""])[0]
        authorization = self.headers.get("Authorization", "")
        SMART["log"].append({**self.smart_request_log(), "grant": get("grant_type"), "basic": authorization.startswith("Basic ")})
        if config.get("confidential_secret"):
            expected = "Basic " + base64.b64encode((config.get("client_id", "isis-app") + ":" + config["confidential_secret"]).encode()).decode()
            if authorization != expected:
                return self.send_json(401, {"error": "invalid_client"})
        if get("grant_type") == "authorization_code":
            record = SMART["codes"].pop(get("code"), None)
            if not record or record["expires"] < time.time() or record["redirect"] != get("redirect_uri") or record["client_id"] != get("client_id"):
                return self.send_json(400, {"error": "invalid_grant", "error_description": "code"})
            verifier = get("code_verifier").encode()
            if b64url(hashlib.sha256(verifier).digest()) != record["challenge"]:
                return self.send_json(400, {"error": "invalid_grant", "error_description": "pkce"})
            granted = config.get("granted_scope") or record["scope"]
            return self.send_json(200, self.smart_issue(granted, config.get("patient", "example"), record["nonce"], record["client_id"], config),
                                  {"Cache-Control": "no-store"})
        if get("grant_type") == "refresh_token":
            record = SMART["refresh"].pop(get("refresh_token"), None)
            if not record or get("refresh_token") in SMART["revoked"]:
                return self.send_json(400, {"error": "invalid_grant", "error_description": "refresh"})
            return self.send_json(200, self.smart_issue(record["scope"], record["patient"], None, record["client_id"], config), {"Cache-Control": "no-store"})
        return self.send_json(400, {"error": "unsupported_grant_type"})

    def smart_revoke(self):
        form = urllib.parse.parse_qs(self.read_body().decode("utf-8"))
        token = form.get("token", [""])[0]
        SMART["log"].append(self.smart_request_log())
        SMART["revoked"].add(token)
        SMART["refresh"].pop(token, None)
        SMART["tokens"].pop(token, None)
        return self.send_json(200, {})

    def smart_denial(self, resource_type, action, resource=None):
        """Return a denial without sending an HTTP response, also usable by Bundle entries."""
        config = smart_config(self.behaviors)
        if not config.get("require_bearer"):
            return None
        authorization = self.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            return outcome("error", "login", "bearer token required", 401)
        token = SMART["tokens"].get(authorization[7:])
        if not token or token["exp"] < time.time() or authorization[7:] in SMART["revoked"]:
            return outcome("error", "expired", "invalid or expired token", 401)
        if resource_type and not scope_allows(token["scope"], resource_type, action, resource, token.get("patient"), self.base()):
            return outcome("error", "forbidden", "insufficient scope", 403)
        return None

    def smart_enforce(self, resource_type, action, resource=None):
        denial = self.smart_denial(resource_type, action, resource)
        if denial:
            self.send_json(*denial, {"WWW-Authenticate": 'Bearer error="%s"' % ("insufficient_scope" if denial[0] == 403 else "invalid_token")})
            return False
        return True

    def visible(self, resource, action="read"):
        return self.smart_denial(resource["resourceType"], action, resource) is None

    # -- routing
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        SMART["log"].append(self.smart_request_log())
        if parts == [".well-known", "smart-configuration"]:
            config = smart_config(self.behaviors)
            issuer = config.get("issuer_override") or self.base()
            document = {"issuer": issuer, "authorization_endpoint": self.base() + "/auth/authorize", "token_endpoint": self.base() + "/auth/token",
                        "revocation_endpoint": self.base() + "/auth/revoke", "capabilities": ["launch-standalone", "launch-ehr", "client-public",
                        "client-confidential-symmetric", "sso-openid-connect", "context-standalone-patient", "permission-patient", "permission-user", "permission-v2"],
                        "code_challenge_methods_supported": ["S256"], "grant_types_supported": ["authorization_code", "refresh_token"],
                        "scopes_supported": ["openid", "fhirUser", "launch", "launch/patient", "offline_access", "patient/*.rs", "user/*.rs"],
                        "token_endpoint_auth_methods_supported": ["client_secret_basic", "none"]}
            if config.get("insecure_endpoints"):
                document["token_endpoint"] = "http://example.test/token"
            return self.send_json(200, document)
        if parts == ["auth", "authorize"]:
            return self.smart_authorize(query)
        if parts == ["auth", "_log"]:
            return self.send_json(200, {"entries": SMART["log"]})
        resource_type = parts[0] if parts and parts[0] != "_history" else None
        if parts and parts[0] != "metadata" and not self.smart_enforce(resource_type, "search" if len(parts) == 1 and parts[0] != "_history" else "read"):
            return
        if self.behaviors.get("delay") and query.get("slow"):
            time.sleep(float(self.behaviors["delay"]))
        if parts == ["metadata"]:
            with STORE.lock:
                types = sorted({t for (t, _) in STORE.resources} | {"Patient", "Observation", "Subscription"})
            statement = {"resourceType": "CapabilityStatement", "status": "active", "date": "2026-09-12", "kind": "instance",
                         "fhirVersion": "4.0.1", "format": ["application/fhir+json"],
                         "rest": [{"mode": "server", "resource": [{"type": t, "interaction": [{"code": c} for c in
                                  ("read", "vread", "update", "delete", "history-instance", "create", "search-type")]} for t in types]}]}
            return self.send_json(200, statement)
        if parts and parts[-1] == "_history":
            return self.history(parts[:-1], query)
        if len(parts) == 4 and parts[2] == "_history":
            rtype, rid, version = parts[0], parts[1], parts[3]
            with STORE.lock:
                versions = list(STORE.resources.get((rtype, rid), []))
            for v, res, stamp in versions:
                if v == version:
                    if res is None:
                        return self.send_json(410, outcome("error", "deleted", "deleted", 410)[1])
                    if not self.smart_enforce(rtype, "read", res):
                        return
                    return self.send_json(200, res, {"ETag": 'W/"%s"' % v, "Last-Modified": stamp})
            return self.send_json(404, outcome("error", "not-found", "unknown version", 404)[1])
        if len(parts) == 2:
            rtype, rid = parts
            version, res, stamp = STORE.current(rtype, rid)
            if version is None:
                return self.send_json(404, outcome("error", "not-found", "unknown resource", 404)[1])
            if res is None:
                return self.send_json(410, outcome("error", "deleted", "resource deleted", 410)[1])
            if not self.smart_enforce(rtype, "read", res):
                return
            etag = 'W/"%s"' % version
            if self.headers.get("If-None-Match") == etag:
                return self.send_json(304, None, {"ETag": etag})
            return self.send_json(200, res, {"ETag": etag, "Last-Modified": stamp})
        if len(parts) == 1:
            return self.search(parts[0], query)
        return self.send_json(404, outcome("error", "not-found", "unknown path", 404)[1])

    def history(self, parts, query):
        entries = []
        with STORE.lock:
            snapshot = [(key, list(versions)) for key, versions in STORE.resources.items()]
        for (t, rid), versions in snapshot:
            if parts and t != parts[0]:
                continue
            if len(parts) == 2 and rid != parts[1]:
                continue
            last_resource = None
            if len(parts) == 2:
                current = next((res for _, res, _ in reversed(versions) if res is not None), None)
                if current is not None and not self.smart_enforce(t, "read", current):
                    return
            for v, res, stamp in versions:
                if res is not None:
                    last_resource = res
                if last_resource is None or not self.visible(last_resource):
                    continue
                entry = {"fullUrl": "%s/%s/%s" % (self.base(), t, rid),
                         "request": {"method": "DELETE" if res is None else ("POST" if v == "1" else "PUT"), "url": "%s/%s" % (t, rid)},
                         "response": {"status": "204" if res is None else ("201" if v == "1" else "200"), "etag": 'W/"%s"' % v, "lastModified": stamp}}
                if res is not None:
                    entry["resource"] = res
                entries.append(entry)
        count = int(query.get("_count", ["100"])[0])
        return self.send_json(200, {"resourceType": "Bundle", "type": "history", "total": len(entries), "entry": entries[:count]})

    def search(self, rtype, query, post_body=None):
        params = dict(query)
        if post_body:
            params.update(urllib.parse.parse_qs(post_body, keep_blank_values=True))
        count = int(params.pop("_count", ["20"])[0])
        page = int(params.pop("page", ["1"])[0])
        includes = params.pop("_include", [])
        revincludes = params.pop("_revinclude", [])
        sort = params.pop("_sort", [None])[0]
        total_mode = params.pop("_total", ["accurate"])[0]
        params.pop("_format", None)
        params.pop("slow", None)
        results = [r for r in STORE.all_current(rtype) if self.visible(r, "search")]
        for name, values in params.items():
            if name.startswith("_has:"):
                _, source_type, ref_param, param = name.split(":", 3)
                referencing = [r for r in STORE.all_current(source_type) if self.visible(r, "search") and matches_param(r, param, values[0])]
                targets = {r.get(ref_param, {}).get("reference") for r in referencing if isinstance(r.get(ref_param), dict)}
                results = [r for r in results if "%s/%s" % (rtype, r.get("id")) in targets]
                continue
            if "." in name:
                head, chain = name.split(".", 1)
                base_param, _, target_type = head.partition(":")
                filtered = []
                for r in results:
                    ref = r.get(base_param, {})
                    reference = ref.get("reference", "") if isinstance(ref, dict) else ""
                    t, _, rid = reference.partition("/")
                    if target_type and t != target_type:
                        continue
                    _, target, _ = STORE.current(t, rid)
                    if target and self.visible(target) and matches_param(target, chain, values[0]):
                        filtered.append(r)
                results = filtered
                continue
            for value in values:
                results = [r for r in results if matches_param(r, name, value)]
        if sort:
            key = sort.lstrip("-")
            results.sort(key=lambda r: json.dumps(r.get(key, ""), sort_keys=True), reverse=sort.startswith("-"))
        total = len(results)
        start = (page - 1) * count
        page_items = results[start:start + count]
        entries = [{"fullUrl": "%s/%s/%s" % (self.base(), rtype, r["id"]), "resource": r, "search": {"mode": "match"}} for r in page_items]
        included = []
        for spec in includes:
            _, _, param = spec.split(":")[:3] if spec.count(":") >= 2 else (None, None, spec.split(":")[-1])
            for r in page_items:
                ref = r.get(param, {})
                reference = ref.get("reference", "") if isinstance(ref, dict) else ""
                t, _, rid = reference.partition("/")
                _, target, _ = STORE.current(t, rid)
                if target and self.visible(target) and target not in included:
                    included.append(target)
        for spec in revincludes:
            source_type, param = spec.split(":")[0], spec.split(":")[1]
            wanted = {"%s/%s" % (rtype, r["id"]) for r in page_items}
            for r in STORE.all_current(source_type):
                ref = r.get(param, {})
                reference = ref.get("reference", "") if isinstance(ref, dict) else ""
                if reference in wanted and self.visible(r) and r not in included:
                    included.append(r)
        entries += [{"fullUrl": "%s/%s/%s" % (self.base(), r["resourceType"], r["id"]), "resource": r, "search": {"mode": "include"}} for r in included]
        bundle = {"resourceType": "Bundle", "type": "searchset", "entry": entries, "link": [{"relation": "self", "url": self.base() + self.path}]}
        if total_mode != "none":
            bundle["total"] = total
        if start + count < total:
            next_query = urllib.parse.urlencode([(k, v) for k, vs in query.items() for v in vs if k != "page"] + [("page", str(page + 1)), ("_count", str(count))], doseq=False)
            bundle["link"].append({"relation": "next", "url": "%s/%s?%s" % (self.base(), rtype, next_query)})
        return self.send_json(200, bundle)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        if parts == ["auth", "token"]:
            return self.smart_token()
        if parts == ["auth", "revoke"]:
            return self.smart_revoke()
        if not self.smart_enforce(parts[0] if parts else None, "search" if parts and parts[-1] == "_search" else "create"):
            return
        if not parts:
            return self.bundle_request()
        if len(parts) == 2 and parts[1] == "_search":
            return self.search(parts[0], urllib.parse.parse_qs(parsed.query, keep_blank_values=True), self.read_body().decode("utf-8"))
        if len(parts) == 1:
            obj, error = self.parse_resource()
            if error:
                return self.send_json(error[0], error[1])
            if obj.get("resourceType") != parts[0]:
                return self.send_json(400, outcome("error", "invalid", "type mismatch", 400)[1])
            if not self.smart_enforce(parts[0], "create", obj):
                return
            if self.headers.get("If-None-Exist"):
                existing = self.conditional_matches(parts[0], self.headers["If-None-Exist"])
                if len(existing) == 1:
                    version, res, stamp = STORE.current(parts[0], existing[0]["id"])
                    return self.send_json(200, res, {"ETag": 'W/"%s"' % version, "Location": "%s/%s/%s/_history/%s" % (self.base(), parts[0], res["id"], version)})
                if len(existing) > 1:
                    return self.send_json(412, outcome("error", "multiple-matches", "multiple matches", 412)[1])
            with STORE.lock:
                candidate = dict(obj, id=str(STORE.counter + 1))
                if not self.smart_enforce(parts[0], "create", candidate):
                    return
                rid = STORE.new_id()
                version, res, stamp = STORE.put(parts[0], rid, obj)
            if parts[0] == "Subscription":
                res["status"] = "active"
                SUBSCRIPTIONS[rid] = res
            self.send_json(201, res if self.headers.get("Prefer", "return=representation") != "return=minimal" else None,
                           {"ETag": 'W/"%s"' % version, "Location": "%s/%s/%s/_history/%s" % (self.base(), parts[0], rid, version), "Last-Modified": stamp})
            threading.Thread(target=self.deliver_notifications, args=(res,), daemon=True).start()
            return
        return self.send_json(404, outcome("error", "not-found", "unknown path", 404)[1])

    def conditional_matches(self, rtype, criteria):
        params = urllib.parse.parse_qs(criteria)
        results = [r for r in STORE.all_current(rtype) if self.visible(r, "create")]
        for name, values in params.items():
            for value in values:
                results = [r for r in results if matches_param(r, name, value)]
        return results

    def do_PUT(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if not self.smart_enforce(parts[0] if parts else None, "update"):
            return
        if len(parts) != 2:
            return self.send_json(400, outcome("error", "invalid", "PUT needs Type/id", 400)[1])
        obj, error = self.parse_resource()
        if error:
            return self.send_json(error[0], error[1])
        if obj.get("id") != parts[1] or obj.get("resourceType") != parts[0]:
            return self.send_json(400, outcome("error", "invalid", "id/type mismatch", 400)[1])
        with STORE.lock:
            version, current, _ = STORE.current(parts[0], parts[1])
            if not self.smart_enforce(parts[0], "update", obj) or (current is not None and not self.smart_enforce(parts[0], "update", current)):
                return
            if_match = self.headers.get("If-Match")
            if if_match and version and if_match != 'W/"%s"' % version:
                return self.send_json(412, outcome("error", "conflict", "version mismatch", 412)[1])
            if if_match and version is None:
                return self.send_json(412, outcome("error", "conflict", "no version to match", 412)[1])
            new_version, res, stamp = STORE.put(parts[0], parts[1], obj)
        status = 201 if version is None else 200
        self.send_json(status, res, {"ETag": 'W/"%s"' % new_version, "Location": "%s/%s/%s/_history/%s" % (self.base(), parts[0], parts[1], new_version), "Last-Modified": stamp})
        threading.Thread(target=self.deliver_notifications, args=(res,), daemon=True).start()

    def do_DELETE(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if not self.smart_enforce(parts[0] if parts else None, "delete"):
            return
        if len(parts) != 2:
            return self.send_json(400, outcome("error", "invalid", "DELETE needs Type/id", 400)[1])
        with STORE.lock:
            version, current, _ = STORE.current(parts[0], parts[1])
            if version is not None and current is not None:
                if not self.smart_enforce(parts[0], "delete", current):
                    return
                STORE.put(parts[0], parts[1], None)
        SUBSCRIPTIONS.pop(parts[1], None) if parts[0] == "Subscription" else None
        return self.send_json(204, None)

    def bundle_request(self):
        # The envelope is checked structurally; entries are validated per interaction semantics
        # (all-or-nothing for transactions, per entry for batches).
        try:
            obj = json.loads(self.read_body().decode("utf-8"))
        except Exception:
            return self.send_json(400, outcome("error", "structure", "body is not JSON", 400)[1])
        if not isinstance(obj, dict) or obj.get("resourceType") != "Bundle":
            return self.send_json(400, outcome("error", "invalid", "not a Bundle", 400)[1])
        kind = obj.get("type")
        if kind not in ("batch", "transaction"):
            return self.send_json(400, outcome("error", "invalid", "bundle type", 400)[1])
        entries = obj.get("entry", [])
        if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
            return self.send_json(400, outcome("error", "invalid", "invalid entries", 400)[1])
        if kind == "transaction":
            # Stage under the shared lock; readers and writers see only the committed state.
            with STORE.lock:
                staged = Store()
                staged.resources = {key: list(versions) for key, versions in STORE.resources.items()}
                staged.counter = STORE.counter
                mapping = {}
                for entry in entries:
                    request, resource = entry.get("request", {}), entry.get("resource", {})
                    if (isinstance(request, dict) and request.get("method") == "POST" and isinstance(resource, dict)
                            and resource.get("resourceType") and isinstance(entry.get("fullUrl"), str) and entry["fullUrl"].startswith("urn:uuid:")):
                        mapping[entry["fullUrl"]] = "%s/%s" % (resource["resourceType"], staged.new_id())
                response_entries = []
                for entry in entries:
                    if "resource" in entry:
                        text = json.dumps(entry["resource"])
                        for urn, target in mapping.items():
                            text = text.replace(urn, target)
                        entry["resource"] = json.loads(text)
                    response = self.bundle_entry(entry, staged, mapping)
                    if int(response["response"]["status"].split()[0]) >= 400:
                        return self.send_json(int(response["response"]["status"].split()[0]), response["response"]["outcome"])
                    response_entries.append(response)
                STORE.resources, STORE.counter = staged.resources, staged.counter
        else:
            response_entries = []
            for entry in entries:
                with STORE.lock:
                    response_entries.append(self.bundle_entry(entry, STORE, {}))
        return self.send_json(200, {"resourceType": "Bundle", "type": kind + "-response", "entry": response_entries})

    def bundle_entry(self, entry, store, mapping):
        def failed(status, detail):
            return {"response": {"status": str(status), "outcome": outcome("error", "forbidden" if status == 403 else "invalid", detail, status)[1]}}

        request = entry.get("request", {})
        if not isinstance(request, dict) or not isinstance(request.get("url"), str):
            return failed(400, "invalid request")
        method = request.get("method")
        if not isinstance(method, str) or not isinstance(entry.get("fullUrl", ""), str):
            return failed(400, "invalid request")
        action = {"GET": "read", "POST": "create", "PUT": "update", "DELETE": "delete"}.get(method)
        try:
            url = urllib.parse.urlsplit(request["url"])
        except ValueError:
            return failed(400, "invalid request URL")
        pieces = url.path.split("/")
        if (not action or url.scheme or url.netloc or url.query or url.fragment or not all(pieces)
                or len(pieces) != (1 if method == "POST" else 2)):
            return failed(400, "unsupported interaction")
        rtype = pieces[0]
        denial = self.smart_denial(rtype, action)
        if denial:
            return {"response": {"status": str(denial[0]), "outcome": denial[1]}}
        resource = entry.get("resource")
        if method in ("POST", "PUT"):
            if not validate(resource)[0] or resource.get("resourceType") != rtype:
                return failed(400, "invalid resource or type mismatch")
            if method == "PUT" and resource.get("id") != pieces[1]:
                return failed(400, "id mismatch")
            error = self.webhook_error(resource)
            if error:
                return failed(error[0], "webhook origin is not permitted")
        target = mapping.get(entry.get("fullUrl", ""))
        rid = (target.split("/")[1] if target else str(store.counter + 1)) if method == "POST" else pieces[1]
        version, current, stamp = store.current(rtype, rid)
        if current is not None and method != "POST" and not self.visible(current, action):
            return failed(403, "insufficient scope")
        if method in ("POST", "PUT"):
            resource = dict(resource, id=rid)
            if not self.visible(resource, action):
                return failed(403, "insufficient scope")
            if request.get("ifMatch") and request["ifMatch"] != 'W/"%s"' % version:
                return failed(412, "version mismatch")
            if method == "POST" and not target:
                store.new_id()
            version, resource, stamp = store.put(rtype, rid, resource)
            return {"response": {"status": "201 Created" if method == "POST" else "200 OK",
                                 "location": "%s/%s/_history/%s" % (rtype, rid, version), "etag": 'W/"%s"' % version}, "resource": resource}
        if method == "GET":
            if current is None:
                return failed(404, "unknown resource")
            return {"response": {"status": "200 OK", "etag": 'W/"%s"' % version}, "resource": current}
        if current is not None:
            store.put(rtype, rid, None)
        return {"response": {"status": "204 No Content"}}


def run_server(request):
    Handler.behaviors = request.get("behaviors", {})
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    port = server.server_address[1]
    lifetime = min(float(request.get("lifetime", 60)), 600)
    if request.get("ready_path"):
        temp = Path(request["ready_path"] + ".tmp")
        temp.write_text(json.dumps({"ready": True, "port": port, "base": "http://127.0.0.1:%d" % port}))
        temp.replace(request["ready_path"])
    print(json.dumps({"ready": True, "port": port}), flush=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    thread.join(lifetime)
    server.shutdown()


def fhirpath(request):
    """Evaluates expressions with fhirpathpy on each document; results are JSON-serialized collections."""
    from fhirpathpy import evaluate
    from fhirpathpy.models import models
    model = models["r4"]
    output = {"documents": []}
    for item in request.get("documents", []):
        raw = base64.b64decode(item["base64"]) if "base64" in item else Path(item["path"]).read_bytes()
        resource = json.loads(raw.decode("utf-8"))
        entry = {"id": item["id"], "results": {}}
        for expression in request.get("expressions", []):
            try:
                value = evaluate(resource, expression, {}, model)
                entry["results"][expression] = {"value": value}
            except Exception as error:
                entry["results"][expression] = {"error": type(error).__name__}
        output["documents"].append(entry)
    return output


def main():
    request = json.loads(sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read())
    found, unavailable = dependencies()
    if request.get("role") == "fhirpath":
        output = fhirpath(request) if not unavailable else {}
        output.update({"ready": not unavailable, "dependencies": found, "unavailable": unavailable})
        print(json.dumps(output))
        return
    if request.get("role") == "server":
        if unavailable:
            print(json.dumps({"ready": False, "unavailable": unavailable}))
            return
        return run_server(request)
    output = {"ready": not unavailable, "dependencies": found, "unavailable": unavailable, "documents": []}
    if output["ready"]:
        for item in request.get("documents", []):
            output["documents"].append(examine(item))
    if request.get("result_path"):
        temp = Path(request["result_path"] + ".tmp")
        temp.write_text(json.dumps(output))
        temp.replace(request["result_path"])
    print(json.dumps(output))


if __name__ == "__main__":
    main()
