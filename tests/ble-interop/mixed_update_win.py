# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Connections winning held advertising updates before client-exit cleanup."""

import asyncio
import re
import sys

from bumble import hci
from connectable_updates import exercise as observe_and_connect
from mixed_update_exit import Sequence as ExitSequence
from mixed_update_exit import validate_board as validate_exit, validate_peer

NAME = 'mixed-update-win'
READY = 'MIXED_EXIT ADVERTISING stage=0'
SCAN_SECONDS = 80
LEGACY_SCAN = False


class Sequence(ExitSequence):
    def __init__(self):
        super().__init__()
        self.winners = []

    def ready(self):
        if self.winners != [0, 1]:
            return False
        for stream, row in enumerate(self.count):
            for phase, count in enumerate(row):
                held = phase in ((1, 3) if stream == 0 else (2,))
                # A successful connection ends advertising during this phase.
                minimum, seconds = (1, 0) if held else (10, 1.5)
                if count < minimum or self.last[stream][phase] - self.first[stream][phase] < seconds:
                    return False
        return True

    def can_connect(self, stage):
        data_phase = stage * 2 + 1
        response_phase = stage * 2
        return self.highest == [data_phase, response_phase]

    def finish(self):
        result = super().finish()
        result['winning_connections'] = len(self.winners)
        return result


def validate_board(text):
    gcs = validate_exit(text)
    for stage in range(2):
        start = text.index(f'MIXED_EXIT EXIT stage={stage} ')
        end = text.index(f'MIXED_EXIT CLEANUP stage={stage} ')
        part = text[start:end]
        connected = re.findall(r'^MIXED_EXIT CONNECTION status=0 role=1 handle=(\d+)$', part, re.M)
        disconnected = re.findall(r'^MIXED_EXIT DISCONNECTION status=0 handle=(\d+) reason=22$', part, re.M)
        if len(connected) != 1 or disconnected != connected:
            raise RuntimeError('Missing winning-link local disconnect before slot release')
        if part.index('CONNECTION status=0 role=1') > part.index('DISCONNECTION status=0'):
            raise RuntimeError('Winning link disconnected before registration')
    if len(re.findall(r'^MIXED_EXIT CONNECTION status=0 role=1 ', text, re.M)) != 3:
        raise RuntimeError('Unexpected incoming connection count')
    return gcs


def check_pending(text, stage):
    if (f'MIXED_EXIT HELD stage={stage} ' not in text or
            f'MIXED_EXIT EXIT stage={stage} ' in text):
        raise RuntimeError('Connection was not observed during the pending client lifetime')


async def before_recovery(args, device, peer, sequence, failures, board_marker, board_text, emit):
    for stage in range(2):
        async with asyncio.timeout(45):
            while not sequence.can_connect(stage):
                if failures:
                    raise failures[0]
                await asyncio.sleep(0.01)
        await board_marker(args.board_log, f'MIXED_EXIT HELD stage={stage} ')
        check_pending(board_text(args.board_log), stage)
        await device.stop_scanning(legacy=False)
        ended = asyncio.get_running_loop().create_future()
        seen = []
        connection = None
        failed = False

        def connected(link):
            if link.peer_address != peer:
                failures.append(RuntimeError('Unexpected winning peer'))
                return
            seen.append(link)

            def disconnected(reason):
                if not ended.done():
                    ended.set_result(int(reason))

            link.on(link.EVENT_DISCONNECTION, disconnected)
            try:
                check_pending(board_text(args.board_log), stage)
            except RuntimeError as error:
                failures.append(error)
            emit(event='update-winner-connected', stage=stage, handle=link.handle,
                 exit_observed=f'MIXED_EXIT EXIT stage={stage} ' in board_text(args.board_log))

        device.on('connection', connected)
        try:
            connection = await device.connect(peer, own_address_type=hci.OwnAddressType.PUBLIC, timeout=5)
            if failures:
                raise failures[0]
            if seen != [connection]:
                raise RuntimeError('Missing unique winning connection witness')
            async with asyncio.timeout(5):
                reason = await asyncio.shield(ended)
            if reason != 0x13:
                raise RuntimeError(f'Winning peer was not disconnected by cleanup: {reason}')
            await board_marker(args.board_log, f'MIXED_EXIT CLEANUP stage={stage} ')
            sequence.winners.append(stage)
            emit(event='update-winner-disconnected', stage=stage, reason=reason)
        except BaseException:
            failed = True
            raise
        finally:
            device.remove_listener('connection', connected)
            active = connection or (seen[0] if seen else None)
            if active is not None and not ended.done():
                try:
                    async with asyncio.timeout(5):
                        await active.disconnect()
                except Exception as cleanup_error:
                    if not failed:
                        raise
                    emit(event='cleanup-failed', error=type(cleanup_error).__name__)
        await device.start_scanning(legacy=False, active=True, filter_duplicates=False,
                                    own_address_type=hci.OwnAddressType.PUBLIC,
                                    scanning_phys=(hci.HCI_LE_1M_PHY,))


async def exercise(args, device, board_marker, board_text, emit):
    return await observe_and_connect(args, device, board_marker, board_text, emit,
                                     scenario=sys.modules[__name__])
