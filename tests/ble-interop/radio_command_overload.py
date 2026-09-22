# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent managed-queue overload and same-provider service recovery."""

import asyncio
import re
from bumble import hci
from bumble.device import Peer
from bumble.pairing import PairingConfig, PairingDelegate
from att_command_bursts import command_characteristic, payload


class Numeric(PairingDelegate):
    def __init__(self, board, board_text, emit):
        super().__init__(io_capability=self.IoCapability.DISPLAY_OUTPUT_AND_YES_NO_INPUT)
        self.board = board
        self.board_text = board_text
        self.emit = emit
        self.offset = len(board_text(board))
        self.confirmed = False

    async def compare_numbers(self, number, digits):
        if self.confirmed:
            raise RuntimeError('Unexpected repeated pairing approval')
        async with asyncio.timeout(10):
            while True:
                fresh = self.board_text(self.board)[self.offset:]
                match = re.search(r'COMMAND_OVERLOAD_PROVIDER NUMERIC value=(\d+) fixture-approval=true', fresh)
                if match:
                    if int(match[1]) != number:
                        raise RuntimeError('Numeric Comparison mismatch')
                    self.confirmed = True
                    self.emit(event='numeric-comparison', matched=True)
                    return True
                await asyncio.sleep(0.05)


def require_authenticated(connection, numeric, keys):
    if not numeric.confirmed or not connection.sc or not connection.is_encrypted or len(keys) != 1:
        raise RuntimeError('Missing authenticated encrypted Secure Connections pairing')
    key = keys[0].ltk
    if not key or not key.authenticated or len(key.value) != 16:
        raise RuntimeError('Missing authenticated full-length pairing key')


async def require_stored_authenticated(device, identity):
    async with asyncio.timeout(5):
        while True:
            saved = await device.keystore.get(str(identity))
            if saved and saved.ltk:
                break
            await asyncio.sleep(0.01)
    if not saved.ltk.authenticated or len(saved.ltk.value) != 16:
        raise RuntimeError('Missing authenticated retained pairing key')
    return saved


async def exercise(args, device, board_marker, board_text, emit):
    expected_error = 'HCI_QUEUE_OVERFLOW' if args.native_overload else 'L2CAP_QUEUE_OVERFLOW'
    bond_phase = getattr(args, 'bond_phase', None)
    identity = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    emit(event='ready', role='central', test='command-overload', expected_error=expected_error)
    connection = None
    disconnected = asyncio.Event()
    try:
        for overload in (True, False):
            phase = 'true' if overload else 'false'
            await board_marker(args.board_log, f'COMMAND_OVERLOAD_APP ADVERTISING overload={phase}')
            numeric = None
            fresh = args.authenticated_overload and (
                not bond_phase or (bond_phase == 'pair' and overload))
            if fresh:
                numeric = Numeric(args.board_log, board_text, emit)
                device.pairing_config_factory = lambda connection: PairingConfig(
                    sc=True, mitm=True, bonding=bool(bond_phase), delegate=numeric)
            elif args.authenticated_overload:
                def reject_pairing(connection):
                    raise RuntimeError('Fresh pairing forbidden during bond resumption')
                device.pairing_config_factory = reject_pairing
            disconnected = asyncio.Event()
            connection = await device.connect(
                identity,
                own_address_type=hci.OwnAddressType.PUBLIC, timeout=15)

            def ended(reason):
                emit(event='disconnected', phase=phase, reason=int(reason))
                disconnected.set()

            connection.on(connection.EVENT_DISCONNECTION, ended)
            if fresh:
                keys = []
                connection.on(connection.EVENT_PAIRING, keys.append)
                async with asyncio.timeout(15):
                    await connection.pair()
                require_authenticated(connection, numeric, keys)
                if bond_phase: await require_stored_authenticated(device, identity)
                emit(event='authenticated', phase=phase, encrypted=True,
                     secure_connections=True, key_bytes=16, fresh=True,
                     bonded=bool(bond_phase))
            elif args.authenticated_overload:
                async with asyncio.timeout(15):
                    await connection.encrypt()
                if not connection.is_encrypted:
                    raise RuntimeError('Resumed connection is not encrypted')
                if bond_phase: await require_stored_authenticated(device, identity)
                emit(event='authenticated', phase=phase, encrypted=True,
                     secure_connections=True, key_bytes=16, fresh=False,
                     bonded=True, resumed=True)
            client = Peer(connection).gatt_client
            service_uuid = ('9f6c6300' if overload else '9f6c6400') + '-8e2a-4b13-9e97-94f353eeb001'
            value = await command_characteristic(client, service_uuid)
            if overload:
                submitted = 0
                async with asyncio.timeout(15):
                    if args.native_overload:
                        await client.write_value(value.handle, payload(0), with_response=False)
                        submitted = 1
                        if await client.read_value(value.handle) != payload(0):
                            raise RuntimeError('Initial native-pressure command readback mismatch')
                    for sequence in range(submitted, 256):
                        if disconnected.is_set():
                            break
                        await client.write_value(value.handle, payload(sequence), with_response=False)
                        submitted += 1
                    await disconnected.wait()
                emit(event='overload-disconnect', local_submissions=submitted,
                     delivery_count_is_not_inferred=True)
                await board_marker(args.board_log,
                                   f'COMMAND_OVERLOAD_APP OVERFLOW error={expected_error} received=1')
            else:
                for burst in range(8):
                    for index in range(8):
                        await client.write_value(value.handle, payload(burst * 8 + index), with_response=False)
                    if await client.read_value(value.handle) != payload(burst * 8 + 7):
                        raise RuntimeError('Recovery readback mismatch')
                await connection.disconnect()
                await disconnected.wait()
                emit(event='recovery', commands=64, bursts=8, exact=True)
        await board_marker(args.board_log, 'entering deep sleep without wakeup time')
        text = board_text(args.board_log).replace('\r', '')
        recovered = re.findall(r'^COMMAND_OVERLOAD_APP RECOVERED received=64 retained=4 full-gcs=(\d+)$', text, re.M)
        if len(recovered) != 1 or int(recovered[0]) < 64:
            raise RuntimeError('Missing application recovery/GC verdict')
        diagnostic = ('COMMAND_OVERLOAD_PROVIDER QUEUE fault=HCI_QUEUE_OVERFLOW capacity=8 queued=8 high-water=8'
                      if args.native_overload else
                      'COMMAND_OVERLOAD_PROVIDER ABORT error=L2CAP_QUEUE_OVERFLOW high-water=32')
        required = [diagnostic,
                    'COMMAND_OVERLOAD_APP COMPLETE', 'COMMAND_OVERLOAD_PROVIDER COMPLETE']
        if args.native_overload:
            required.append('NATIVE_OVERLOAD_PAUSE milliseconds=500 sequence=1')
            required.append('COMMAND_OVERLOAD_APP TERMINATED canceled=false reason=HCI_QUEUE_OVERFLOW received=1')
        if args.authenticated_overload:
            if text.count('COMMAND_OVERLOAD_PROVIDER AUTHENTICATED encrypted=true authenticated=true') != 2:
                raise RuntimeError('Missing both provider security verdicts')
        if bond_phase:
            expected_modes = (['pair', 'resume'] if bond_phase == 'pair' else
                              ['resume', 'resume'])
            modes = re.findall(r'^COMMAND_BOND_PROVIDER READY mode=(pair|resume) session=\d+$',
                               text, re.M)
            if modes != expected_modes:
                raise RuntimeError('Unexpected provider bond phases')
            if text.count('COMMAND_BOND_PROVIDER candidate-saved=true') != int(bond_phase == 'pair'):
                raise RuntimeError('Unexpected provider candidate persistence')
            if text.count('COMMAND_OVERLOAD_PROVIDER NUMERIC value=') != int(bond_phase == 'pair'):
                raise RuntimeError('Unexpected fresh pairing during bond resumption')
            if bond_phase == 'resume':
                if 'COMMAND_BOND_PROVIDER candidate-deleted=true' not in text:
                    raise RuntimeError('Missing provider bond deletion verdict')
        if any(marker not in text for marker in required) or 'EXCEPTION' in text:
            raise RuntimeError('Missing overload/provider completion verdict')
        if bond_phase == 'resume':
            await device.keystore.delete(str(identity))
            if await device.keystore.get_all():
                raise RuntimeError('Independent bond store was not emptied')
            emit(event='bond-deleted', independent_store_empty=True)
        emit(event='command-overload', error=expected_error, recovered=64,
             retained=4, full_gcs=int(recovered[0]), mtu=23,
             bond_phase=bond_phase)
    except BaseException:
        if connection and not disconnected.is_set():
            try:
                async with asyncio.timeout(5):
                    await connection.disconnect()
            except BaseException as cleanup_error:
                emit(event='cleanup-failed', error=type(cleanup_error).__name__)
        raise
