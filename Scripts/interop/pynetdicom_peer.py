#!/usr/bin/env python3
"""Independent pynetdicom peer. No patches to pynetdicom negotiation or dispatch.

One JSON configuration on stdin (or as argv[1]); stdout contains JSON readiness/result.
Optional ready_path/result_path allow a bounded Swift launcher without pipe blocking.
"""
import json
import hashlib
import signal
import sys
import threading
import time
from pathlib import Path

import pydicom
import pynetdicom
from pydicom.dataset import Dataset, FileMetaDataset
from pynetdicom import AE, evt, build_role
from pynetdicom.pdu_primitives import AsynchronousOperationsWindowNegotiation, SOPClassExtendedNegotiation
from pynetdicom.sop_class import (
    Verification, SecondaryCaptureImageStorage, StudyRootQueryRetrieveInformationModelFind,
    StudyRootQueryRetrieveInformationModelGet, StudyRootQueryRetrieveInformationModelMove,
    PatientRootQueryRetrieveInformationModelFind, PatientRootQueryRetrieveInformationModelGet,
    PatientRootQueryRetrieveInformationModelMove, ModalityWorklistInformationFind,
    ModalityPerformedProcedureStep, StorageCommitmentPushModel,
)

cfg = json.loads(sys.argv[1] if len(sys.argv) > 1 else sys.stdin.readline())
stats = {"pynetdicom": pynetdicom.__version__, "pydicom": pydicom.__version__,
         "stores": [], "commands": [], "async_proposals": [], "max_outstanding": 0, "outstanding": 0,
         "cancelled": False, "rq_items": [], "responses": [], "release_requests": 0}
lock = threading.Lock()
stop = threading.Event()
syntaxes = cfg.get("syntaxes", ["1.2.840.10008.1.2.1", "1.2.840.10008.1.2"])


def scu_tls_context(config):
    import ssl
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(config["tls_ca_file"])
    context.check_hostname = True
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    if config.get("tls_cert_file") and config.get("tls_key_file"):
        context.load_cert_chain(config["tls_cert_file"], config["tls_key_file"])
    return context


def dataset(values):
    ds = Dataset()
    for key, value in values.items():
        if key.endswith("Sequence") and isinstance(value, list):
            value = [dataset(item) if isinstance(item, dict) else item for item in value]
        setattr(ds, key, value)
    return ds


def instances():
    if cfg.get("instances"):
        objects = []
        for values in cfg["instances"]:
            ds = dataset({key: value for key, value in values.items() if key != "pixel_data_hex"})
            if "pixel_data_hex" in values:
                ds.PixelData = bytes.fromhex(values["pixel_data_hex"])
            ds.file_meta = FileMetaDataset()
            ds.file_meta.TransferSyntaxUID = syntaxes[0]
            objects.append(ds)
        return objects
    if cfg.get("files"):
        return [pydicom.dcmread(path) for path in cfg["files"]]
    ds = dataset({"SOPClassUID": str(SecondaryCaptureImageStorage), "SOPInstanceUID": "2.25.2350001",
                  "PatientName": "SYNTHETIC^A1", "PatientID": "A1", "StudyInstanceUID": "2.25.2350",
                  "SeriesInstanceUID": "2.25.23501", "Rows": 1, "Columns": 2048,
                  "SamplesPerPixel": 1, "PhotometricInterpretation": "MONOCHROME2",
                  "BitsAllocated": 8, "BitsStored": 8, "HighBit": 7, "PixelRepresentation": 0})
    ds.PixelData = bytes(2048)
    ds.file_meta = FileMetaDataset()
    ds.file_meta.TransferSyntaxUID = syntaxes[0]
    return [ds]


def dimse_received(event):
    command = event.message.command_set
    field = int(command.CommandField)
    with lock:
        stats["commands"].append({"field": field, "id": int(command.get("MessageID", 0))})
        if field & 0x8000 == 0 and field != 0x0FFF:
            stats["outstanding"] += 1
            stats["max_outstanding"] = max(stats["max_outstanding"], stats["outstanding"])


def dimse_sent(event):
    command = event.message.command_set
    if int(command.CommandField) & 0x8000:
        stats["responses"].append({"field": int(command.CommandField), "status": int(command.get("Status", 0)),
                                   "failed": int(command.get("NumberOfFailedSuboperations", 0)),
                                   "completed": int(command.get("NumberOfCompletedSuboperations", 0))})
    if cfg.get("wrong_response_id") and int(command.CommandField) & 0x8000:
        command.MessageIDBeingRespondedTo = cfg["wrong_response_id"]
    if int(command.CommandField) & 0x8000 and int(command.get("Status", 0)) not in (0xFF00, 0xFF01):
        with lock:
            stats["outstanding"] -= 1


def pdu_received(event):
    if event.pdu.pdu_type == 0x07:
        stats["abort_received"] = True
    if event.pdu.pdu_type == 0x05:
        stats["release_requests"] += 1
    if event.pdu.__class__.__name__ == "A_ASSOCIATE_RQ":
        for item in event.pdu.user_information.user_data:
            stats["rq_items"].append(int(item.item_type))
            if int(item.item_type) == 0x53:
                stats["async_proposals"].append([item.maximum_number_operations_invoked,
                                                 item.maximum_number_operations_performed])


def commitment_report(event):
    stats.setdefault("commitment_reports", []).append(str(event.event_information.TransactionUID))
    return 0, None


def echo(event):
    time.sleep(cfg.get("echo_delay", 0))
    return 0


def store(event):
    ds = event.dataset
    stats["stores"].append({"uid": str(ds.SOPInstanceUID), "syntax": str(event.context.transfer_syntax),
                            "pixel_bytes": len(ds.get("PixelData", b"")),
                            "sha256": hashlib.sha256(event.request.DataSet.getvalue()).hexdigest()})
    time.sleep(cfg.get("store_delay", 0))
    return 0xA700 if str(ds.SOPInstanceUID) == cfg.get("fail_store_uid") else 0


def find(event):
    for index in range(cfg.get("pending_count", 3)):
        time.sleep(cfg.get("pending_delay", 0.03))
        if event.is_cancelled and not cfg.get("ignore_cancel", False):
            stats["cancelled"] = True
            yield 0xFE00, None
            return
        rows = cfg.get("datasets", [{"PatientID": "A1", "PatientName": "SYNTHETIC^A1",
                                     "StudyInstanceUID": "2.25.2350", "QueryRetrieveLevel": "STUDY"}])
        yield 0xFF00, dataset(rows[index % len(rows)])
    yield 0, None


def get(event):
    objects = instances()
    yield len(objects)
    for ds in objects:
        if event.is_cancelled and not cfg.get("ignore_cancel", False):
            stats["cancelled"] = True
            yield 0xFE00, None
            return
        yield 0xFF00, ds


def move(event):
    yield cfg.get("move_host", "127.0.0.1"), cfg.get("move_port", 11113)
    yield from get(event)


def identity(event):
    accepted = event.primary_field == cfg.get("identity_primary", "operator").encode()
    if event.user_id_type == 2:
        accepted = accepted and event.secondary_field == cfg.get("identity_secondary", "secret").encode()
    return accepted, cfg.get("identity_response", "accepted").encode() if accepted else None


def extended(event):
    supported = cfg.get("extended_flags", [1, 0, 0, 0, 0])
    return {uid: bytes(1 if value == 1 and i < len(supported) and supported[i] == 1 else 0
                       for i, value in enumerate(values)) for uid, values in event.app_info.items()}


def action(event):
    info = event.action_information
    if cfg.get("commitment_port"):
        def report():
            time.sleep(cfg.get("commitment_delay", 0.1))
            ae = AE(ae_title=cfg.get("aet", "PYNETDICOM"))
            ae.add_requested_context(StorageCommitmentPushModel)
            assoc = ae.associate("127.0.0.1", cfg["commitment_port"], ae_title=cfg.get("commitment_aet", "ISIS"),
                                 ext_neg=[build_role(StorageCommitmentPushModel, scu_role=False, scp_role=True)])
            if assoc.is_established:
                result = Dataset()
                result.TransactionUID = info.TransactionUID
                successful, failed = [], []
                for reference in info.ReferencedSOPSequence:
                    if str(reference.ReferencedSOPInstanceUID) == cfg.get("fail_commitment_uid"):
                        reference.FailureReason = 0x0112
                        failed.append(reference)
                    else:
                        successful.append(reference)
                result.ReferencedSOPSequence = successful
                if failed:
                    result.FailedSOPSequence = failed
                status, _ = assoc.send_n_event_report(result, 2 if failed else 1, StorageCommitmentPushModel, "1.2.840.10008.1.20.1.1")
                stats["commitment_status"] = int(status.Status) if status else None
                assoc.release()
        threading.Thread(target=report, daemon=True).start()
    return 0, None


# Independent UPS implementation. This state is never shared with the Swift engine.
UPS_PUSH, UPS_WATCH, UPS_PULL, UPS_EVENT, UPS_QUERY = [
    "1.2.840.10008.5.1.4.34.6." + str(i) for i in range(1, 6)]
IAN = "1.2.840.10008.5.1.4.33"
ups_objects = {}


def ups_create(event):
    from copy import deepcopy
    sop = str(event.request.AffectedSOPClassUID)
    if sop == IAN:
        stats.setdefault("ian", []).append(event.attribute_list.to_json_dict())
        return 0, None
    if sop != UPS_PUSH:
        return 0, None
    uid = str(event.request.AffectedSOPInstanceUID)
    ds = event.attribute_list
    with lock:
        if uid in ups_objects:
            return 0x0111, None
        if ds.get("ProcedureStepState") != "SCHEDULED":
            return 0xC309, None
        if ds.get("TransactionUID", ""):
            return 0x0106, None
        stored = deepcopy(ds)
        stored.SOPClassUID, stored.SOPInstanceUID = UPS_PUSH, uid
        stored.ScheduledProcedureStepModificationDateTime = "20260911090000"
        stored.WorklistLabel = stored.get("WorklistLabel") or "PYTHON"
        ups_objects[uid] = stored
    return 0, None


def ups_set(event):
    from copy import deepcopy
    if str(event.request.RequestedSOPClassUID) != UPS_PUSH:
        return 0, None
    with lock:
        ds = ups_objects.get(str(event.request.RequestedSOPInstanceUID))
        if ds is None:
            return 0xC307, None
        changes = event.modification_list
        if ds.ProcedureStepState in ("COMPLETED", "CANCELED"):
            return 0xC300, None
        if ds.ProcedureStepState == "IN PROGRESS" and changes.get("TransactionUID") != ds.get("TransactionUID"):
            return 0xC301, None
        if ds.ProcedureStepState == "SCHEDULED" and "TransactionUID" in changes:
            return 0xC301, None
        if "ProcedureStepState" in changes:
            return 0xC303, None
        for element in changes:
            if element.keyword != "TransactionUID":
                ds[element.tag] = deepcopy(element)
        ds.ScheduledProcedureStepModificationDateTime = "20260911100000"
    return 0, None


def ups_get(event):
    from copy import deepcopy
    with lock:
        ds = ups_objects.get(str(event.request.RequestedSOPInstanceUID))
        if ds is None:
            return 0xC307, None
        selection = event.attribute_identifiers
        result = Dataset()
        for element in ds:
            if element.keyword not in ("TransactionUID", "SOPClassUID", "SOPInstanceUID") and (
                    not selection or element.tag in selection):
                result[element.tag] = deepcopy(element)
    return 0, result


def ups_find(event):
    import fnmatch
    from copy import deepcopy
    with lock:
        records = deepcopy(list(ups_objects.values()))
    query = event.identifier
    if not any(element.value for element in query):
        yield 0, None
        return
    for ds in records:
        if event.is_cancelled:
            yield 0xFE00, None
            return
        if all(not element.value or fnmatch.fnmatchcase(str(ds.get(element.tag, "").value
               if element.tag in ds else ""), str(element.value)) for element in query):
            result = Dataset()
            for element in query:
                if element.keyword != "TransactionUID":
                    result[element.tag] = deepcopy(ds[element.tag] if element.tag in ds else element)
            yield 0xFF00, result
    yield 0, None


def ups_action(event):
    if str(event.request.RequestedSOPClassUID) != UPS_PUSH:
        return action(event)
    with lock:
        ds = ups_objects.get(str(event.request.RequestedSOPInstanceUID))
        if ds is None:
            return 0xC307, None
        info = event.action_information
        current = ds.ProcedureStepState
        if event.action_type == 2:
            if current == "COMPLETED":
                return 0xC311, None
            if current == "CANCELED":
                return 0xB304, None
            if current == "SCHEDULED":
                ds.ProcedureStepState = "CANCELED"
            return 0, None
        if event.action_type != 1:
            return 0x0211, None
        target = info.get("ProcedureStepState")
        if target == "SCHEDULED":
            return 0xC303, None
        transaction = info.get("TransactionUID")
        if not transaction or (ds.get("TransactionUID") and ds.TransactionUID != transaction):
            return 0xC301, None
        if current == "SCHEDULED" and target != "IN PROGRESS":
            return 0xC310, None
        if current == "IN PROGRESS" and target == "IN PROGRESS":
            return 0xC302, None
        if current in ("COMPLETED", "CANCELED"):
            return (0xB306 if current == "COMPLETED" else 0xB304) if current == target else 0xC300, None
        if target == "COMPLETED":
            performed = ds.get("UnifiedProcedureStepPerformedProcedureSequence", [])
            if not performed or any(not item.get(key) for item in performed for key in (
                    "PerformedStationNameCodeSequence", "PerformedProcedureStepStartDateTime",
                    "PerformedWorkitemCodeSequence", "PerformedProcedureStepEndDateTime")):
                return 0xC304, None
            if any("OutputInformationSequence" not in item for item in performed):
                return 0xC304, None
        ds.TransactionUID, ds.ProcedureStepState = transaction, target
    return 0, None


def ups_notification(event):
    stats.setdefault("events", []).append({"type": int(event.event_type),
        "state": str(event.event_information.get("ProcedureStepState", ""))})
    return cfg.get("ups_event_status", 0), None


def ups_step(assoc, step):
    operation = step["operation"]
    if cfg.get("ups_debug"):
        print("UPS step", operation, step.get("action"), flush=True)
    uid = step.get("uid", "2.25.2352")
    ds = dataset(step.get("attributes", {}))
    context = step.get("context", UPS_PULL)
    if operation == "ups_create":
        responses = [assoc.send_n_create(ds, UPS_PUSH, uid)]
    elif operation == "ian_create":
        responses = [assoc.send_n_create(ds, IAN, uid)]
    elif operation == "ups_get":
        responses = [assoc.send_n_get(step.get("attribute_ids", []), UPS_PUSH, uid, meta_uid=context)]
    elif operation == "ups_set":
        responses = [assoc.send_n_set(ds, UPS_PUSH, uid, meta_uid=context)]
    elif operation == "ups_action":
        responses = [assoc.send_n_action(ds if len(ds) else None, step.get("action", 1), UPS_PUSH, uid, meta_uid=context)]
    elif operation == "ups_find":
        responses = assoc.send_c_find(ds, context)
    else:
        raise ValueError(operation)
    for status, result in responses:
        if cfg.get("ups_debug"):
            print("UPS response", status, flush=True)
        stats.setdefault("statuses", []).append(int(status.Status) if status else -1)
        stats.setdefault("ups_results", []).append(result.to_json_dict() if result is not None else None)


def emit(result, path=None):
    text = json.dumps(result)
    if path:
        destination = Path(path)
        temporary = destination.with_suffix(destination.suffix + ".tmp")
        temporary.write_text(text)
        temporary.replace(destination)
    print(text, flush=True)


# Print model is deliberately independent of DICOM-Swift's implementation.
PRINT_ROOT = "1.2.840.10008.5.1.1."
PS, PB, GI, CI, PJ, PA, PR, PC, PL = [PRINT_ROOT + suffix for suffix in
                                     ("1", "2", "4", "4.1", "14", "15", "16", "16.376", "23")]
GM, CM = PRINT_ROOT + "9", PRINT_ROOT + "18"
print_cfg = cfg.get("print", {})
print_objects = {}
print_counter = 0
stats["films"] = []
stats["print_sessions"] = []
stats["job_events"] = []
stats["print_operations"] = []
stats["print_order"] = []


def print_uid():
    global print_counter
    print_counter += 1
    return "2.25.235300000" + str(print_counter)


def print_ref(sop, uid):
    return dataset({"ReferencedSOPClassUID": sop, "ReferencedSOPInstanceUID": uid})


def print_layout(value):
    parts = str(value).split("\\")
    if parts[0] in ("STANDARD", "ROW", "COL") and len(parts) == 2:
        dims = [int(v) for v in parts[1].split(",")]
        if not dims or min(dims) < 1:
            raise ValueError("Invalid layout")
        if parts[0] == "STANDARD":
            if len(dims) != 2:
                raise ValueError("Invalid STANDARD")
            return dims[0] * dims[1]
        return sum(dims)
    return int(print_cfg.get("custom_layouts", {})[str(value)])


def print_fault(operation, sop):
    fault = print_cfg.get("fail_" + operation)
    if isinstance(fault, dict):
        return int(fault.get(sop, 0))
    return int(fault or 0)


def print_record(operation, sop, uid, status):
    stats["print_operations"].append({"operation": operation, "sop_class": sop, "uid": uid, "status": status})


def print_create(event):
    sop = str(event.request.AffectedSOPClassUID)
    uid = print_uid() if print_cfg.get("replace_uids", True) else str(event.request.AffectedSOPInstanceUID)
    attrs = event.attribute_list
    status = print_fault("create", sop)
    reply = Dataset()
    if not status:
        if sop == PS:
            model = {"uid": uid, "copies": int(attrs.get("NumberOfCopies", 1)), "films": [], "deleted": False}
            print_objects[uid] = model
            stats["print_sessions"].append(model)
        elif sop == PB:
            try:
                session_uid = str(attrs.ReferencedFilmSessionSequence[0].ReferencedSOPInstanceUID)
                session = print_objects[session_uid]
                count = print_layout(attrs.ImageDisplayFormat)
                count = max(0, count - int(print_cfg.get("insufficient_boxes", 0)))
                if count > int(print_cfg.get("max_image_boxes", 64)):
                    raise ValueError("Print layout exceeds max_image_boxes")
                image_sop = CI if str(event.context.abstract_syntax) == CM else GI
                model = {"uid": uid, "session_uid": session_uid, "layout": str(attrs.ImageDisplayFormat),
                         "images": [], "annotations": [], "accepted": False, "deleted": False,
                         "attributes": attrs.to_json_dict()}
                session["films"].append(uid)
                print_objects[uid] = model
                stats["films"].append(model)
                reply.ReferencedImageBoxSequence = []
                for _ in range(count):
                    image_uid = print_uid()
                    print_objects[image_uid] = {"film": model, "sop": image_sop}
                    reply.ReferencedImageBoxSequence.append(print_ref(image_sop, image_uid))
                annotation_count = int(print_cfg.get("annotation_formats", {}).get(str(attrs.get("AnnotationDisplayFormatID", "")), 0))
                annotation_count = max(0, annotation_count - int(print_cfg.get("insufficient_annotations", 0)))
                reply.ReferencedBasicAnnotationBoxSequence = []
                for _ in range(annotation_count):
                    annotation_uid = print_uid()
                    print_objects[annotation_uid] = {"film": model, "sop": PA}
                    reply.ReferencedBasicAnnotationBoxSequence.append(print_ref(PA, annotation_uid))
            except (KeyError, ValueError, AttributeError, IndexError):
                status = 0x0106
        elif sop == PL:
            if print_cfg.get("refuse_lut"):
                status = 0x0122
            elif "PresentationLUTShape" in attrs:
                if str(attrs.PresentationLUTShape) not in ("IDENTITY", "LIN OD") or "PresentationLUTSequence" in attrs:
                    status = 0x0106
            else:
                try:
                    table = attrs.PresentationLUTSequence[0]
                    descriptor = list(table.LUTDescriptor)
                    if descriptor[0] not in (256, 4096) or descriptor[1] != 0 or not 10 <= descriptor[2] <= 16:
                        status = 0x0106
                    elif len(table.LUTData) != descriptor[0] * 2:
                        status = 0x0106
                except (AttributeError, IndexError):
                    status = 0x0120
            if not status:
                print_objects[uid] = {"attributes": attrs.to_json_dict()}
        else:
            status = 0x0118
    print_record("create", sop, uid, status)
    response = Dataset()
    response.Status = status
    response.AffectedSOPInstanceUID = uid
    return response, reply if not status else None


def print_set(event):
    sop, uid = str(event.request.RequestedSOPClassUID), str(event.request.RequestedSOPInstanceUID)
    attrs = event.modification_list
    status = print_fault("set", sop)
    obj = print_objects.get(uid)
    if obj is None:
        status = 0x0112
    if obj is not None and sop in (GI, CI):
        seq = attrs.get("BasicGrayscaleImageSequence", attrs.get("BasicColorImageSequence", []))
        if seq:
            image = seq[0]
            pixels = bytes(image.PixelData)
            maximum = print_cfg.get("box_size", [65535, 65535])
            if int(image.Rows) > maximum[0] or int(image.Columns) > maximum[1]:
                status = 0xC603 if attrs.get("RequestedDecimateCropBehavior") == "FAIL" else 0xB604
            if len(pixels) > print_cfg.get("memory_limit", 2**31):
                status = 0xC605
            if sop == CI and int(image.get("PlanarConfiguration", 0)) != 1:
                status = 0x0106
            record = {"uid": uid, "position": int(attrs.ImageBoxPosition), "sha256": hashlib.sha256(pixels).hexdigest(),
                      "rows": int(image.Rows), "columns": int(image.Columns), "photometric": str(image.PhotometricInterpretation),
                      "planar_configuration": int(image.get("PlanarConfiguration", 0)), "status": status,
                      "original_image": [item.to_json_dict() for item in attrs.get("OriginalImageSequence", [])],
                      "requested_image_size": str(attrs.get("RequestedImageSize", "")),
                      "decimate_crop": str(attrs.get("RequestedDecimateCropBehavior", ""))}
            obj["film"]["images"].append(record)
    elif not status and sop == PA:
        obj["film"]["annotations"].append({"uid": uid, "position": int(attrs.AnnotationPosition), "text": str(attrs.get("TextString", ""))})
    elif not status and sop == PS:
        obj["copies"] = int(attrs.get("NumberOfCopies", obj["copies"]))
    elif not status and sop == PB:
        obj["updates"] = attrs.to_json_dict()
    if not status and print_cfg.get("unknown_attribute_warning"):
        status = 0x0107
    print_record("set", sop, uid, status)
    return status, None


def print_action(event):
    sop, uid = str(event.request.RequestedSOPClassUID), str(event.request.RequestedSOPInstanceUID)
    status = print_fault("action", sop)
    if uid not in print_objects:
        status = 0x0112
    reply = None
    if not status:
        obj = print_objects[uid]
        films = [print_objects[item] for item in obj["films"]] if sop == PS else [obj]
        if not films:
            status = 0xC600
        else:
            for film in films:
                film["accepted"] = True
            copies = obj["copies"] if sop == PS else print_objects[obj["session_uid"]]["copies"]
            stats["print_order"] += [film["uid"] for film in films] * copies
            if print_cfg.get("jobs", False):
                job_uid = print_uid()
                print_objects[job_uid] = {"status": "PENDING", "info": "QUEUED"}
                reply = Dataset()
                reply.add_new(0x21000500, "SQ", [print_ref(PJ, job_uid)])
                def report():
                    time.sleep(0.05)
                    for event_id, state, info in [(1, "PENDING", "QUEUED"), (2, "PRINTING", "NORMAL"),
                        (4, "FAILURE", print_cfg.get("job_failure_info", "FILM JAM")) if print_cfg.get("job_failure") else (3, "DONE", "NORMAL")]:
                        if not event.assoc.is_established or (print_cfg.get("job_stall") and event_id > 1):
                            return
                        print_objects[job_uid].update(status=state, info=info)
                        data = dataset({"ExecutionStatusInfo": info})
                        response, _ = event.assoc.send_n_event_report(data, event_id, PJ, job_uid)
                        stats["job_events"].append({"uid": job_uid, "type": event_id, "state": state,
                                                    "info": info, "ack": int(response.get("Status", -1))})
                        time.sleep(0.01)
                threading.Thread(target=report, daemon=True).start()
    print_record("action", sop, uid, status)
    return status, reply


def print_get(event):
    sop, uid = str(event.request.RequestedSOPClassUID), str(event.request.RequestedSOPInstanceUID)
    status = print_fault("get", sop)
    reply = None
    if sop == PR:
        reply = dataset({"PrinterStatus": print_cfg.get("printer_status", "NORMAL"),
                         "PrinterStatusInfo": print_cfg.get("printer_status_info", "NORMAL"), "PrinterName": "Independent Print SCP"})
        if print_cfg.get("printer_event") and not stats.get("printer_event_sent"):
            stats["printer_event_sent"] = True
            # Send before the N-GET response so it is observed before any action.
            event_id = int(print_cfg["printer_event"])
            info = dataset({"PrinterStatusInfo": print_cfg.get("printer_status_info", "FILM JAM")})
            event.assoc.send_n_event_report(info, event_id, PR, PRINT_ROOT + "17", meta_uid=event.context.abstract_syntax)
    elif sop == PC:
        reply = dataset({"PrinterConfigurationSequence": print_cfg.get("configuration", [])})
    elif sop == PJ and uid in print_objects:
        job = print_objects[uid]
        reply = dataset({"ExecutionStatus": job["status"], "ExecutionStatusInfo": job["info"]})
    else:
        status = 0x0112
    print_record("get", sop, uid, status)
    return status, reply


def print_delete(event):
    sop, uid = str(event.request.RequestedSOPClassUID), str(event.request.RequestedSOPInstanceUID)
    status = print_fault("delete", sop)
    if uid in print_objects:
        if not status:
            obj = print_objects[uid]
            obj["deleted"] = True
            films = [print_objects[film_uid] for film_uid in obj.get("films", [])] if sop == PS else [obj] if sop == PB else []
            for film in films:
                film["deleted"] = True
                for child in print_objects.values():
                    if child.get("film") is film:
                        child["deleted"] = True
    else:
        status = 0x0112
    print_record("delete", sop, uid, status)
    return status


def print_services():
    services = [PS, PB, GI, CI, PA, PR, PC, PL, GM, CM]
    if print_cfg.get("jobs", False):
        services.append(PJ)
    if print_cfg.get("refuse_color_contexts"):
        services = [uid for uid in services if uid not in (CI, CM)]
    if print_cfg.get("refuse_annotation_context"):
        services.remove(PA)
    return services


if cfg.get("role") == "print_scu":
    ae = AE(ae_title=cfg.get("aet", "PYNETSCU"))
    ae.dimse_timeout = 10
    ae.acse_timeout = 10
    meta = CM if print_cfg.get("color") else GM
    image_sop = CI if print_cfg.get("color") else GI
    for service in [meta, PA, PL, PJ, PC]:
        ae.add_requested_context(service, syntaxes)
    stats["job_events"] = []
    finished = threading.Event()
    created_uids = {}

    def print_scu_command(event):
        command = event.message.command_set
        if int(command.CommandField) == 0x8140 and command.get("AffectedSOPInstanceUID"):
            created_uids[str(command.AffectedSOPClassUID)] = str(command.AffectedSOPInstanceUID)

    def print_scu_event(event):
        stats["job_events"].append({"type": int(event.request.EventTypeID),
            "uid": str(event.request.AffectedSOPInstanceUID),
            "info": str(event.event_information.get("ExecutionStatusInfo", ""))})
        if int(event.request.EventTypeID) in (3, 4):
            finished.set()
        return 0x0000, None

    emit({"ready": True, "port": 0}, cfg.get("ready_path"))
    if cfg.get("start_path"):
        deadline = time.monotonic() + 10
        while not Path(cfg["start_path"]).exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    assoc = ae.associate(cfg.get("host", "127.0.0.1"), cfg["port"],
        ae_title=cfg.get("called_aet", "ISIS"), evt_handlers=[(evt.EVT_N_EVENT_REPORT, print_scu_event),
            (evt.EVT_DIMSE_RECV, print_scu_command)])
    stats["established"] = assoc.is_established

    def record_print_reply(operation, sop, response):
        status, attributes = response
        code = int(status.Status) if hasattr(status, "Status") else -1
        stats["print_operations"].append({"operation": operation, "sop_class": sop, "status": code,
            "uid": created_uids.get(sop, "") if operation == "create" else "",
            "attribute_identifier_list": str(status.get("AttributeIdentifierList", ""))})
        return code, status, attributes

    if assoc.is_established:
        try:
            code, status, _ = record_print_reply("create", PS, assoc.send_n_create(
                dataset({"NumberOfCopies": print_cfg.get("copies", 1)}), PS, None, meta_uid=meta))
            session_uid = created_uids.get(PS, "")
            if code not in (0, 0xB600):
                raise RuntimeError("Film Session CREATE failed")
            lut_uid = None
            if print_cfg.get("lut"):
                lut = print_cfg["lut"]
                attributes = dataset(lut if isinstance(lut, dict) else {"PresentationLUTShape": "IDENTITY"})
                code, status, _ = record_print_reply("create", PL, assoc.send_n_create(attributes, PL, None))
                if code != 0:
                    raise RuntimeError("LUT CREATE failed")
                lut_uid = created_uids[PL]
            film = dataset({"ImageDisplayFormat": print_cfg.get("layout", "STANDARD\\1,1"),
                "FilmSizeID": "8INX10IN", "FilmOrientation": "PORTRAIT", "MagnificationType": "REPLICATE",
                "ReferencedFilmSessionSequence": [print_ref(PS, session_uid)]})
            if print_cfg.get("annotations"):
                film.AnnotationDisplayFormatID = print_cfg.get("annotation_format", "LABEL")
            if lut_uid:
                film.ReferencedPresentationLUTSequence = [print_ref(PL, lut_uid)]
            code, status, attributes = record_print_reply("create", PB, assoc.send_n_create(film, PB, None, meta_uid=meta))
            if code != 0:
                raise RuntimeError("Film Box CREATE failed")
            film_uid = created_uids[PB]
            if lut_uid and print_cfg.get("delete_referenced_lut"):
                record_print_reply("delete_referenced_lut", PL, (assoc.send_n_delete(PL, lut_uid), None))
            refs = attributes.ReferencedImageBoxSequence
            images = print_cfg.get("images", [{"rows": 2, "columns": 2,
                "pixels": "ff000000ff000000ffffffff" if print_cfg.get("color") else "001020ff"}])
            if len(refs) < len(images):
                raise RuntimeError("Insufficient image boxes")
            stats["sent_images"] = []
            for index, image in enumerate(images):
                pixels = bytes.fromhex(image["pixels"])
                image_attributes = dataset({"Rows": image["rows"], "Columns": image["columns"],
                    "SamplesPerPixel": 3 if print_cfg.get("color") else 1,
                    "PhotometricInterpretation": "RGB" if print_cfg.get("color") else "MONOCHROME2",
                    "BitsAllocated": 8, "BitsStored": 8, "HighBit": 7, "PixelRepresentation": 0})
                image_attributes.PixelData = pixels
                if print_cfg.get("color"):
                    image_attributes.PlanarConfiguration = 1
                request = dataset({"ImageBoxPosition": index + 1})
                setattr(request, "BasicColorImageSequence" if print_cfg.get("color") else "BasicGrayscaleImageSequence", [image_attributes])
                if print_cfg.get("unknown_attribute"):
                    request.add_new(0x20209999, "LO", "UNKNOWN")
                record_print_reply("set", image_sop, assoc.send_n_set(request, image_sop, str(refs[index].ReferencedSOPInstanceUID), meta_uid=meta))
                stats["sent_images"].append({"position": index + 1, "sha256": hashlib.sha256(pixels).hexdigest()})
            for index, text in enumerate(print_cfg.get("annotations", [])):
                reference = attributes.ReferencedBasicAnnotationBoxSequence[index]
                record_print_reply("set", PA, assoc.send_n_set(dataset({"AnnotationPosition": index + 1, "TextString": text}),
                    PA, str(reference.ReferencedSOPInstanceUID)))
            code, _, action = record_print_reply("action", PB, assoc.send_n_action(None, 1, PB, film_uid, meta_uid=meta))
            if code == 0 and action and action.get(0x21000500):
                if print_cfg.get("abort_after_action"):
                    assoc.abort()
                elif not finished.wait(10):
                    raise RuntimeError("Print Job terminal event timed out")
            if assoc.is_established:
                record_print_reply("get", PR, assoc.send_n_get([], PR, "1.2.840.10008.5.1.1.17", meta_uid=meta))
                record_print_reply("get", PC, assoc.send_n_get([], PC, "1.2.840.10008.5.1.1.17.376"))
                status = assoc.send_n_delete(PB, film_uid, meta_uid=meta)
                record_print_reply("delete", PB, (status, None))
                status = assoc.send_n_delete(PS, session_uid, meta_uid=meta)
                record_print_reply("delete", PS, (status, None))
                if lut_uid:
                    record_print_reply("delete", PL, (assoc.send_n_delete(PL, lut_uid), None))
        except Exception as error:
            stats["error"] = str(error)
        finally:
            if assoc.is_established:
                assoc.release()
    emit(stats, cfg.get("result_path"))
    sys.exit(0)


if cfg.get("role", "scp") == "scp":
    ae = AE(ae_title=cfg.get("aet", "PYNETDICOM"))
    ae.maximum_pdu_size = cfg.get("max_pdu", 16384)
    services = [Verification, SecondaryCaptureImageStorage, StudyRootQueryRetrieveInformationModelFind,
                StudyRootQueryRetrieveInformationModelGet, StudyRootQueryRetrieveInformationModelMove,
                PatientRootQueryRetrieveInformationModelFind, PatientRootQueryRetrieveInformationModelGet,
                PatientRootQueryRetrieveInformationModelMove, ModalityWorklistInformationFind,
                ModalityPerformedProcedureStep, StorageCommitmentPushModel,
                UPS_PUSH, UPS_WATCH, UPS_PULL, UPS_EVENT, UPS_QUERY, IAN]
    if "print" in cfg:
        services = print_services()
    for uid in cfg.get("services", services):
        ae.add_supported_context(uid, syntaxes, scu_role=True, scp_role=True)
    ae.add_requested_context(SecondaryCaptureImageStorage, syntaxes)
    handlers = [(evt.EVT_C_ECHO, echo), (evt.EVT_C_STORE, store), (evt.EVT_C_FIND, lambda event: ups_find(event) if str(event.context.abstract_syntax) in (UPS_PULL, UPS_WATCH, UPS_QUERY) else find(event)),
                (evt.EVT_C_GET, get), (evt.EVT_C_MOVE, move), (evt.EVT_N_CREATE, print_create if "print" in cfg else ups_create),
                (evt.EVT_N_SET, print_set if "print" in cfg else ups_set), (evt.EVT_N_GET, print_get if "print" in cfg else ups_get), (evt.EVT_N_ACTION, print_action if "print" in cfg else ups_action),
                (evt.EVT_N_EVENT_REPORT, lambda event: ups_notification(event) if str(event.context.abstract_syntax) == UPS_EVENT else commitment_report(event)),
                (evt.EVT_USER_ID, identity), (evt.EVT_ASYNC_OPS, lambda event: (1, 1)),
                (evt.EVT_SOP_EXTENDED, extended), (evt.EVT_PDU_RECV, pdu_received),
                (evt.EVT_DIMSE_RECV, dimse_received), (evt.EVT_DIMSE_SENT, dimse_sent)]
    if "print" in cfg:
        handlers.append((evt.EVT_N_DELETE, print_delete))
    tls_context = None
    tls_directory = None
    if cfg.get("generate_tls"):
        import shutil
        import subprocess
        import tempfile
        if not shutil.which("openssl"):
            emit({"unavailable": "openssl is unavailable"}, cfg.get("ready_path"))
            sys.exit(0)
        tls_directory = tempfile.TemporaryDirectory(prefix="isis-pynet-tls-")
        cert = str(Path(tls_directory.name) / "cert.pem")
        key = str(Path(tls_directory.name) / "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-keyout", key, "-out", cert],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        cfg["tls_certificate"], cfg["tls_key"] = cert, key

    if cfg.get("tls_certificate"):
        import ssl
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.load_cert_chain(cfg["tls_certificate"], cfg["tls_key"])
    server = ae.start_server(("127.0.0.1", cfg.get("port", 0)), block=False,
                             evt_handlers=handlers, ssl_context=tls_context)
    if cfg.get("fixture_path"):
        import struct
        from pydicom.encaps import encapsulate
        ds = instances()[0]
        ds.file_meta.TransferSyntaxUID = "1.2.840.10008.1.2.5"
        header = struct.pack("<16I", 1, 64, *([0] * 14))
        ds.PixelData = encapsulate([header + bytes([129, 0]) * 16])
        ds[0x7FE00010].is_undefined_length = True
        pydicom.dcmwrite(cfg["fixture_path"], ds, enforce_file_format=True)
    emit({"ready": True, "port": server.server_address[1]}, cfg.get("ready_path"))
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    stop.wait()
    server.shutdown()
    emit(stats, cfg.get("result_path"))
else:
    ae = AE(ae_title=cfg.get("aet", "PYNETSCU"))
    ae.dimse_timeout = 10
    ae.acse_timeout = 10
    operation = cfg.get("operation", "echo")
    uid = {"echo": Verification, "find": StudyRootQueryRetrieveInformationModelFind,
           "patient_find": PatientRootQueryRetrieveInformationModelFind, "mwl": ModalityWorklistInformationFind,
           "get": StudyRootQueryRetrieveInformationModelGet, "move": StudyRootQueryRetrieveInformationModelMove,
           "action": StorageCommitmentPushModel, "store": SecondaryCaptureImageStorage,
           "mpps": ModalityPerformedProcedureStep, "concurrent": StudyRootQueryRetrieveInformationModelFind,
           "sequence": UPS_PUSH, "ups_create": UPS_PUSH, "ups_find": UPS_PULL, "ups_get": UPS_PULL,
           "ups_set": UPS_PULL, "ups_action": UPS_PULL, "ian_create": IAN}[operation]
    ae.add_requested_context(uid, syntaxes)
    if operation == "concurrent":
        ae.add_requested_context(Verification, syntaxes)
    if operation == "sequence" or operation.startswith("ups_") or operation == "ian_create":
        for extra_uid in (UPS_PUSH, UPS_WATCH, UPS_PULL, UPS_QUERY, IAN):
            if extra_uid != uid:
                ae.add_requested_context(extra_uid, syntaxes)
    roles = []
    event_received = threading.Event()

    def notification(event):
        stats["event_type"] = int(event.event_type)
        stats["transaction_uid"] = str(event.event_information.TransactionUID)
        stats["failed_references"] = [int(item.FailureReason)
                                      for item in event.event_information.get("FailedSOPSequence", [])]
        event_received.set()
        return 0, None

    callback_server = None
    if (operation == "sequence" or operation.startswith("ups_")) and cfg.get("callback_listener"):
        ae.add_supported_context(UPS_EVENT, syntaxes)
        callback_server = ae.start_server(("127.0.0.1", cfg.get("callback_port", 0)), block=False,
                                          evt_handlers=[(evt.EVT_N_EVENT_REPORT, ups_notification)])
    if operation == "action" and cfg.get("callback_listener"):
        ae.add_supported_context(StorageCommitmentPushModel, syntaxes, scu_role=False, scp_role=True)
        callback_server = ae.start_server(("127.0.0.1", cfg.get("callback_port", 0)), block=False,
                                          evt_handlers=[(evt.EVT_N_EVENT_REPORT, notification)])
    if operation == "action" and cfg.get("same_association_role"):
        roles.append(build_role(StorageCommitmentPushModel, scu_role=True, scp_role=False))
    if operation == "get":
        ae.add_requested_context(SecondaryCaptureImageStorage, syntaxes)
        roles.append(build_role(SecondaryCaptureImageStorage, scu_role=False, scp_role=True))
    if cfg.get("async_window"):
        window = AsynchronousOperationsWindowNegotiation()
        window.maximum_number_operations_invoked, window.maximum_number_operations_performed = cfg["async_window"]
        roles.append(window)
    if cfg.get("user_identity"):
        from pynetdicom.pdu_primitives import UserIdentityNegotiation
        identity = UserIdentityNegotiation()
        identity.user_identity_type = 2 if cfg.get("passcode") is not None else 1
        identity.secondary_field = cfg.get("passcode", "").encode()
        identity.primary_field = cfg["user_identity"].encode()
        roles.append(identity)
    if cfg.get("extended_flags"):
        negotiation = SOPClassExtendedNegotiation()
        negotiation.sop_class_uid = uid
        negotiation.service_class_application_information = bytes(cfg["extended_flags"])
        roles.append(negotiation)
    emit({"ready": True, "port": callback_server.server_address[1] if callback_server else 0}, cfg.get("ready_path"))
    if cfg.get("start_path"):
        deadline = time.monotonic() + 10
        while not Path(cfg["start_path"]).exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    tls_options = {}
    stats["tls"] = "tls_ca_file" in cfg
    if stats["tls"]:
        tls_options["tls_args"] = (scu_tls_context(cfg), cfg.get("tls_server_hostname", "localhost"))
    assoc = ae.associate(cfg.get("host", "127.0.0.1"), cfg["port"], ae_title=cfg.get("called_aet", "ISIS"),
                         ext_neg=roles, max_pdu=cfg.get("max_pdu", 16384),
                         evt_handlers=[(evt.EVT_C_STORE, store), (evt.EVT_N_EVENT_REPORT, notification)], **tls_options)
    stats["established"] = assoc.is_established
    if assoc.is_established:
        stats["async_accepted"] = list(assoc.acceptor.asynchronous_operations)
        query = dataset(cfg.get("identifier", {"QueryRetrieveLevel": "STUDY", "StudyInstanceUID": "2.25.2350"}))
        if operation == "sequence" or operation.startswith("ups_") or operation == "ian_create":
            for step in cfg.get("steps", [cfg]):
                ups_step(assoc, step)
        elif operation == "echo":
            stats["statuses"] = [int(assoc.send_c_echo().Status)]
        elif operation == "store":
            stats["statuses"] = [int(assoc.send_c_store(ds).Status) for ds in instances()]
        elif operation == "concurrent":
            from io import BytesIO
            from pynetdicom.dimse_primitives import C_FIND, C_ECHO
            from pynetdicom.dsutils import encode
            # Use the same reactor handoff as send_c_find, with one consumer for
            # correlated responses. No monkeypatching of peer negotiation/dispatch.
            assoc._reactor_checkpoint.clear()
            while not assoc._is_paused:
                time.sleep(0.001)
            try:
                context = assoc._get_valid_context(uid, "", "scu")
                syntax = context.transfer_syntax[0]
                for message_id in range(1, 4):
                    request = C_FIND()
                    request.MessageID = message_id
                    request.AffectedSOPClassUID = uid
                    request.Priority = 0
                    request.Identifier = BytesIO(encode(dataset({"QueryRetrieveLevel": "STUDY"}),
                        syntax.is_implicit_VR, syntax.is_little_endian))
                    assoc.dimse.send_msg(request, context.context_id)
                echo_request = C_ECHO()
                echo_request.MessageID = 4
                echo_request.AffectedSOPClassUID = Verification
                assoc.dimse.send_msg(echo_request, assoc._get_valid_context(Verification, "", "scu").context_id)
                stats["concurrent_responses"] = []
                final = set()
                while len(final) < 4:
                    _, response = assoc.dimse.get_msg(block=True)
                    if response is None:
                        raise RuntimeError("Concurrent DIMSE response timed out")
                    stats["concurrent_responses"].append([int(response.MessageIDBeingRespondedTo), int(response.Status)])
                    if response.Status not in (0xFF00, 0xFF01):
                        final.add(int(response.MessageIDBeingRespondedTo))
            finally:
                assoc._reactor_checkpoint.set()
        elif operation == "mpps":
            sop_instance = "2.25.235099"
            stats["statuses"] = []
            for method, state in [("send_n_create", "IN PROGRESS"), ("send_n_set", "COMPLETED"),
                                   ("send_n_set", "DISCONTINUED")]:
                status, _ = getattr(assoc, method)(dataset({"PerformedProcedureStepStatus": state}), uid, sop_instance)
                stats["statuses"].append(int(status.Status))
                if "ErrorComment" in status:
                    stats["error_comment"] = str(status.ErrorComment)
                if "ErrorID" in status:
                    stats["error_id"] = int(status.ErrorID)
        elif operation == "action":
            action_data = dataset({"TransactionUID": cfg.get("transaction_uid", "2.25.235088")})
            action_data.ReferencedSOPSequence = [dataset({"ReferencedSOPClassUID": str(SecondaryCaptureImageStorage),
                                                          "ReferencedSOPInstanceUID": "2.25.2350001"})]
            status, _ = assoc.send_n_action(action_data, 1, uid, "1.2.840.10008.1.20.1.1")
            stats["statuses"] = [int(status.Status)]
            if cfg.get("release_after_action"):
                assoc.release()
                stats["released_before_event"] = not event_received.is_set()
            event_received.wait(10)
        else:
            method = "find" if operation in ("patient_find", "mwl") else operation
            responses = (assoc.send_c_move(query, cfg.get("destination_aet", "ISIS"), uid, msg_id=7) if method == "move"
                         else getattr(assoc, "send_c_" + method)(query, uid, msg_id=7))
            stats["statuses"] = []
            for status, identifier in responses:
                if not status:
                    continue
                stats["statuses"].append(int(status.Status))
                stats["responses"].append({key: int(getattr(status, key)) for key in (
                    "NumberOfRemainingSuboperations", "NumberOfCompletedSuboperations",
                    "NumberOfFailedSuboperations", "NumberOfWarningSuboperations") if hasattr(status, key)})
                if cfg.get("cancel_after") and len(stats["statuses"]) == cfg["cancel_after"]:
                    assoc.send_c_cancel(7, query_model=uid)
                    stats["cancelled"] = True
        if assoc.is_established:
            assoc.release()
    if callback_server:
        callback_server.shutdown()
    emit(stats, cfg.get("result_path"))
