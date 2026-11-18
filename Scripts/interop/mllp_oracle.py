#!/usr/bin/env python3
"""Bounded plain-loopback MLLP oracle. JSON config on stdin; no clinical data on stdout/stderr."""
import asyncio
import json
import os
from pathlib import Path
import sys
import threading


def publish(path, value):
    target = Path(path)
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    os.replace(temporary, target)


def frame(payload):
    return b'\x0b' + payload + b'\x1c\x0d'


async def run_async(config, result):
    import hl7
    from hl7.mllp import open_hl7_connection, start_hl7_server
    lifetime = min(60, max(1, config.get('lifetime', 15)))
    if config['role'] == 'client':
        reader, writer = await open_hl7_connection('127.0.0.1', config['port'], encoding='utf-8')
        publish(config['ready_path'], {'ready': True})
        try:
            payloads = [Path(path).read_bytes() for path in config.get('files', [])]
            if config.get('giant_bytes'):
                payloads = [b'X' * config['giant_bytes']]
            wire = b''.join(frame(payload) for payload in payloads)
            chunk = config.get('chunk_bytes', 0) or len(wire)
            try:
                for offset in range(0, len(wire), chunk):
                    writer.write(wire[offset:offset + chunk])
                    await writer.drain()
                    if config.get('chunk_bytes'):
                        await asyncio.sleep(0.001)
                for _ in payloads:
                    ack = await asyncio.wait_for(reader.readmessage(), lifetime)
                    result['ack_codes'].append(str(ack.segment('MSA')[1]))
            except (ConnectionError, asyncio.IncompleteReadError):
                result['closed'] = True
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass
        return

    done = asyncio.Event()
    target = config.get('count', 1)

    async def peer(reader, writer):
        try:
            while not done.is_set():
                message = await asyncio.wait_for(reader.readmessage(), lifetime)
                result['received'].append({'control_id': str(message.segment('MSH')[10]),
                                           'byte_length': len(str(message).encode('utf-8'))})
                await asyncio.sleep(config.get('ack_delay', 0))
                ack = message.create_ack(ack_code=config.get('ack_code', 'AA'))
                writer.writemessage(ack)
                if config.get('duplicate_ack'):
                    writer.writemessage(ack)
                await writer.drain()
                if len(result['received']) >= target:
                    done.set()
                    # Give the client's receiver time to consume the duplicate ACK before EOF.
                    await asyncio.sleep(0.1)
                    return
                drop = config.get('drop_after', 0)
                if drop and len(result['received']) % drop == 0:
                    return
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()

    server = await start_hl7_server(peer, '127.0.0.1', 0, encoding='utf-8', limit=32 * 1024 * 1024)
    async with server:
        publish(config['ready_path'], {'ready': True, 'port': server.sockets[0].getsockname()[1]})
        await asyncio.wait_for(done.wait(), lifetime)
        await asyncio.sleep(0.15)


def run_hl7apy(config, result):
    from hl7apy.mllp import MLLPServer, AbstractHandler
    from hl7apy.parser import parse_message
    from hl7apy.core import Message
    done = threading.Event()

    class Handler(AbstractHandler):
        def reply(self):
            incoming = parse_message(self.incoming_message, find_groups=False)
            control = incoming.msh.msh_10.to_er7()
            result['received'].append({'control_id': control,
                                       'byte_length': len(self.incoming_message.encode('utf-8'))})
            ack = Message('ACK', version=incoming.version)
            ack.msh.msh_9 = 'ACK'
            ack.msh.msh_10 = 'ORACLE-ACK'
            ack.msa.msa_1 = config.get('ack_code', 'AA')
            ack.msa.msa_2 = control
            done.set()
            return ack.to_mllp()

    server = MLLPServer('127.0.0.1', 0, {'ADT^A01': (Handler,), 'ADT^A01^ADT_A01': (Handler,)}, timeout=2)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    publish(config['ready_path'], {'ready': True, 'port': server.server_address[1]})
    try:
        if not done.wait(min(60, config.get('lifetime', 15))):
            raise TimeoutError()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def main():
    config = json.load(sys.stdin)
    result = {'received': [], 'ack_codes': [], 'closed': False, 'ok': False}
    try:
        # Fail dependency gates consistently for every role.
        import hl7
        import hl7apy
        if config['role'] == 'server-hl7apy':
            run_hl7apy(config, result)
        else:
            asyncio.run(asyncio.wait_for(run_async(config, result), min(65, config.get('lifetime', 15) + 3)))
        result['ok'] = True
    except Exception as error:
        result['error'] = type(error).__name__
    publish(config['result_path'], result)
    return 0 if result['ok'] else 2


if __name__ == '__main__':
    sys.exit(main())
