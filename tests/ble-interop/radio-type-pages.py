# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional Bumble radio Read By Type regression; never flashes or resets boards."""
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
from bumble import hci
from bumble.device import Device, DeviceConfiguration, Peer
from bumble.host import Host
from bumble.keys import JsonKeyStore
from bumble.transport.common import BaseSource
from radio_transport import Sink, packets
from att_type_pages import type_pages
from att_transactions import transactions
from att_command_bursts import command_bursts
from att_writable_description import writable_description
from radio_command_overload import exercise as command_overload
from connectable_updates import exercise as connectable_updates
from accept_update_cancel import exercise as accept_update_cancel
from accept_update_exit import exercise as accept_update_exit
from mixed_connectable_updates import exercise as mixed_connectable_updates
from mixed_update_exit import exercise as mixed_update_exit
from mixed_update_win import exercise as mixed_update_win
from mixed_update_lost import exercise as mixed_update_lost

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter-index', type=int, required=True)
    parser.add_argument('--adapter-address', required=True)
    parser.add_argument('--peer-address', required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--mixed-update-lost', choices=('data', 'response'),
                      help='drop one real update reply, require shared failure and fresh GATT recovery')
    mode.add_argument('--mixed-update-win', action='store_true',
                      help='connect during each held update and verify client-exit winner cleanup')
    mode.add_argument('--mixed-update-exit', action='store_true',
                      help='check pending-update client death with a surviving radio connection')
    mode.add_argument('--mixed-connectable-updates', action='store_true',
                      help='check updates with survivor traffic and a second board log')
    parser.add_argument('--survivor-log', type=Path)
    mode.add_argument('--accept-update-exit', action='store_true',
                      help='terminate service clients during held advertising updates and verify recovery')
    mode.add_argument('--accept-update-cancel', action='store_true',
                      help='Observe held-reply accept cancellation at both commands and subsequent GATT recovery')
    mode.add_argument('--connectable-updates', action='store_true',
                      help='Observe payload updates then connect and check GATT on the same session')
    mode.add_argument('--writable-description', action='store_true',
                      help='Check UTF-8 descriptor writes through separate service containers')
    mode.add_argument('--transactions', action='store_true',
                        help='Run multi-attribute prepared transactions at MTU247')
    mode.add_argument('--command-bursts', action='store_true',
                      help='Run 512 Write Commands in 64 bursts at default MTU23')
    mode.add_argument('--command-overload', action='store_true',
                      help='Require managed queue overflow then 64-command service recovery')
    parser.add_argument('--native-overload', action='store_true',
                        help='With --command-overload, require native HCI queue overflow instead')
    parser.add_argument('--authenticated-overload', action='store_true',
                        help='With --command-overload, require authenticated security in each phase')
    parser.add_argument('--bond-phase', choices=('pair', 'resume'),
                        help='Persist or resume authenticated overload keys across separate board boots')
    parser.add_argument('--key-store', type=Path,
                        help='Private Bumble key store required with --bond-phase')
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board-log', 'output'):
        parser.add_argument(f'--{name}', type=Path, required=True)
    args = parser.parse_args()
    if bool(args.mixed_connectable_updates or args.mixed_update_exit or args.mixed_update_win or args.mixed_update_lost) != (args.survivor_log is not None):
        parser.error("mixed update modes require --survivor-log, and only those modes accept it")
    if args.survivor_log is not None and (not args.survivor_log.is_file() or args.survivor_log.stat().st_size):
        parser.error("--survivor-log must be an existing empty file")
    if args.native_overload and not args.command_overload:
        parser.error('--native-overload requires --command-overload')
    if args.authenticated_overload and not args.command_overload:
        parser.error('--authenticated-overload requires --command-overload')
    if args.bond_phase and not (args.command_overload and args.native_overload and
                                args.authenticated_overload):
        parser.error('--bond-phase requires authenticated native command overload')
    if bool(args.key_store) != bool(args.bond_phase):
        parser.error('--key-store is required exactly when --bond-phase is used')
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
    if args.key_store:
        args.key_store = args.key_store.resolve()
    if args.output.exists():
        parser.error('output directory must be new')
    return args

def board_text(path):
    with path.open('rb') as source:
        text = source.read(65537)
    if len(text) > 65536:
        raise RuntimeError('Board log exceeded bounded fixture size')
    # Preserve the raw capture; USB serial startup may contain non-UTF8 noise.
    text = text.decode('utf-8', errors='replace')
    marker = '[toit] INFO: starting '
    if marker not in text:
        return ''
    if text.count(marker) != 1:
        raise RuntimeError('Unexpected additional board boot')
    return text[text.index(marker):]

def emit(**fields):
    print(json.dumps(fields), flush=True)

async def board_marker(board, marker, seconds=25):
    async with asyncio.timeout(seconds):
        while marker not in board_text(board):
            await asyncio.sleep(0.05)

class LinuxHost(Host):
    async def reset(self, driver_factory=None):
        await super().reset(driver_factory=None)

async def exercise(args, device):
    if args.mixed_update_lost:
        return await mixed_update_lost(args, device, board_marker, board_text, emit)
    if args.mixed_update_win:
        return await mixed_update_win(args, device, board_marker, board_text, emit)
    if args.mixed_update_exit:
        return await mixed_update_exit(args, device, board_marker, board_text, emit)
    if args.mixed_connectable_updates:
        return await mixed_connectable_updates(args, device, board_marker, board_text, emit)
    if args.accept_update_exit:
        return await accept_update_exit(args, device, board_marker, board_text, emit)
    if args.accept_update_cancel:
        return await accept_update_cancel(args, device, board_marker, board_text, emit)
    if args.connectable_updates:
        return await connectable_updates(args, device, board_marker, board_text, emit)
    if args.command_overload:
        return await command_overload(args, device, board_marker, board_text, emit)
    emit(event='ready', role='central', test='writable-description' if args.writable_description else
         'command-bursts' if args.command_bursts else
         ('transactions' if args.transactions else 'read-by-type-pages'))
    await board_marker(args.board_log, 'WRITABLE_DESCRIPTION_APP ADVERTISING' if args.writable_description else
                       'COMMAND_BURSTS_APP ADVERTISING' if args.command_bursts else 'TYPE_PAGES READY')
    connection = await device.connect(
        hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS),
        own_address_type=hci.OwnAddressType.PUBLIC, timeout=15)
    emit(event='connected', peer=str(connection.peer_address), handle=connection.handle)
    connection.on(connection.EVENT_DISCONNECTION,
                  lambda reason: emit(event='disconnected', reason=int(reason)))
    try:
        if args.writable_description:
            await writable_description(Peer(connection).gatt_client)
        elif args.command_bursts:
            await command_bursts(Peer(connection).gatt_client)
        elif args.transactions:
            await transactions(Peer(connection).gatt_client, 247)
        else:
            await type_pages(Peer(connection).gatt_client)
    except BaseException as error:
        emit(event='exchange-failed', error=type(error).__name__)
        try:
            async with asyncio.timeout(5):
                await connection.disconnect()
        except Exception as cleanup_error:
            emit(event='cleanup-failed', error=type(cleanup_error).__name__)
        # Keep the serial capture alive for the board's own accept deadline
        # and teardown records. A peer failure is never converted into PASS.
        try:
            await board_marker(args.board_log, 'entering deep sleep without wakeup time', seconds=35)
        except Exception as board_error:
            emit(event='board-terminal-missing', error=type(board_error).__name__)
        raise
    else:
        await connection.disconnect()
    await board_marker(args.board_log, 'entering deep sleep without wakeup time')
    text = board_text(args.board_log).replace('\r', '')
    if args.writable_description:
        complete = re.findall(r'^WRITABLE_DESCRIPTION_APP COMPLETE writes=3 retained=true full-gcs=(\d+)$', text, re.M)
        if len(complete) != 1 or int(complete[0]) < 60:
            raise RuntimeError('Incomplete writable description application verdict')
        for marker in ('WRITABLE_DESCRIPTION_PROVIDER COMPLETE',
                       'WRITABLE_DESCRIPTION_SUPERVISOR COMPLETE groups=2 exits=0'):
            if text.splitlines().count(marker) != 1:
                raise RuntimeError('Incomplete writable description container teardown')
        if 'EXCEPTION' in text or 'Controller disable failed' in text or 'Controller deinit failed' in text:
            raise RuntimeError('Board cleanup failed')
        emit(event='writable-description', writes=3, max_bytes=512, malformed_writes=4,
             atomic_rejection=True, split_utf8=True, mtu=247, full_gcs=int(complete[0]))
        return
    if args.command_bursts:
        complete = re.findall(r'^COMMAND_BURSTS_APP COMPLETE received=512 retained=4 full-gcs=(\d+) elapsed-us=(\d+)$', text, re.M)
        if len(complete) != 1 or int(complete[0][0]) < 512 or 'VHCI_SERVICE COMPLETE' not in text:
            raise RuntimeError('Incomplete command burst application/provider verdict')
        if 'EXCEPTION' in text or 'Controller disable failed' in text or 'Controller deinit failed' in text:
            raise RuntimeError('Board cleanup failed')
        emit(event='command-bursts', commands=512, bursts=64, mtu=23,
             full_gcs=int(complete[0][0]), elapsed_us=int(complete[0][1]))
        return
    expected_writes = 2 if args.transactions else 32
    minimum_reads = 18 if args.transactions else 64
    minimum_gcs = 20 if args.transactions else 96
    complete = re.findall(rf'^TYPE_PAGES COMPLETE reads=(\d+) writes={expected_writes} full-gcs=(\d+)$', text, re.M)
    if len(complete) != 1 or int(complete[0][0]) < minimum_reads or int(complete[0][1]) < minimum_gcs:
        raise RuntimeError('Incomplete board read/write/GC verdict')
    if 'EXCEPTION' in text or 'Controller disable failed' in text or 'Controller deinit failed' in text:
        raise RuntimeError('Board cleanup failed')
    if args.transactions:
        emit(event='transactions', transactions=3, mtu=247, reads=int(complete[0][0]),
             writes=expected_writes, full_gcs=int(complete[0][1]))
    else:
        emit(event='type-pages', pairs=16, characteristic_groups=2, mtu=517, reads=int(complete[0][0]),
             writes=expected_writes, full_gcs=int(complete[0][1]))

async def main(args):
    if importlib.metadata.version('bumble') != '0.0.234':
        raise RuntimeError('Expected Bumble 0.0.234; install the optional requirements')
    logging.disable(logging.CRITICAL)
    args.output.mkdir(parents=True, exist_ok=False)
    configuration = {'adapter_index': args.adapter_index, 'adapter_address': args.adapter_address,
                     'peer_address': args.peer_address, 'bumble': '0.0.234',
                     'transactions': args.transactions,
                     'connectable_updates': args.connectable_updates,
                     'accept_update_cancel': args.accept_update_cancel,
                     'accept_update_exit': args.accept_update_exit,
                     'mixed_connectable_updates': args.mixed_connectable_updates,
                     'mixed_update_exit': args.mixed_update_exit,
                     'mixed_update_win': args.mixed_update_win,
                     'mixed_update_lost': args.mixed_update_lost,
                     'writable_description': args.writable_description,
                     'command_bursts': args.command_bursts,
                     'command_overload': args.command_overload,
                     'native_overload': args.native_overload,
                     'authenticated_overload': args.authenticated_overload,
                     'bond_phase': args.bond_phase,
                     'key_store': str(args.key_store) if args.key_store else None,
                     'artifacts': {name: {'path': str(getattr(args, name)),
                         'sha256': hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                         for name in ('vm', 'supervisor', 'policy', 'relay')},
                     'sources': {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                         for name in ('radio-type-pages.py', 'radio_transport.py', 'att_type_pages.py', 'att_transactions.py', 'att_command_bursts.py', 'att_writable_description.py', 'radio_command_overload.py', 'connectable_updates.py', 'accept_update_cancel.py', 'accept_update_exit.py', 'mixed_connectable_updates.py', 'mixed_update_exit.py', 'mixed_update_win.py', 'mixed_update_lost.py')}}
    (args.output / 'configuration.json').write_text(json.dumps(configuration, indent=2) + '\n')
    key_store = None
    if args.bond_phase:
        os.umask(0o077)
        if args.bond_phase == 'pair':
            descriptor = os.open(args.key_store, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as output:
                output.write('{}\n')
        elif not args.key_store.is_file():
            raise RuntimeError('Missing retained independent bond')
        key_store = JsonKeyStore(namespace='toit-command-overload',
                                 filename=str(args.key_store))
        if bool(await key_store.get_all()) != (args.bond_phase == 'resume'):
            raise RuntimeError('Wrong independent bond phase')
    with (args.output / 'supervisor.log').open('wb') as errors:
        process = await asyncio.create_subprocess_exec(
            args.supervisor, str(args.adapter_index), args.adapter_address,
            args.vm, args.policy, '--', args.vm, args.relay, str(args.adapter_index), '180',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=errors, start_new_session=True)
        source = BaseSource()
        sink = Sink(process.stdin)
        device = Device(config=DeviceConfiguration(name='Toit type-page reference', classic_enabled=False),
                        host=LinuxHost(source, sink))
        if key_store: device.keystore = key_store
        incoming = asyncio.create_task(packets(process.stdout, source))
        try:
            async with asyncio.timeout(180 if args.mixed_update_exit or args.mixed_update_win or args.mixed_update_lost else 100):
                await device.power_on()
                if str(device.public_address).split('/')[0].upper() != args.adapter_address:
                    raise RuntimeError('Wrong adapter identity')
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
