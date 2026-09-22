# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Independent payload observation followed by GATT on the same advertising session."""

import asyncio
import re
import time

from bumble import hci
from bumble.device import Advertisement, Peer

DATA = tuple(bytes([2, 1, 6, 27, 0xff, 0xff, 0xff]) + b'cup' + bytes([phase]) +
             bytes([0x30 + phase]) * 20 if phase < 3 else b'' for phase in range(4))
RESPONSE = tuple(bytes([30, 9]) + b'cup' + bytes([ord('0') + phase]) +
                 bytes([0x41 + phase]) * 25 if phase < 3 else b'' for phase in range(4))


class Sequence:
    def __init__(self):
        self.highest = [-1, -1]
        self.count = [[0] * 4 for _ in range(2)]
        self.first = [[None] * 4 for _ in range(2)]
        self.last = [[None] * 4 for _ in range(2)]

    def observe(self, now, payload, *, connectable, scannable, scan_response):
        stream = int(scan_response)
        if not scan_response and not (connectable and scannable):
            raise RuntimeError('Expected connectable scannable advertising')
        values = RESPONSE if scan_response else DATA
        if payload not in values:
            raise RuntimeError('Unexpected connectable update payload')
        phase = values.index(payload)
        if not self.highest[stream] <= phase <= self.highest[stream] + 1:
            raise RuntimeError('Missing or regressing connectable phase')
        self.highest[stream] = phase
        if self.count[stream][phase] == 0:
            self.first[stream][phase] = now
        self.last[stream][phase] = now
        self.count[stream][phase] += 1

    def ready(self):
        return all(self.count[s][p] >= 10 and self.last[s][p] - self.first[s][p] >= 1.5
                   for s in range(2) for p in range(4))

    def finish(self):
        if not self.ready():
            raise RuntimeError('Insufficient repeated connectable updates')
        gaps = [[self.first[s][p] - self.last[s][p - 1] for p in range(1, 4)]
                for s in range(2)]
        if any(gap > 2 for row in gaps for gap in row):
            raise RuntimeError('Update interrupted advertising repetition')
        return {'reports': [row.copy() for row in self.count], 'transition_gaps_seconds': gaps, 'updates': 3}


def validate_board(text):
    markers = [f'CONNECTABLE_UPDATE APPLIED phase={phase} gc=true' for phase in range(4)]
    positions = [text.find(marker) for marker in markers]
    if any(text.count(marker) != 1 for marker in markers) or positions != sorted(positions):
        raise RuntimeError('Missing ordered application updates')
    for marker in ('CONNECTABLE_UPDATE_PROVIDER COMPLETE opens=1 closes=1 enables=1 disables=1 data=4 response=4',
                   'CONNECTABLE_UPDATE_SUPERVISOR COMPLETE groups=2 exits=0'):
        if text.splitlines().count(marker) != 1:
            raise RuntimeError('Incorrect provider lifetime or child exits')
    complete = re.findall(r'^CONNECTABLE_UPDATE_APP COMPLETE writes=100 retained=4 full-gcs=(\d+)$', text, re.M)
    if len(complete) != 1 or int(complete[0]) < 104:
        raise RuntimeError('Missing GATT/GC completion')
    if any(error in text for error in ('EXCEPTION', 'Controller disable failed', 'Controller deinit failed')):
        raise RuntimeError('Board cleanup failed')
    return int(complete[0])


async def exercise(args, device, board_marker, board_text, emit, *, scenario=None):
    sequence = scenario.Sequence() if scenario else Sequence()
    test_name = scenario.NAME if scenario else 'connectable-updates'
    writes = getattr(scenario, 'WRITES', 0) if scenario else 100
    recovery_reads = getattr(scenario, 'READS', 20) if scenario else 0
    peer = hci.Address(args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS)
    failures = []
    armed = False
    scanning = False
    connection = None
    failed = False
    legacy_scan = getattr(scenario, 'LEGACY_SCAN', True)

    def observed(report):
        advertisement = Advertisement.from_advertising_report(report)
        if not armed or not advertisement or advertisement.address != peer:
            return
        try:
            sequence.observe(time.monotonic(), bytes(advertisement.data_bytes),
                             connectable=advertisement.is_connectable,
                             scannable=advertisement.is_scannable,
                             scan_response=advertisement.is_scan_response)
        except RuntimeError as error:
            if not failures:
                failures.append(error)

    device.host.on('advertising_report', observed)
    try:
        if not legacy_scan and not device.supports_le_extended_advertising:
            raise RuntimeError('This scenario requires extended scan commands')
        await device.start_scanning(legacy=legacy_scan, active=True, filter_duplicates=False,
                                    own_address_type=hci.OwnAddressType.PUBLIC,
                                    scanning_phys=(hci.HCI_LE_1M_PHY,))
        scanning = True
        emit(event='ready', test=test_name, scan='active')
        await board_marker(args.board_log, scenario.READY if scenario else 'CONNECTABLE_UPDATE ADVERTISING')
        armed = True
        if scenario and hasattr(scenario, 'before_recovery'):
            await scenario.before_recovery(args, device, peer, sequence, failures,
                                           board_marker, board_text, emit)
        async with asyncio.timeout(getattr(scenario, 'SCAN_SECONDS', 40) if scenario else 30):
            while not sequence.ready():
                if failures:
                    raise failures[0]
                await asyncio.sleep(0.05)
        await device.stop_scanning(legacy=legacy_scan)
        scanning = False
        armed = False
        if failures:
            raise failures[0]
        verdict = sequence.finish()
        emit(event='connectable-observed', **verdict)
        connection = await device.connect(peer, own_address_type=hci.OwnAddressType.PUBLIC, timeout=15)
        emit(event='connected', peer=str(connection.peer_address), handle=connection.handle)
        client = Peer(connection).gatt_client
        services = await client.discover_services()
        service = [s for s in services if s.uuid.to_bytes() == b'\xf0\xff']
        if len(service) != 1:
            raise RuntimeError('Missing fixture service')
        values = await client.discover_characteristics([], service=service[0])
        if len(values) != 1 or values[0].uuid.to_bytes() != b'\xf1\xff' or int(values[0].properties) != (0x0a if writes else 0x02):
            raise RuntimeError('Unexpected fixture characteristic')
        value = values[0]
        if recovery_reads:
            for index in range(recovery_reads):
                if await client.read_value(value.handle) != bytes([index, 42]):
                    raise RuntimeError('Post-cancellation GATT recovery mismatch')
        else:
            if await client.read_value(value.handle) != b'\0':
                raise RuntimeError('Wrong initial value')
            for index in range(writes):
                payload = bytes([index, 42, 43])
                await client.write_value(value.handle, payload, with_response=True)
                if await client.read_value(value.handle) != payload:
                    raise RuntimeError('Post-update GATT readback mismatch')
        await connection.disconnect()
        connection = None
        await board_marker(args.board_log, 'entering deep sleep without wakeup time')
        validator = scenario.validate_board if scenario else validate_board
        gcs = validator(board_text(args.board_log).replace('\r', ''))
        if scenario and hasattr(scenario, 'validate_peer'):
            await board_marker(args.survivor_log, 'entering deep sleep without wakeup time')
            scenario.validate_peer(board_text(args.survivor_log).replace('\r', ''))
        emit(event=test_name, writes=writes, recovery_reads=recovery_reads,
             full_gcs=gcs, **verdict)
    except BaseException as error:
        failed = True
        emit(event='exchange-failed', error=type(error).__name__)
        if connection:
            try:
                async with asyncio.timeout(5):
                    await connection.disconnect()
            except Exception as cleanup_error:
                emit(event='cleanup-failed', error=type(cleanup_error).__name__)
        try:
            await board_marker(args.board_log, 'entering deep sleep without wakeup time', seconds=80)
        except Exception as board_error:
            emit(event='board-terminal-missing', error=type(board_error).__name__)
        raise
    finally:
        device.host.remove_listener('advertising_report', observed)
        if scanning:
            try:
                await device.stop_scanning(legacy=legacy_scan)
            except Exception as cleanup_error:
                if not failed:
                    raise
                emit(event='cleanup-failed', error=type(cleanup_error).__name__)
