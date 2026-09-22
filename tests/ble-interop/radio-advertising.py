# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional Bumble advertising lifecycle check; never flashes or resets boards."""

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
import time

from bumble import hci, smp
from bumble.device import Advertisement, Device, DeviceConfiguration
from bumble.host import Host
from bumble.transport.common import BaseSource
from advertising_sequence import Sequence, board_session
from advertising_updates import UpdateSequence, validate_board, validate_exit_board
from private_advertising_updates import TEST_IRK, PrivateUpdates, select_private
from private_rotation_exit import PrivateRotationExit, select_rotation, validate_rotation_board
from radio_transport import Sink, packets


def emit(**fields):
    print(json.dumps(fields), flush=True)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter-index', type=int, required=True)
    parser.add_argument('--adapter-address', required=True)
    parser.add_argument('--peer-address', required=True)
    parser.add_argument('--updates', action='store_true', help='Verify live payload updates in both broadcast modes')
    parser.add_argument('--update-client-exit', action='store_true',
                        help='Verify both clients exit during an unanswered final update (implies --updates)')
    parser.add_argument('--private-updates', action='store_true',
                        help='Verify updates during one-second RPA rotation with the public fixture IRK')
    parser.add_argument('--private-rotation-exit', action='store_true',
                        help='Verify private-rotation command-boundary client death and recovery')
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board-log', 'output'):
        parser.add_argument(f'--{name}', type=Path, required=True)
    args = parser.parse_args()
    if args.private_rotation_exit and (args.updates or args.private_updates or args.update_client_exit):
        parser.error('private rotation exit uses a separate fixture')
    if args.private_updates and args.update_client_exit:
        parser.error('private updates and pending client exit are separate fixtures')
    if args.update_client_exit or args.private_updates:
        args.updates = True
    if not 0 <= args.adapter_index < 0xffff:
        parser.error('invalid adapter index')
    for name in ('adapter_address', 'peer_address'):
        value = getattr(args, name)
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', value):
            parser.error(f'invalid {name}')
        setattr(args, name, value.upper())
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board_log'):
        path = getattr(args, name).resolve()
        if not path.is_file():
            parser.error(f'missing {name}')
        setattr(args, name, path)
    if args.board_log.stat().st_size:
        parser.error('board log must be empty; start monitor after ready event')
    args.output = args.output.resolve()
    if args.output.exists():
        parser.error('output directory must be new')
    return args


def board_text(path):
    with path.open('rb') as source:
        value = source.read(65537)
    if len(value) > 65536:
        raise RuntimeError('Board log exceeded fixture bound')
    return board_session(value.decode('utf-8', errors='replace').replace('\r', ''))


class LinuxHost(Host):
    async def reset(self, driver_factory=None):
        await super().reset(driver_factory=None)


async def exercise(args, device):
    sequence = (PrivateRotationExit() if args.private_rotation_exit else
                PrivateUpdates() if args.private_updates else
                UpdateSequence(pending_exit=args.update_client_exit) if args.updates else Sequence())
    failure = []
    armed = False
    peer = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    resolver = smp.AddressResolver([(TEST_IRK[::-1], peer)]) if args.private_updates or args.private_rotation_exit else None

    def observed(report):
        if not armed:
            return
        advertisement = Advertisement.from_advertising_report(report)
        if not advertisement:
            return
        try:
            flags = dict(connectable=advertisement.is_connectable,
                         scannable=advertisement.is_scannable,
                         scan_response=advertisement.is_scan_response)
            if resolver:
                select = select_rotation if args.private_rotation_exit else select_private
                if not select(advertisement, peer, resolver):
                    return
                sequence.observe_private(time.monotonic(), bytes(advertisement.data_bytes),
                                         str(advertisement.address), **flags)
            elif advertisement.address == peer:
                sequence.observe(time.monotonic(), bytes(advertisement.data_bytes), **flags)
        except RuntimeError as error:
            if not failure:
                failure.append(str(error))

    device.host.on('advertising_report', observed)
    await device.start_scanning(legacy=True, active=True, filter_duplicates=False,
                                own_address_type=hci.OwnAddressType.PUBLIC)
    try:
        emit(event='ready', peer=args.peer_address, scan='active', filter_duplicates=False)
        async with asyncio.timeout(70):
            # Flashing also starts the app. Ignore that earlier boot while the
            # monitor resets it, and arm against the fresh, initially empty log.
            ready = 'ADVERTISING_UPDATE APPLIED mode=0 phase=0 gc=true' if args.updates else 'ADVERTISING_APP READY mode=0'
            if args.private_rotation_exit:
                ready = 'PRIVATE_ROTATION_EXIT ACTIVE stage=0'
            while ready not in board_text(args.board_log):
                await asyncio.sleep(0.05)
            armed = True
            emit(event='armed', phase=0)
            while 'entering deep sleep without wakeup time' not in board_text(args.board_log):
                if failure:
                    raise RuntimeError(failure[0])
                await asyncio.sleep(0.1)
            # Keep scanning after application shutdown to distinguish cessation
            # from the observer itself stopping. Require repetition in both modes.
            await asyncio.sleep(6)
        if failure:
            raise RuntimeError(failure[0])
        text = board_text(args.board_log)
        markers = ['ADVERTISING_APP READY mode=0', 'ADVERTISING_APP STOPPED mode=0',
                   'ADVERTISING_APP READY mode=1', 'ADVERTISING_APP STOPPED mode=1',
                   'ADVERTISING_APP COMPLETE']
        positions = [text.find(marker) for marker in markers]
        if not args.updates and not args.private_rotation_exit and (any(text.count(marker) != 1 for marker in markers) or positions != sorted(positions)):
            raise RuntimeError('Incomplete or unordered application lifecycle')
        if any(error in text for error in ('EXCEPTION', 'Controller disable failed', 'Controller deinit failed')):
            raise RuntimeError('Board failed')
        if args.private_rotation_exit:
            validate_rotation_board(text)
        elif args.updates:
            if args.update_client_exit:
                validate_exit_board(text)
            else:
                validate_board(text, private=args.private_updates)
        return sequence.finish(time.monotonic())
    finally:
        await device.stop_scanning()


async def main(args):
    if importlib.metadata.version('bumble') != '0.0.234':
        raise RuntimeError('Expected optional Bumble 0.0.234')
    logging.disable(logging.CRITICAL)
    args.output.mkdir(parents=True, exist_ok=False)
    configuration = {
        'adapter_index': args.adapter_index, 'adapter_address': args.adapter_address,
        'peer_address': args.peer_address, 'bumble': '0.0.234',
        'artifacts': {name: {'path': str(getattr(args, name)),
                            'sha256': hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                      for name in ('vm', 'supervisor', 'policy', 'relay')},
        'sources': {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                    for name in ('radio-advertising.py', 'advertising_sequence.py', 'advertising_updates.py',
                                 'private_advertising_updates.py', 'private_rotation_exit.py', 'radio_transport.py')},
        'updates': args.updates, 'update_client_exit': args.update_client_exit,
        'private_updates': args.private_updates, 'private_rotation_exit': args.private_rotation_exit}
    (args.output / 'configuration.json').write_text(json.dumps(configuration, indent=2) + '\n')
    with (args.output / 'supervisor.log').open('wb') as errors:
        process = await asyncio.create_subprocess_exec(
            args.supervisor, str(args.adapter_index), args.adapter_address,
            args.vm, args.policy, '--', args.vm, args.relay, str(args.adapter_index), '120',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=errors, start_new_session=True)
        source = BaseSource()
        sink = Sink(process.stdin)
        device = Device(config=DeviceConfiguration(classic_enabled=False), host=LinuxHost(source, sink))
        incoming = asyncio.create_task(packets(process.stdout, source))
        try:
            async with asyncio.timeout(90):
                await device.power_on()
                if str(device.public_address).split('/')[0].upper() != args.adapter_address:
                    raise RuntimeError('Wrong adapter identity')
                verdict = await exercise(args, device)
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
        result = dict(result='PASS', supervisor_exit=process.returncode,
                      outgoing=sink.count, incoming=received, **verdict)
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        emit(**result)


if __name__ == '__main__':
    asyncio.run(main(parse_args()))
