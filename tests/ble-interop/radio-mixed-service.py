# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional Bumble peer for the mixed-role service fixture; never flashes boards."""

import argparse
import asyncio
import hashlib
import importlib.metadata
import json
import logging
import os
from pathlib import Path
import re
import secrets
import signal
import time

from bumble import att, gatt, hci
from bumble.core import UUID
from bumble.device import Device, DeviceConfiguration, Peer
from bumble.host import Host
from bumble.keys import JsonKeyStore
from bumble.pairing import PairingConfig, PairingDelegate
from bumble.transport.common import BaseSource
from radio_transport import Sink, packets
from radio_command_overload import require_authenticated, require_stored_authenticated


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter-index', type=int, required=True)
    parser.add_argument('--adapter-address', required=True)
    parser.add_argument('--peer-address', required=True)
    parser.add_argument('--role', choices=('central', 'peripheral'), default='central')
    parser.add_argument('--authenticated', action='store_true',
                        help='Fresh Numeric Comparison and protected reads')
    parser.add_argument('--bond-phase', choices=('pair', 'resume'),
                        help='Persist first central pairing or resume existing bonds without pairing')
    parser.add_argument('--key-store', type=Path, help='Private JSON file required with --bond-phase')
    parser.add_argument('--private-peer', action='store_true',
                        help='Exchange IRKs, then rotate this peer RPA between resumed links')
    parser.add_argument('--local-irk', type=Path, help='Private persistent IRK file for --private-peer')
    parser.add_argument('--peer-log', '--incoming-log', dest='peer_log', type=Path,
                        help='Initially empty other S3 log; required for peripheral role or authentication')
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board-log', 'output'):
        parser.add_argument(f'--{name}', type=Path, required=True)
    args = parser.parse_args()
    if args.bond_phase and not args.authenticated:
        parser.error('--bond-phase requires --authenticated')
    if args.role == 'peripheral' and args.bond_phase == 'pair':
        parser.error('peripheral bond mode requires existing bonds and --bond-phase resume')
    if bool(args.key_store) != bool(args.bond_phase):
        parser.error('--key-store is required exactly with --bond-phase')
    if args.key_store:
        args.key_store = args.key_store.resolve()
    if args.private_peer and not args.bond_phase:
        parser.error('--private-peer requires --bond-phase')
    if bool(args.local_irk) != args.private_peer:
        parser.error('--local-irk is required exactly with --private-peer')
    if args.local_irk:
        args.local_irk = args.local_irk.resolve()
        if args.local_irk == args.key_store:
            parser.error('IRK and bond files must be separate')
    if not 0 <= args.adapter_index < 0xffff:
        parser.error('invalid adapter index')
    for name in ('adapter_address', 'peer_address'):
        address = getattr(args, name)
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', address):
            parser.error(f'invalid {name}')
        setattr(args, name, address.upper())
    for name in ('vm', 'supervisor', 'policy', 'relay', 'board_log'):
        path = getattr(args, name).resolve()
        if not path.is_file():
            parser.error(f'missing {name}')
        setattr(args, name, path)
    if args.board_log.stat().st_size:
        parser.error('board log must be empty; start boards after reference ready')
    if args.role == 'peripheral' or args.authenticated:
        if args.peer_log is None or not args.peer_log.is_file():
            parser.error('this mode requires --peer-log')
        args.peer_log = args.peer_log.resolve()
        if args.peer_log == args.board_log or args.peer_log.stat().st_size:
            parser.error('peer log must be separate and empty')
    elif args.peer_log is not None:
        parser.error('--peer-log requires peripheral role or authentication')
    args.output = args.output.resolve()
    if args.output.exists():
        parser.error('output directory must be new')
    return args


def emit(**fields):
    print(json.dumps(fields), flush=True)


def board_text(path):
    with path.open('rb') as source:
        raw = source.read(262145)
    if len(raw) > 262144:
        raise RuntimeError('Board log exceeded fixture bound')
    text = raw.decode('utf-8', errors='replace').replace('\r', '')
    boot = '[toit] INFO: starting '
    if boot not in text:
        return ''
    if text.count(boot) != 1:
        raise RuntimeError('Unexpected additional board boot')
    text = text[text.index(boot):]
    if any(error in text for error in ('EXCEPTION', 'ASSERTION_FAILED',
                                       'Controller disable failed', 'Controller deinit failed')):
        raise RuntimeError('Board reported a failure')
    return text


async def board_marker(path, marker, count=1, seconds=40):
    async with asyncio.timeout(seconds):
        while board_text(path).count(marker) < count:
            await asyncio.sleep(0.05)


def validate_owner(text, central_peer='84f703a00b3a', peer_reads=200):
    rounds = re.findall(r'^MIXED_PROVIDER ROUND_COMPLETE peripheral-first=(false|true) '
                        rf'opens=1 closes=1 peer-reads={peer_reads} full-gcs=(\d+)$', text, re.M)
    if [order for order, _ in rounds] != ['false', 'true'] or any(int(gcs) < 2 for _, gcs in rounds):
        raise RuntimeError('Missing ordered controller-lifetime/GC verdicts')
    expectations = {
        f'MIXED_INDEPENDENT CONFIG receive-acl-packets=4 central-peer={central_peer}': 1,
        'MIXED_CENTRAL COMPLETE reads=500': 2,
        'MIXED_CENTRAL CYCLE cycle=0 reads=300': 2,
        'MIXED_CENTRAL CYCLE cycle=1 reads=500': 2,
        'MIXED_PERIPHERAL COMPLETE cycle=0 local-reads=100': 2,
        'MIXED_PERIPHERAL COMPLETE cycle=1 local-reads=100': 2,
        'MIXED_PROVIDER COMPLETE rounds=2': 1,
        '[toit] INFO: entering deep sleep without wakeup time': 1,
    }
    lines = text.splitlines()
    for marker, count in expectations.items():
        if lines.count(marker) != count:
            raise RuntimeError(f'Incorrect board marker count: {marker}')
    return [int(gcs) for _, gcs in rounds]


def validate_incoming(text):
    cycles = re.findall(r'^MIXED_LINUX CYCLE cycle=(\d+) reads=100 reason=19$', text, re.M)
    if cycles != ['0', '1', '2', '3']:
        raise RuntimeError('Missing ordered incoming peer cycles')
    lines = text.splitlines()
    for marker in ('MIXED_INDEPENDENT_INCOMING READY peer=f412fac150fe',
                   'MIXED_LINUX COMPLETE reads=400',
                   'MIXED_INDEPENDENT_INCOMING COMPLETE reads=400 connections=4',
                   '[toit] INFO: entering deep sleep without wakeup time'):
        if lines.count(marker) != 1:
            raise RuntimeError(f'Incorrect incoming peer marker count: {marker}')


def numeric_values(text, role, prefix='MIXED_SECURE_PROVIDER'):
    return [int(value) for value in re.findall(
        rf'^{re.escape(prefix)} NUMERIC role={role} value=(\d{{1,6}}) fixture-approval=true$',
        text, re.M)]


class Numeric(PairingDelegate):
    def __init__(self, board, cycle, role=1, prefix='MIXED_SECURE_PROVIDER'):
        super().__init__(io_capability=self.IoCapability.DISPLAY_OUTPUT_AND_YES_NO_INPUT)
        self.board = board
        self.cycle = cycle
        self.role = role
        self.prefix = prefix
        self.confirmed = False

    async def compare_numbers(self, number, digits):
        if self.confirmed:
            raise RuntimeError('Unexpected repeated pairing approval')
        async with asyncio.timeout(10):
            while True:
                values = numeric_values(board_text(self.board), self.role, self.prefix)
                if len(values) > self.cycle:
                    if len(values) != self.cycle + 1 or values[-1] != number:
                        raise RuntimeError('Numeric Comparison mismatch or unexpected extra pairing')
                    self.confirmed = True
                    emit(event='numeric-comparison', cycle=self.cycle, matched=True)
                    return True
                await asyncio.sleep(0.05)


def validate_owner_security(owner):
    rounds = re.findall(r'^MIXED_SECURE_PROVIDER ROUND_SECURITY peripheral-first=(false|true) pairings=3$',
                        owner, re.M)
    if rounds != ['false', 'true']:
        raise RuntimeError('Missing ordered provider security cleanup verdicts')
    for role, count in ((0, 2), (1, 4)):
        marker = f'MIXED_SECURE_PROVIDER SECURED role={role} encrypted=true authenticated=true'
        if owner.splitlines().count(marker) != count or len(numeric_values(owner, role)) != count:
            raise RuntimeError('Incorrect provider pairing/authentication counts')


def validate_security(owner, peer):
    validate_owner_security(owner)
    comparisons = re.findall(r'^MIXED_SECURE_PEER NUMERIC cycle=(\d) value=(\d{1,6}) fixture-approval=true$',
                             peer, re.M)
    if [cycle for cycle, _ in comparisons] != ['0', '1'] or [int(value) for _, value in comparisons] != numeric_values(owner, 0):
        raise RuntimeError('Outgoing peer Numeric Comparisons do not match')
    secured = re.findall(r'^MIXED_SECURE_PEER SECURED cycle=(\d) encrypted=true authenticated=true$', peer, re.M)
    completed = re.findall(r'^MIXED_SECURE_PEER CYCLE_COMPLETE cycle=(\d)$', peer, re.M)
    if secured != ['0', '1'] or completed != ['0', '1']:
        raise RuntimeError('Missing authenticated outgoing peer cycles')
    for marker in ('MIXED_SECURE_PEER COMPLETE cycles=2',
                   'MIXED_INDEPENDENT_AUTH_PEER COMPLETE protected-reads=1000 connections=2 closes=1',
                   '[toit] INFO: entering deep sleep without wakeup time'):
        if peer.splitlines().count(marker) != 1:
            raise RuntimeError(f'Incorrect authenticated peer marker count: {marker}')


def validate_secure_incoming(owner, peer):
    validate_owner_security(owner)
    comparisons = re.findall(r'^MIXED_SECURE_LINUX NUMERIC cycle=(\d) value=(\d{1,6}) fixture-approval=true$',
                             peer, re.M)
    if [cycle for cycle, _ in comparisons] != ['0', '1', '2', '3'] or [int(value) for _, value in comparisons] != numeric_values(owner, 1):
        raise RuntimeError('Incoming peer Numeric Comparisons do not match')
    cycles = re.findall(r'^MIXED_SECURE_LINUX CYCLE cycle=(\d) protected-reads=100 denied=1 reason=19$',
                        peer, re.M)
    if cycles != ['0', '1', '2', '3']:
        raise RuntimeError('Missing ordered authenticated incoming cycles')
    for marker in ('MIXED_INDEPENDENT_AUTH_INCOMING READY peer=f412fac150fe',
                   'MIXED_SECURE_LINUX COMPLETE protected-reads=400 denied=4',
                   'MIXED_INDEPENDENT_AUTH_INCOMING COMPLETE protected-reads=400 denied=4 connections=4',
                   '[toit] INFO: entering deep sleep without wakeup time'):
        if peer.splitlines().count(marker) != 1:
            raise RuntimeError(f'Incorrect authenticated incoming marker count: {marker}')


def validate_bond(owner, peer, phase, reverse=False):
    resume = phase == 'resume'
    if reverse and not resume:
        raise RuntimeError('Reverse bond fixture requires resumption')
    flag = str(resume).lower()
    peer_resumed = 4 if reverse else (2 if resume else 1)
    peer_mode = 'INCOMING' if reverse else 'PEER'
    peer_markers = (('MIXED_INDEPENDENT_BOND_INCOMING COMPLETE protected-reads=400 denied=4 connections=4',)
                    if reverse else ('MIXED_SECURE_PEER COMPLETE cycles=2',
                                     'MIXED_INDEPENDENT_BOND_PEER COMPLETE protected-reads=1000 connections=2 closes=1'))
    for text, marker in (
        (owner, f'MIXED_INDEPENDENT_BOND OWNER resume-only={flag}'),
        (owner, f'MIXED_RESUME S3 COMPLETE fresh={0 if resume else 2} resumed={6 if resume else 4} stored=2 unchanged={flag}'),
        (peer, f'MIXED_INDEPENDENT_BOND {peer_mode} resume-only={flag}'),
        (peer, f'MIXED_RESUME PEER COMPLETE fresh={0 if resume else 1} resumed={peer_resumed} stored=1 unchanged={flag}'),
        (peer, '[toit] INFO: entering deep sleep without wakeup time'),
    ):
        if text.splitlines().count(marker) != 1:
            raise RuntimeError(f'Incorrect bond fixture verdict: {marker}')
    for marker in peer_markers:
        if peer.splitlines().count(marker) != 1:
            raise RuntimeError(f'Incorrect bond peer verdict: {marker}')
    if reverse:
        cycles = re.findall(r'^MIXED_RESUME LINUX CYCLE cycle=(\d) protected-reads=100 denied=1$', peer, re.M)
        if cycles != ['0', '1', '2', '3']:
            raise RuntimeError('Missing reverse bond incoming cycles')
    if resume and any(' NUMERIC ' in text or ' SAVED ' in text for text in (owner, peer)):
        raise RuntimeError('Unexpected pairing or save during resumption')
    for role, count in ((0, 2 if resume else 1), (1, 4 if resume else 3)):
        if owner.splitlines().count(f'MIXED_RESUME S3 RESUMED role={role} authenticated=true') != count:
            raise RuntimeError('Incorrect owner resumption counts')
    if peer.splitlines().count(f'MIXED_RESUME PEER RESUMED role={0 if reverse else 1} authenticated=true') != peer_resumed:
        raise RuntimeError('Incorrect peer resumption counts')
    outgoing = numeric_values(owner, 0, 'MIXED_RESUME S3')
    incoming = numeric_values(owner, 1, 'MIXED_RESUME S3')
    other = numeric_values(peer, 1, 'MIXED_RESUME PEER')
    if len(outgoing) != int(not resume) or len(incoming) != int(not resume) or other != outgoing:
        raise RuntimeError('Unexpected bond pairing or mismatched outgoing comparison')
    for text, label, slots in ((owner, 'S3', ['0', '1']), (peer, 'PEER', ['0'])):
        saved = re.findall(rf'^MIXED_RESUME {label} SAVED slot=(\d+) authenticated=true$', text, re.M)
        if saved != ([] if resume else slots):
            raise RuntimeError('Unexpected bond storage changes')


async def open_bond_store(path, phase):
    if phase == 'pair':
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            output.write('{}\n')
    if path.stat().st_mode & 0o777 != 0o600 or path.stat().st_size > 16384:
        raise RuntimeError('Expected a bounded private reference key store')
    original = path.read_bytes()
    store = JsonKeyStore(namespace='toit-mixed-radio', filename=str(path))
    if len(await store.get_all()) != (1 if phase == 'resume' else 0):
        raise RuntimeError('Wrong independent bond storage phase')
    return store, original


def require_resumed(connection, stored, keys):
    if not connection.is_encrypted or keys:
        raise RuntimeError('Missing encryption or unexpected fresh pairing during resumption')
    key = stored.ltk if stored else None
    if not key or not key.authenticated or len(key.value) != 16:
        raise RuntimeError('Missing authenticated retained pairing key')


def reject_pairing(connection):
    raise RuntimeError('Fresh pairing forbidden during bond resumption')


async def exercise_peripheral(args, device):
    identity = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    completed = asyncio.Queue(maxsize=4)
    records = []
    active = None
    keys = []
    numeric = None
    stored = None
    private_addresses = []
    if args.bond_phase:
        await require_stored_authenticated(device, identity)
        stored = await device.keystore.get(str(identity))
        if args.private_peer and (not stored.irk or len(stored.irk.value) != 16 or
                                 stored.irk.value == bytes(16)):
            raise RuntimeError('Missing exchanged peer IRK')

    def fail(message):
        if not completed.full():
            completed.put_nowait(RuntimeError(message))

    def connected(connection):
        nonlocal active
        if connection.peer_address != identity or active is not None or len(records) >= 2:
            fail('Unexpected outgoing central connection')
            return
        record = {'cycle': len(records), 'reads': 0, 'started': time.monotonic_ns()}
        records.append(record)
        active = connection

        def disconnected(reason):
            nonlocal active
            active = None
            record['reason'] = int(reason)
            record['elapsed_us'] = (time.monotonic_ns() - record.pop('started')) // 1000
            if not completed.full():
                completed.put_nowait(record)

        connection.on(connection.EVENT_DISCONNECTION, disconnected)
        if args.authenticated:
            connection.on(connection.EVENT_PAIRING, keys.append)
            connection.on(connection.EVENT_PAIRING_FAILURE,
                          lambda reason: fail(f'Independent peripheral pairing failed: {int(reason)}'))
        emit(event='connected', cycle=record['cycle'], peer=str(connection.peer_address),
             handle=connection.handle)

    def read_value(connection):
        if connection is not active or not records or records[-1]['reads'] >= 500:
            fail('Unexpected outgoing value read')
            raise att.ATT_Error(att.ATT_UNLIKELY_ERROR_ERROR)
        if args.authenticated:
            try:
                if args.bond_phase:
                    require_resumed(connection, stored, keys)
                else:
                    require_authenticated(connection, numeric, keys)
            except RuntimeError as error:
                fail(str(error))
                raise att.ATT_Error(att.ATT_INSUFFICIENT_AUTHENTICATION_ERROR) from error
            records[-1]['authenticated'] = True
            records[-1]['key_bytes'] = 16
        records[-1]['reads'] += 1
        return b'Toit HCI'

    if args.authenticated:
        readable = gatt.Characteristic(
            'FFF2', gatt.Characteristic.Properties.READ,
            gatt.Characteristic.Permissions.READABLE |
            gatt.Characteristic.Permissions.READ_REQUIRES_ENCRYPTION |
            gatt.Characteristic.Permissions.READ_REQUIRES_AUTHENTICATION,
            value=gatt.CharacteristicValue(read=read_value))
        device.add_service(gatt.Service('FFF0', [readable]))
        if readable.handle != 16:
            raise RuntimeError('Unexpected Bumble protected handle')
    else:
        readable = device.gatt_server.get_attribute(3)
        if readable is None or readable.type != UUID.from_16_bits(0x2A00):
            raise RuntimeError('Unexpected Bumble Name handle')
        readable.value = gatt.CharacteristicValue(read=read_value)
    device.on(device.EVENT_CONNECTION, connected)
    for cycle in range(2):
        keys = []
        if args.bond_phase:
            device.pairing_config_factory = reject_pairing
        elif args.authenticated:
            numeric = Numeric(args.board_log, cycle, role=0)
            if len(numeric_values(board_text(args.board_log), 0)) != cycle:
                raise RuntimeError('Unexpected pairing before this outgoing connection')
            device.pairing_config_factory = lambda connection: PairingConfig(
                sc=True, mitm=True, bonding=False, delegate=numeric)
        own_type = hci.OwnAddressType.PUBLIC
        if args.private_peer:
            private_addresses.append(await rotate_private_address(device))
            own_type = hci.OwnAddressType.RANDOM
            emit(event='private-address', cycle=cycle, address=private_addresses[-1])
        await device.start_advertising(own_address_type=own_type,
                                      advertising_data=(b'\x02\x01\x06' +
                                                        (b'\x03\x03\xf0\xff' if args.private_peer else b'')))
        if cycle == 0:
            emit(event='ready', role='peripheral', test='mixed-service', value_handle=readable.handle)
        async with asyncio.timeout(140):
            record = await completed.get()
        if isinstance(record, Exception):
            raise record
        if record['cycle'] != cycle or record['reads'] != 500 or record['reason'] != 0x13:
            raise RuntimeError(f'Incorrect independent peripheral verdict: {record}')
        if args.authenticated:
            if args.bond_phase:
                if keys or not record.get('authenticated'):
                    raise RuntimeError('Missing independent peripheral resumption')
                record['resumed'] = True
            elif not numeric.confirmed or len(keys) != 1 or not record.get('authenticated'):
                raise RuntimeError('Missing independent peripheral authentication')
        emit(event='cycle-complete', **record)
    await board_marker(args.board_log, 'entering deep sleep without wakeup time', seconds=70)
    await board_marker(args.peer_log, 'entering deep sleep without wakeup time', seconds=70)
    gcs = validate_owner(board_text(args.board_log), args.adapter_address.replace(':', '').lower(),
                         peer_reads=202 if args.authenticated else 200)
    if args.bond_phase:
        validate_bond(board_text(args.board_log), board_text(args.peer_log), args.bond_phase, reverse=True)
    elif args.authenticated:
        validate_secure_incoming(board_text(args.board_log), board_text(args.peer_log))
    else:
        validate_incoming(board_text(args.peer_log))
    if not completed.empty() or len(records) != 2:
        raise RuntimeError('Unexpected extra peripheral events')
    if args.private_peer:
        validate_private_peer(board_text(args.board_log), private_addresses,
                              args.adapter_address.replace(':', '').lower(), count=2, discovered=True)
    return {'cycles': 2, 'reads': 1000, 'provider_full_gcs': gcs,
            'connections': records, 'incoming_peer_reads': 400,
            'authenticated': args.authenticated, 'pre_pairing_denials': 4 if args.authenticated else 0,
            'bond_phase': args.bond_phase, 'private_peer_addresses': private_addresses}


class LinuxHost(Host):
    async def reset(self, driver_factory=None):
        await super().reset(driver_factory=None)


def local_irk(path, phase):
    if phase == 'pair':
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(secrets.token_bytes(16))
    if path.stat().st_mode & 0o777 != 0o600 or path.stat().st_size != 16:
        raise RuntimeError('Expected a private 16-byte local IRK file')
    return path.read_bytes()


def validate_private_peer(text, addresses, identity, count=4, discovered=False):
    observed = re.findall(r'^MIXED_RESUME S3 PRIVATE peer=([0-9a-f]{12}) identity=([0-9a-f]{12}) resolved=true$',
                          text, re.M)
    if (len(addresses) != count or len(set(addresses)) != count or
            any(not hci.Address(address, hci.Address.RANDOM_DEVICE_ADDRESS).is_resolvable
                for address in addresses) or
            observed != [(address, identity) for address in addresses]):
        raise RuntimeError('Rotating private peer addresses did not match Toit bond resolution')
    if discovered:
        scanned = re.findall(r'^MIXED_PRIVATE_DISCOVERED peer=([0-9a-f]{12}) identity=([0-9a-f]{12}) stopped=true$',
                             text, re.M)
        if scanned != observed:
            raise RuntimeError('Private peer discovery did not match authenticated connections')


async def rotate_private_address(device):
    address = hci.Address.generate_private_address(device.irk)
    # Set the exact generated address: the pinned Bumble update_rpa
    # implementation sends its previous address before updating its field.
    await device.send_sync_command(hci.HCI_LE_Set_Random_Address_Command(random_address=address))
    device.random_address = address
    return str(address).split('/')[0].replace(':', '').lower()


async def exercise(args, device):
    emit(event='ready', role='central', test='mixed-service')
    retained = []
    elapsed = []
    private_addresses = []
    identity = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    for cycle in range(4):
        await board_marker(args.board_log, f'MIXED_PERIPHERAL ACCEPT_READY cycle={cycle % 2}',
                           count=cycle // 2 + 1, seconds=70)
        fresh = not args.bond_phase or (args.bond_phase == 'pair' and cycle == 0)
        prefix = 'MIXED_RESUME S3' if args.bond_phase else 'MIXED_SECURE_PROVIDER'
        numeric = Numeric(args.board_log, cycle, prefix=prefix)
        if args.bond_phase and not fresh:
            device.pairing_config_factory = reject_pairing
        elif args.authenticated:
            if len(numeric_values(board_text(args.board_log), 1, prefix)) != cycle:
                raise RuntimeError('Unexpected pairing before this incoming connection')
            device.pairing_config_factory = lambda connection: PairingConfig(
                sc=True, mitm=True, bonding=bool(args.bond_phase), delegate=numeric,
                identity_address_type=hci.Address.PUBLIC_DEVICE_ADDRESS)
        started = time.monotonic_ns()
        own_type = hci.OwnAddressType.PUBLIC
        if args.private_peer and args.bond_phase == 'resume':
            own_type = hci.OwnAddressType.RANDOM
            private_addresses.append(await rotate_private_address(device))
            emit(event='private-address', cycle=cycle, address=private_addresses[-1])
        connection = await device.connect(
            identity,
            own_address_type=own_type, timeout=40)
        disconnected = asyncio.get_running_loop().create_future()

        def on_disconnected(reason):
            if not disconnected.done():
                disconnected.set_result(int(reason))

        connection.on(connection.EVENT_DISCONNECTION, on_disconnected)
        keys = []
        connection.on(connection.EVENT_PAIRING, keys.append)
        emit(event='connected', cycle=cycle, peer=str(connection.peer_address), handle=connection.handle)
        try:
            peer = Peer(connection)
            mtu = await peer.request_mtu(247)
            if mtu != 247:
                raise RuntimeError(f'Unexpected negotiated MTU: {mtu}')
            await peer.discover_services()
            await peer.discover_characteristics()
            names = peer.get_characteristics_by_uuid(UUID.from_16_bits(0x2A00))
            controls = peer.get_characteristics_by_uuid(UUID.from_16_bits(0xFFF1))
            if len(names) != 1 or names[0].handle != 3 or len(controls) != 1 or controls[0].handle != (14 if args.authenticated else 12):
                raise RuntimeError('Unexpected discovered service layout')
            readable = names[0]
            if args.authenticated:
                protected = peer.get_characteristics_by_uuid(UUID.from_16_bits(0xFFF2))
                if len(protected) != 1 or protected[0].handle != 12:
                    raise RuntimeError('Unexpected protected characteristic layout')
                readable = protected[0]
                try:
                    await readable.read_value()
                except att.ATT_Error as error:
                    if error.error_code != att.ATT_INSUFFICIENT_AUTHENTICATION_ERROR:
                        raise
                else:
                    raise RuntimeError('Protected value was accessible before pairing')
                async with asyncio.timeout(20):
                    if fresh:
                        await connection.pair()
                    else:
                        await connection.encrypt()
                if fresh:
                    require_authenticated(connection, numeric, keys)
                elif not connection.is_encrypted or keys or numeric.confirmed:
                    raise RuntimeError('Missing encryption or unexpected fresh pairing during resumption')
                if args.bond_phase:
                    await require_stored_authenticated(device, identity)
                    stored = await device.keystore.get(str(identity))
                    if args.private_peer and (not stored.irk or len(stored.irk.value) != 16 or
                                             stored.irk.value == bytes(16)):
                        raise RuntimeError('Missing exchanged peer IRK')
                emit(event='authenticated', cycle=cycle, denied=1,
                     pairing='secure-connections' if fresh else 'forbidden',
                     encrypted=True, authenticated_key_bytes=16, bonded=bool(args.bond_phase),
                     resumed=not fresh)
            for index in range(100):
                if args.authenticated:
                    if fresh:
                        require_authenticated(connection, numeric, keys)
                    elif not connection.is_encrypted or keys:
                        raise RuntimeError('Resumed authenticated link lost')
                value = await readable.read_value()
                if value != b'Toit HCI':
                    raise RuntimeError('Incorrect GATT value')
                if index == 0:
                    retained.append(value)
            if retained != [b'Toit HCI'] * (cycle + 1):
                raise RuntimeError('Retained GATT value changed')
            # Secure fixture closes immediately; observed disconnect acknowledges
            # its command, so an ATT write response cannot race that close.
            await controls[0].write_value(b'\x01', with_response=not args.authenticated)
            async with asyncio.timeout(35):
                reason = await asyncio.shield(disconnected)
            if reason != 0x13:
                raise RuntimeError(f'Unexpected remote disconnect reason: {reason}')
        finally:
            if not disconnected.done():
                async with asyncio.timeout(5):
                    await connection.disconnect()
        elapsed.append((time.monotonic_ns() - started) // 1000)
        emit(event='cycle-complete', cycle=cycle, reads=100, mtu=mtu,
             reason=reason, elapsed_us=elapsed[-1])
    await board_marker(args.board_log, 'entering deep sleep without wakeup time', seconds=70)
    gcs = validate_owner(board_text(args.board_log), peer_reads=202 if args.authenticated else 200)
    if args.authenticated:
        await board_marker(args.peer_log, 'entering deep sleep without wakeup time', seconds=70)
        if args.bond_phase:
            validate_bond(board_text(args.board_log), board_text(args.peer_log), args.bond_phase)
        else:
            validate_security(board_text(args.board_log), board_text(args.peer_log))
    if args.private_peer and args.bond_phase == 'resume':
        validate_private_peer(board_text(args.board_log), private_addresses,
                              args.adapter_address.replace(':', '').lower())
    return {'cycles': 4, 'reads': 400, 'mtu': 247, 'provider_full_gcs': gcs,
            'cycle_elapsed_us': elapsed, 'retained_values': len(retained),
            'authenticated': args.authenticated, 'pre_pairing_denials': 4 if args.authenticated else 0,
            'bond_phase': args.bond_phase, 'private_peer_addresses': private_addresses}


async def main(args):
    if importlib.metadata.version('bumble') != '0.0.234':
        raise RuntimeError('Expected optional Bumble 0.0.234')
    logging.disable(logging.CRITICAL)
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    configuration = {
        'adapter_index': args.adapter_index, 'adapter_address': args.adapter_address,
        'peer_address': args.peer_address, 'bumble': '0.0.234', 'provider_receive_credits': 4,
        'reference_role': args.role,
        'authenticated': args.authenticated,
        'bond_phase': args.bond_phase,
        'private_peer': args.private_peer,
        'artifacts': {name: {'path': str(getattr(args, name)),
                            'sha256': hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()}
                      for name in ('vm', 'supervisor', 'policy', 'relay')},
        'sources': {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                    for name in ('radio-mixed-service.py', 'radio_transport.py', 'radio_command_overload.py')},
    }
    (args.output / 'configuration.json').write_text(json.dumps(configuration, indent=2) + '\n')
    store = None
    original_store = None
    if args.bond_phase:
        store, original_store = await open_bond_store(args.key_store, args.bond_phase)
    config = DeviceConfiguration(name='Mixed service reference', classic_enabled=False)
    if args.private_peer:
        config.irk = local_irk(args.local_irk, args.bond_phase)
    with (args.output / 'supervisor.log').open('wb') as errors:
        process = await asyncio.create_subprocess_exec(
            args.supervisor, str(args.adapter_index), args.adapter_address,
            args.vm, args.policy, '--', args.vm, args.relay, str(args.adapter_index), '360',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=errors, start_new_session=True)
        source = BaseSource()
        sink = Sink(process.stdin)
        device = Device(config=config,
                        host=LinuxHost(source, sink))
        if store is not None:
            device.keystore = store
        incoming = asyncio.create_task(packets(process.stdout, source))
        try:
            async with asyncio.timeout(300):
                await device.power_on()
                if str(device.public_address).split('/')[0].upper() != args.adapter_address:
                    raise RuntimeError('Wrong adapter identity')
                result = await (exercise_peripheral(args, device) if args.role == 'peripheral'
                                else exercise(args, device))
                if args.bond_phase:
                    if len(await store.get_all()) != 1:
                        raise RuntimeError('Expected exactly one retained independent bond')
                    if args.bond_phase == 'resume' and args.key_store.read_bytes() != original_store:
                        raise RuntimeError('Reference bond changed during resumption')
                    result['reference_store_unchanged'] = args.bond_phase == 'resume'
                if args.private_peer and local_irk(args.local_irk, 'resume') != config.irk:
                    raise RuntimeError('Local identity changed during campaign')
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
        result.update(result='PASS', supervisor_exit=process.returncode,
                      outgoing=sink.count, incoming=received)
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        emit(**result)


if __name__ == '__main__':
    asyncio.run(main(parse_args()))
