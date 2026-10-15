# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional Bumble radio parameter-update lifetime tests.

Requires explicit hardware selection and parameter-retry-central firmware,
or late-parameter-response peripheral firmware with --late-responses.
Never flashes, resets or monitors a board. Start its monitor only after the
advertising event (ready for --late-responses); the board log must start empty.
"""
import argparse
import asyncio
import hashlib
import importlib.metadata
import json
import logging
import os
from pathlib import Path
import re
import signal
import struct
from bumble import hci
from bumble.device import Device, DeviceConfiguration, Peer
from bumble.host import Host
from bumble.transport.common import BaseSource
from radio_transport import Sink, packets

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter-index', type=int, required=True)
    parser.add_argument('--adapter-address', required=True)
    parser.add_argument('--peer-address', required=True)
    parser.add_argument('--late-responses', action='store_true',
                        help='Act as central against late-parameter-response.toit peripheral')
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board-log', 'output'):
        parser.add_argument(f'--{name}', type=Path, required=True)
    args = parser.parse_args()
    if not 0 <= args.adapter_index < 0xffff:
        parser.error('adapter index must be between 0 and 65534')
    for name in ('adapter_address', 'peer_address'):
        value = getattr(args, name)
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', value):
            parser.error(f'invalid {name}')
        setattr(args, name, value.upper())
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board_log'):
        path = getattr(args, name).resolve()
        if not path.is_file():
            parser.error(f'missing {name}: {path}')
        setattr(args, name, path)
    if args.board_log.stat().st_size:
        parser.error('board log must be empty; start monitor after reference ready event')
    args.output = args.output.resolve()
    if args.output.exists():
        parser.error('output directory must be new')
    return args

def board_text(path):
    with path.open() as source:
        text = source.read(65537)
    if len(text) > 65536:
        raise RuntimeError('Board log exceeded bounded fixture size')
    return text

def emit(**fields):
    print(json.dumps(fields), flush=True)

async def board_marker(board, marker):
    async with asyncio.timeout(25):
        while marker not in board_text(board):
            await asyncio.sleep(0.05)

class LinuxHost(Host):
    async def reset(self, driver_factory=None):
        await super().reset(driver_factory=None)

async def exercise(args, device):
    connected = asyncio.get_running_loop().create_future()
    device.on(device.EVENT_CONNECTION, lambda connection: connected.set_result(connection))
    responses = asyncio.Queue()
    disconnected = asyncio.Event()
    reads = []
    manager = device.l2cap_channel_manager
    manager.on_l2cap_connection_parameter_update_response = (
        lambda connection, cid, response: responses.put_nowait(bytes(response)))
    def read(connection_handle, pdu):
        if bytes(pdu) != b'\x0a\x03\x00' or len(reads) >= 6:
            raise RuntimeError('Unexpected ATT read')
        response = bytes([0x0b, 42, len(reads)])
        reads.append(response)
        device.send_l2cap_pdu(connection_handle, 4, response)
    manager.register_fixed_channel(4, read)
    await device.start_advertising(own_address_type=hci.OwnAddressType.PUBLIC,
                                   advertising_data=b'\x02\x01\x06')
    emit(event='advertising')
    async with asyncio.timeout(25):
        connection = await connected
    if str(connection.peer_address).split('/')[0].upper() != args.peer_address:
        raise RuntimeError('Unexpected central identity')
    connection.on(connection.EVENT_DISCONNECTION, lambda reason: disconnected.set())
    for round in range(6):
        identifier, interval, latency, result = (
            (7, 12, 0, 0) if round < 2 else
            (8, 12, 512, 1) if round < 4 else (9, 40, 0, 0))
        request = struct.pack('<BBHHHHH', 0x12, identifier, 8, interval, interval, latency, 400)
        connection.send_l2cap_pdu(5, request)
        async with asyncio.timeout(10):
            response = await responses.get()
        if response != bytes([0x13, identifier, 2, 0, result, 0]):
            raise RuntimeError(f'Unexpected response round {round}: {response.hex()}')
        await board_marker(args.board_log, f'PARAM_RETRY ROUND round={round} ')
        if len(reads) != round + 1:
            raise RuntimeError('Missing exact ATT exchange')
        emit(event='parameter-response', round=round, response=response.hex())
    async with asyncio.timeout(10):
        await disconnected.wait()
    await board_marker(args.board_log, 'PARAM_RETRY COMPLETE updates=2 reads=6 retained=6')
    await board_marker(args.board_log, 'entering deep sleep without wakeup time')
    if not responses.empty():
        raise RuntimeError('Unexpected extra signaling response')
    text = board_text(args.board_log)
    rounds = re.findall(r'^PARAM_RETRY ROUND round=(\d+) updates=(\d+) interval=(\d+)$', text, re.M)
    expected_rounds = [(str(i), '1' if i < 4 else '2', '12' if i < 4 else '40') for i in range(6)]
    complete = re.findall(r'^PARAM_RETRY COMPLETE updates=2 reads=6 retained=6 full-gcs=(\d+)$', text, re.M)
    if rounds != expected_rounds or len(complete) != 1 or int(complete[0]) < 6:
        raise RuntimeError('Incomplete board update/GC verdict')
    emit(event='parameter-retries', requests=6, updates=2, reads=6, full_gcs=int(complete[0]))

async def exercise_late_responses(args, device):
    requests = asyncio.Queue(maxsize=4)
    device.l2cap_channel_manager.on_l2cap_connection_parameter_update_request = (
        lambda connection, cid, request:
            requests.put_nowait((connection.handle, cid, bytes(request))))
    emit(event='ready', role='central', test='late-parameter-responses')
    await board_marker(args.board_log, 'LATE_PARAMETER READY peripheral=true')
    reads = 0
    for index in range(3):
        connection = await device.connect(
            hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS),
            own_address_type=hci.OwnAddressType.PUBLIC, timeout=15)
        async with asyncio.timeout(5):
            handle, cid, request = await requests.get()
        if (handle != connection.handle or cid != 5 or
                request != bytes.fromhex('120108000c000c0000009001')):
            raise RuntimeError('Unexpected parameter request')
        if index < 2:
            connection.send_l2cap_pdu(5, bytes([0x13, 1, 2, 0, index, 0]))
        else:
            await asyncio.sleep(0.75)
        peer = Peer(connection)
        for sequence in range(11):
            if sequence == 1:
                connection.send_l2cap_pdu(5, bytes.fromhex('130102000200'))
                connection.send_l2cap_pdu(5, bytes.fromhex('01010200ffff'))
            if bytes(await peer.read_value(3)) != bytes([42, index]):
                raise RuntimeError('ATT read changed after late response')
            reads += 1
        await connection.disconnect()
        await board_marker(args.board_log,
                           f'LATE_PARAMETER ROUND round={index} reads=11 peripheral=true')
        emit(event='late-parameter-round', round=index, reads=11)
    await board_marker(args.board_log, 'entering deep sleep without wakeup time')
    text = board_text(args.board_log).replace('\r', '')
    rounds = re.findall(r'^LATE_PARAMETER ROUND round=(\d+) reads=11 peripheral=true$', text, re.M)
    complete = re.findall(r'^LATE_PARAMETER COMPLETE peripheral=true reads=33 full-gcs=(\d+) retained=0$', text, re.M)
    if rounds != ['0', '1', '2'] or len(complete) != 1 or int(complete[0]) < 33 or reads != 33:
        raise RuntimeError('Incomplete late-response board verdict')
    if not requests.empty():
        raise RuntimeError('Unexpected extra parameter request')
    emit(event='late-parameter-responses', connections=3, reads=reads, full_gcs=int(complete[0]))

async def main(args):
    if importlib.metadata.version('bumble') != '0.0.234':
        raise RuntimeError('Expected Bumble 0.0.234; install the optional requirements')
    logging.disable(logging.CRITICAL)
    args.output.mkdir(parents=True, exist_ok=False)
    configuration = {'adapter_index': args.adapter_index, 'adapter_address': args.adapter_address,
                     'peer_address': args.peer_address, 'bumble': '0.0.234',
                     'late_responses': args.late_responses,
                     'artifacts': {name: {'path': str(getattr(args, name)),
                         'sha256': hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                         for name in ('vm', 'supervisor', 'policy', 'relay')},
                     'sources': {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                         for name in ('radio-parameters.py', 'radio_transport.py')}}
    (args.output / 'configuration.json').write_text(json.dumps(configuration, indent=2) + '\n')
    with (args.output / 'supervisor.log').open('wb') as errors:
        process = await asyncio.create_subprocess_exec(
            args.supervisor, str(args.adapter_index), args.adapter_address,
            args.vm, args.policy, '--', args.vm, args.relay, str(args.adapter_index), '180',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=errors, start_new_session=True)
        source = BaseSource()
        sink = Sink(process.stdin)
        device = Device(config=DeviceConfiguration(name='Toit parameter reference', classic_enabled=False),
                        host=LinuxHost(source, sink))
        incoming = asyncio.create_task(packets(process.stdout, source))
        try:
            async with asyncio.timeout(100):
                await device.power_on()
                if str(device.public_address).split('/')[0].upper() != args.adapter_address:
                    raise RuntimeError('Wrong adapter identity')
                if args.late_responses:
                    await exercise_late_responses(args, device)
                else:
                    await exercise(args, device)
        finally:
            process.stdin.close()
            try:
                await asyncio.wait_for(process.wait(), 15)
            except TimeoutError:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    await asyncio.wait_for(process.wait(), 5)
                except TimeoutError:
                    os.killpg(process.pid, signal.SIGKILL)
                    await process.wait()
            received = await incoming
        if process.returncode != 0 or 'restoration-verified=true' not in (args.output / 'supervisor.log').read_text():
            raise RuntimeError('Supervisor/restoration failed')
        result = {'result': 'PASS', 'supervisor_exit': process.returncode,
                  'outgoing': sink.count, 'incoming': received}
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        emit(**result)

if __name__ == '__main__':
    asyncio.run(main(parse_args()))
