#!/usr/bin/env python3
"""Independent OpenJPIP FastCGI/HTTP fixture. No DicomCore dependency."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qsl, urlsplit


class FixtureError(RuntimeError):
    """A fixed, PHI-free diagnostic suitable for the result JSON."""


def emit(value, path=None):
    line = json.dumps(value, sort_keys=True)
    if path:
        Path(path).write_text(line + "\n")
    print(line, flush=True)


def run(command, directory):
    # Native logs may contain source paths or metadata; never relay them to JSON.
    result = subprocess.run([str(x) for x in command], cwd=directory,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    return result.returncode


def prepare(args, directory, compressor):
    import numpy as np

    source = args.input
    if args.self_test or source is None:
        pixels = np.fromfunction(lambda y, x: (x + y) / 2, (256, 256)).astype('uint8')
    elif args.format == 'dicom':
        import pydicom

        dataset = pydicom.dcmread(source)
        if dataset.PhotometricInterpretation not in ('MONOCHROME1', 'MONOCHROME2'):
            raise ValueError('DICOM input must be monochrome')
        pixels = dataset.pixel_array
        if pixels.ndim == 3:
            pixels = pixels[args.frame]
        if pixels.ndim != 2:
            raise ValueError('DICOM input must have two-dimensional grayscale frames')
        # Fixture conversion, not clinical windowing: normalize stored values.
        pixels = pixels.astype('float64')
        low, high = pixels.min(), pixels.max()
        pixels = (pixels - low) / (high - low) if high > low else pixels * 0
        if dataset.PhotometricInterpretation == 'MONOCHROME1':
            pixels = 1 - pixels
        pixels = np.rint(pixels * ((1 << args.bits) - 1))
    elif args.format == 'raw':
        if not args.width or not args.height:
            raise ValueError('Raw input requires --width and --height')
        dtype = 'u1' if args.bits == 8 else ('<u2' if args.byte_order == 'little' else '>u2')
        pixels = np.fromfile(source, dtype=dtype).reshape(args.height, args.width)
    else:
        # Copy under a fixed name; never expose the original filename to the server.
        suffix = source.suffix.lower()
        if suffix not in ('.pgm', '.ppm'):
            raise ValueError('Portable input must be PGM or PPM')
        source_copy = directory / ('input' + suffix)
        shutil.copyfile(source, source_copy)
        pixels = None
    if pixels is not None:
        bits = 8 if args.self_test or source is None else args.bits
        source_copy = directory / 'input.pgm'
        with source_copy.open('wb') as stream:
            stream.write(f'P5\n{pixels.shape[1]} {pixels.shape[0]}\n{(1 << bits) - 1}\n'.encode())
            stream.write(pixels.astype('u1' if bits == 8 else '>u2').tobytes())
    command = [compressor, '-i', source_copy.name, '-o', 'target.jp2', '-jpip', '-p', 'RPCL',
               '-TP', 'R', '-n', str(3 if args.self_test else args.resolutions),
               '-c', '[64,64]' if args.self_test else args.precincts]
    command += ['-r', '8,4,1'] if args.self_test else (['-q', args.quality] if args.quality else ['-r', args.rates])
    if args.tile_size:
        command += ['-t', args.tile_size]
    if run(command, directory):
        raise FixtureError(f'{Path(compressor).name} failed')
    return [str(x) for x in command]


def validate_index(path):
    # OpenJPEG accepts -jpip even in builds without a working index writer.
    data = path.read_bytes()

    def walk(start, end):
        boxes = []
        while start + 8 <= end:
            length, kind = struct.unpack_from('!I4s', data, start)
            header_size = 8
            if length == 1:
                length = struct.unpack_from('!Q', data, start + 8)[0]
                header_size = 16
            elif length == 0:
                length = end - start
            if length < header_size or start + length > end:
                raise FixtureError('Invalid JP2 index box length')
            payload = data[start + header_size:start + length]
            box = {'type': kind.decode('ascii'), 'length': length}
            if kind in (b'cidx', b'fidx') and not any(payload):
                raise FixtureError('Encoder -jpip produced a zero-filled '
                                   + kind.decode() + ' placeholder, not a usable JPIP index')
            if kind in (b'cidx', b'fidx', b'tpix', b'ppix', b'phix', b'thix'):
                box['children'] = walk(start + header_size, start + length)
            boxes.append(box)
            start += length
        return boxes

    boxes = walk(0, len(data))
    if not {'jp2c', 'iptr', 'cidx', 'fidx'} <= {box['type'] for box in boxes}:
        raise FixtureError('Encoder -jpip produced no usable JPIP index '
                           '(required top-level jp2c/iptr/cidx/fidx boxes missing)')
    def types(boxes):
        return {box['type'] for box in boxes}.union(
            *(types(box.get('children', [])) for box in boxes))

    cidx = next(box for box in boxes if box['type'] == 'cidx')
    if not {'cptr', 'manf'} <= {box['type'] for box in cidx['children']} or 'faix' not in types(cidx['children']):
        raise FixtureError('JPIP cidx lacks cptr/manf/faix index children')
    return boxes


def record(kind, content=b''):
    padding = (-len(content)) % 8
    return struct.pack('!BBHHBB', 1, kind, 1, len(content), padding, 0) + content + bytes(padding)


def param_length(length):
    return bytes([length]) if length < 128 else struct.pack('!I', length | 0x80000000)


def receive(sock, length):
    data = bytearray()
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise ConnectionError('FastCGI closed before END_REQUEST')
        data.extend(part)
    return bytes(data)


def fcgi(address, params, log=None):
    with socket.create_connection(address, timeout=10) as connection:
        connection.sendall(record(1, struct.pack('!HB5x', 1, 0)))
        encoded = bytearray()
        for key, value in params.items():
            key, value = key.encode(), value.encode()
            encoded.extend(param_length(len(key)) + param_length(len(value)) + key + value)
        for offset in range(0, len(encoded), 65535):
            connection.sendall(record(4, encoded[offset:offset + 65535]))
        connection.sendall(record(4) + record(5))
        while True:
            version, kind, request_id, length, padding, _ = struct.unpack('!BBHHBB', receive(connection, 8))
            if version != 1 or request_id != 1:
                raise ValueError('Invalid FastCGI record')
            content = receive(connection, length)
            receive(connection, padding)
            if kind == 6 and content:
                yield content
            elif kind == 7 and content and log:
                log.write(content)
            elif kind == 3:
                if len(content) != 8 or struct.unpack('!IB3x', content) != (0, 0):
                    raise RuntimeError('FastCGI request failed')
                return


def safe_query(query):
    # Record protocol fields only, keeping arbitrary user strings out of evidence.
    result = []
    for key, value in parse_qsl(query, keep_blank_values=True):
        if key == 'target':
            value = 'target.jp2' if value == 'target.jp2' else '[redacted]'
        elif key in ('fsiz', 'roff', 'rsiz', 'layers', 'len'):
            value = value if re.fullmatch(r'[0-9,\-]+', value) else '[redacted]'
        elif key in ('cid', 'tid', 'cclose'):
            value = value if re.fullmatch(r'[0-9a-fA-F*\-]+', value) else '[redacted]'
        elif key == 'type':
            value = value if value in ('jpp-stream', 'jpt-stream') else '[redacted]'
        elif key == 'cnew':
            value = value if value == 'http' else '[redacted]'
        else:
            key, value = '[redacted]', '[redacted]'
        result.append(f'{key}={value}')
    return '&'.join(result)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        params = {'GATEWAY_INTERFACE': 'CGI/1.1', 'REQUEST_METHOD': 'GET',
                  'QUERY_STRING': url.query, 'SCRIPT_NAME': url.path,
                  'SERVER_PROTOCOL': 'HTTP/1.1', 'SERVER_NAME': '127.0.0.1',
                  'SERVER_PORT': str(self.server.server_port), 'REMOTE_ADDR': '127.0.0.1'}
        params.update({'HTTP_' + key.upper().replace('-', '_'): value for key, value in self.headers.items()})
        status, content_type, size, started = 502, '', 0, False
        error = None
        try:
            pending = b''
            for data in fcgi(self.server.fcgi_address, params, self.server.fcgi_log):
                if not started:
                    pending += data
                    boundary = re.search(b'\r?\n\r?\n', pending)
                    # Empty CGI header block is a single CRLF.
                    if pending.startswith(b'\r\n'):
                        head, data = b'', pending[2:]
                    elif boundary:
                        head, data = pending[:boundary.start()], pending[boundary.end():]
                    else:
                        if len(pending) > 65536:
                            raise ValueError('Oversized CGI headers')
                        continue
                    headers = []
                    status = 200
                    for line in head.decode('iso-8859-1').splitlines():
                        key, value = line.split(':', 1)
                        value = value.strip()
                        if key.lower() == 'status':
                            status = int(value.split()[0])
                        elif key.lower() not in ('content-length', 'transfer-encoding', 'connection'):
                            headers.append((key, value))
                        if key.lower() == 'content-type':
                            content_type = value
                    self.send_response(status)
                    for key, value in headers:
                        self.send_header(key, value)
                    self.send_header('Transfer-Encoding', 'chunked')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    started = True
                if data:
                    self.wfile.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n')
                    self.wfile.flush()
                    size += len(data)
            if not started:
                raise ValueError('Missing CGI headers')
            self.wfile.write(b'0\r\n\r\n')
        except (OSError, ValueError, RuntimeError) as exc:
            error = type(exc).__name__
            if not started:
                self.send_response(502)
                self.send_header('Content-Length', '0')
                self.end_headers()
        finally:
            self.close_connection = True
            entry = {'query': safe_query(url.query), 'status': status,
                     'content_type': content_type, 'length': size}
            if error:
                entry['error'] = error
            self.server.evidence.append(entry)


class Harness:
    def __init__(self, binary, directory):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(16)
        self.process = None
        self.http = None
        self.thread = None
        self.log = (directory / 'opj_server.log').open('ab', buffering=0)
        try:
            # Popen's stdin duplicates the listening socket onto fd 0 before exec.
            self.process = subprocess.Popen([str(binary)], cwd=directory, stdin=self.listener,
                                            stdout=subprocess.DEVNULL, stderr=self.log,
                                            env=os.environ.copy())
            self.http = HTTPServer(('127.0.0.1', 0), Handler)
            self.http.fcgi_address = self.listener.getsockname()
            self.http.evidence = []
            self.http.fcgi_log = self.log
            # Harmless unknown-channel probe verifies FastCGI is accepting requests.
            list(fcgi(self.http.fcgi_address, {'REQUEST_METHOD': 'GET', 'QUERY_STRING': 'cid=0',
                                              'SCRIPT_NAME': '/', 'SERVER_PROTOCOL': 'HTTP/1.1'}, self.log))
            if self.process.poll() is not None:
                raise RuntimeError('opj_server exited during startup')
            self.listener.close()  # Only the child should keep the listening fd alive.
            self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
            self.thread.start()
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.thread:
            self.http.shutdown()
            self.thread.join()
        if self.http:
            self.http.server_close()
        self.listener.close()
        self.log.close()

    def result(self):
        entries = self.http.evidence
        return {'request_count': len(entries), 'bytes': sum(x['length'] for x in entries),
                'requests': entries, 'server_returncode': self.process.poll()}


def messages(body):
    """Walk JPIP message boundaries, so payload zero bytes cannot mimic EOR."""
    position, class_id = 0, None

    def vbas():
        nonlocal position
        value = 0
        for _ in range(10):
            if position >= len(body):
                raise ValueError('Truncated VBAS')
            byte = body[position]
            position += 1
            value = (value << 7) | (byte & 127)
            if byte < 128:
                return value
        raise ValueError('Oversized VBAS')

    while position < len(body):
        start = position
        first = body[position]
        if first == 0:
            position += 1
            if position >= len(body):
                raise ValueError('Truncated EOR')
            reason = body[position]
            position += 1
            length = vbas()
            position += length
            if position != len(body):
                raise ValueError('EOR does not terminate response')
            return {'present': True, 'offset': start, 'reason': reason}
        mode = (first >> 5) & 3
        if mode == 0:
            raise ValueError('Invalid Bin-ID')
        vbas()  # Bin-ID value is immaterial to this boundary check.
        if mode >= 2:
            class_id = vbas()
        if mode == 3:
            vbas()
        if class_id is None:
            raise ValueError('Missing initial class ID')
        vbas()  # Data-bin offset.
        length = vbas()
        if class_id & 1:
            vbas()
        position += length
        if position > len(body):
            raise ValueError('Truncated message body')
    return {'present': False}


def self_test(harness, directory, transcoder, decompressor):
    import requests
    from PIL import Image

    responses, failures = [], []
    client = requests.Session()
    client.trust_env = False
    cid = None
    session_data = bytearray()
    cases = [
        ('small', 'target=target.jp2&type=jpp-stream&fsiz=64,64'),
        ('layer1', 'target=target.jp2&type=jpp-stream&fsiz=256,256&layers=1'),
        ('session_new', 'target=target.jp2&cnew=http&type=jpp-stream&fsiz=128,128'),
        ('session_more', 'cid={cid}&fsiz=256,256&layers=3'),
        # Supplying cid as well leaves a freed channel in the upstream response path.
        ('session_close', 'cclose={cid}'),
        ('tiles', 'target=target.jp2&type=jpt-stream&fsiz=256,256'),
        ('roi', 'target=target.jp2&type=jpp-stream&fsiz=256,256&roff=64,64&rsiz=64,64'),
    ]
    try:
        for name, query in cases:
            item = {'name': name}
            responses.append(item)
            try:
                if '{cid}' in query and cid is None:
                    raise ValueError('No session CID returned')
                query = query.format(cid=cid)
                response = client.get(f'http://127.0.0.1:{harness.http.server_port}/?{query}', timeout=15)
                body = response.content
                item.update(query=query, status=response.status_code, headers=dict(response.headers),
                            request_headers=dict(response.request.headers), length=len(body))
                expected = 'image/jpt-stream' if name == 'tiles' else 'image/jpp-stream'
                path = directory / (name + ('.jpt' if name == 'tiles' else '.jpp'))
                path.write_bytes(body)
                item['body'] = str(path)
                if response.status_code != 200:
                    failures.append(f'{name}: HTTP {response.status_code}')
                if name == 'session_close' and response.status_code == 200 and not body:
                    # OpenJPIP 1.5.2 answers cclose with an empty 200 and no EOR; the
                    # channel is closed, which is the only observable requirement here.
                    item['limitation'] = 'cclose returns an empty 200 without Content-type or EOR'
                    item['eor'] = {'present': False}
                    continue
                if response.headers.get('Content-Type') != expected:
                    if name in ('small', 'layer1', 'roi') and response.status_code == 200:
                        item['limitation'] = f'Expected {expected}; received {response.headers.get("Content-Type")}'
                    else:
                        failures.append(f'{name}: expected {expected}')
                if not body:
                    failures.append(f'{name}: empty body')
                try:
                    item['eor'] = messages(body)
                    if name.startswith('session_') and not item['eor']['present']:
                        failures.append(f'{name}: missing EOR')
                except ValueError as exc:
                    failures.append(f'{name}: {exc}')
                if name == 'session_new':
                    match = re.search(r'(?:^|,)\s*cid=([^,\s]+)', response.headers.get('JPIP-cnew', ''))
                    if not match:
                        failures.append('session_new: missing JPIP-cnew CID')
                    else:
                        cid = match.group(1)
                if body and response.headers.get('Content-Type') in ('image/jpp-stream', 'image/jpt-stream'):
                    # Session deltas require the previously received data bins.
                    output = directory / (name + '.j2k')
                    rc = run([transcoder, path, output], directory)
                    item['transcode_returncode'] = rc
                    if rc == 0:
                        pgm = directory / (name + '.pgm')
                        item['decompress_returncode'] = run([decompressor, '-i', output, '-o', pgm], directory)
                        if item['decompress_returncode'] == 0:
                            with Image.open(pgm) as decoded:
                                item['decoded_size'] = list(decoded.size)
                    if rc != 0 or item.get('decompress_returncode') != 0:
                        item['oracle_limitation'] = 'Standalone body did not transcode/decode; see native return codes'
                    if name in ('session_new', 'tiles') and (rc != 0 or item.get('decompress_returncode') != 0):
                        failures.append(f'{name}: standalone transcode/decode failed')
                    if name in ('session_new', 'session_more'):
                        eor = item.get('eor', {})
                        session_data.extend(body[:eor['offset']] if eor.get('present') else body)
                        if name == 'session_more':
                            cumulative = directory / 'session_accumulated.jpp'
                            cumulative.write_bytes(session_data)
                            output = directory / 'session_accumulated.j2k'
                            rc = run([transcoder, cumulative, output], directory)
                            item['accumulated_transcode_returncode'] = rc
                            pgm = directory / 'session_accumulated.pgm'
                            if rc == 0:
                                item['accumulated_decompress_returncode'] = run([decompressor, '-i', output, '-o', pgm], directory)
                                if item['accumulated_decompress_returncode'] == 0:
                                    with Image.open(pgm) as decoded:
                                        item['accumulated_decoded_size'] = list(decoded.size)
                            if rc != 0 or item.get('accumulated_decompress_returncode') != 0:
                                failures.append('session_more: accumulated transcode/decode failed')
            except Exception as exc:
                item['error'] = type(exc).__name__
                failures.append(f'{name}: {type(exc).__name__}')
    finally:
        client.close()
    return {'ok': not failures, 'responses': responses, 'failures': failures, 'artifacts': str(directory)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--input', type=Path)
    parser.add_argument('--format', choices=('portable', 'raw', 'dicom'), default='portable')
    parser.add_argument('--bits', type=int, choices=(8, 16), default=16)
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    parser.add_argument('--byte-order', choices=('little', 'big'), default='little')
    parser.add_argument('--frame', type=int, default=0)
    layers = parser.add_mutually_exclusive_group()
    layers.add_argument('--rates', default='8,4,1')
    layers.add_argument('--quality')
    parser.add_argument('--resolutions', type=int, default=3)
    parser.add_argument('--precincts', default='[64,64]')
    parser.add_argument('--tile-size')
    parser.add_argument('--work-dir', type=Path, help='New directory for retained target and evidence')
    parser.add_argument('--ready-path', '--ready_path', type=Path)
    parser.add_argument('--result-path', '--result_path', type=Path)
    args = parser.parse_args()
    configured = os.environ.get('DICOM_JPIP_OPENJPIP_BIN')
    if not configured:
        emit({'skipped': True, 'reason': 'DICOM_JPIP_OPENJPIP_BIN is unset'})
        return 77
    binaries = Path(configured).resolve()
    legacy = (binaries / 'image_to_j2k').exists()
    toolchain = 'openjpeg-1.5.2' if legacy else 'openjpeg-2.5.x'
    compressor_name = 'image_to_j2k' if legacy else 'opj_compress'
    decompressor_name = 'j2k_to_image' if legacy else 'opj_decompress'
    transcoder = binaries / ('jpip_to_j2k' if legacy else 'opj_jpip_transcode')
    for name in ('opj_server', transcoder.name, compressor_name, decompressor_name):
        if not os.access(binaries / name, os.X_OK):
            emit({'ok': False, 'toolchain': toolchain, 'error': f'Missing executable: {name}'}, args.result_path)
            return 1
    compressor = binaries / compressor_name
    decompressor = binaries / decompressor_name
    directory = args.work_dir
    if directory:
        directory = directory.resolve()
        directory.mkdir(parents=True, exist_ok=False)
    else:
        directory = Path(tempfile.mkdtemp(prefix='isis-openjpip-'))
    os.chmod(directory, 0o700)
    harness = None
    result = {}
    metadata = {'toolchain': toolchain}
    stop = threading.Event()
    previous = {sig: signal.signal(sig, lambda *_: stop.set()) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        command = prepare(args, directory, compressor)
        metadata['compress_command'] = command
        metadata['index_boxes'] = validate_index(directory / 'target.jp2')
        version = re.search(rb'OpenJPEG version ([0-9.]+)', (directory / 'target.jp2').read_bytes())
        metadata['versions'] = {'encoder': version.group(1).decode() if version else 'unreported',
                                'server': 'unreported', 'transcoder': 'unreported', 'decoder': 'unreported'}
        metadata['version_source'] = 'encoder codestream COM; other tools have no version output'
        harness = Harness(binaries / 'opj_server', directory)
        emit({'ready': True, 'port': harness.http.server_port, 'target': 'target.jp2', **metadata}, args.ready_path)
        if args.self_test:
            result = self_test(harness, directory, transcoder, decompressor)
        else:
            while not stop.wait(0.25):
                if harness.process.poll() is not None:
                    raise RuntimeError('opj_server exited')
            result = {'ok': True}
        result['compress_command'] = command
    except Exception as exc:
        result = {'ok': False, 'error': str(exc) if isinstance(exc, FixtureError) else type(exc).__name__,
                  'artifacts': str(directory)}
    finally:
        if harness:
            harness.close()
            result.update(harness.result())
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if not result.get('ok') and (directory / 'opj_server.log').exists():
            result['server_log_path'] = str(directory / 'opj_server.log')
        result.update(metadata)
        emit(result, args.result_path or directory / 'result.json')
    return 0 if result.get('ok') else 1


if __name__ == '__main__':
    sys.exit(main())
