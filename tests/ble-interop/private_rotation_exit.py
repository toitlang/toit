# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Bounded independent verdict for private-rotation client death on a board."""

DATA = tuple(bytes([2, 1, 6, 5, 0x16, 0xf0, 0xff, 0x72, stage]) for stage in range(4))


class PrivateRotationExit:
    def __init__(self):
        self.stage = -1
        self.visits = [[] for _ in range(4)]
        self.addresses = set()

    def observe_private(self, now, payload, address, **flags):
        if flags != dict(connectable=False, scannable=False, scan_response=False):
            raise RuntimeError('Unexpected private-rotation advertising mode')
        if payload not in DATA:
            raise RuntimeError('Private-rotation payload changed')
        stage = DATA.index(payload)
        if stage < self.stage or stage > self.stage + 1:
            raise RuntimeError('Private-rotation stage missing or reappeared')
        self.stage = stage
        visits = self.visits[stage]
        if not visits or visits[-1]['address'] != address:
            if address in self.addresses:
                raise RuntimeError('Old private address reappeared')
            if len(visits) >= (2 if stage == 2 else 1):
                raise RuntimeError('Unexpected additional private rotation')
            self.addresses.add(address)
            visits.append(dict(address=address, first=now, last=now, count=0))
        if sum(visit['count'] for visit in visits) >= 512:
            raise RuntimeError('Private-rotation report bound exceeded')
        visit = visits[-1]
        if now < visit['last']:
            raise RuntimeError('Private-rotation observation clock reversed')
        visit['last'] = now
        visit['count'] += 1

    def finish(self, now):
        if [len(visits) for visits in self.visits] != [1, 1, 2, 1]:
            raise RuntimeError('Missing private-rotation stage or enabled RPA')
        for stage, visits in enumerate(self.visits):
            first = visits[0]
            minimum_span = 1 if stage == 3 else 2
            if first['count'] < 4 or first['last'] - first['first'] < minimum_span:
                raise RuntimeError('Insufficient private-rotation baseline repetition')
        rotation_gap = self.visits[2][1]['first'] - self.visits[2][0]['first']
        if not 2 <= rotation_gap <= 6:
            raise RuntimeError('Unexpected enabled-rotation observation interval')
        gaps = [later[0]['first'] - earlier[-1]['last']
                for earlier, later in zip(self.visits, self.visits[1:])]
        if any(gap < 0.7 for gap in gaps):
            raise RuntimeError('Missing inter-client stop gap')
        quiet = now - self.visits[-1][-1]['last']
        if quiet < 2:
            raise RuntimeError('Private advertising did not cease')
        return dict(private_rotation_exit=True, visits=self.visits,
                    stop_gaps_seconds=gaps, rotation_gap_seconds=rotation_gap,
                    final_quiet_seconds=quiet)


def select_rotation(advertisement, peer, resolver):
    payload = bytes(advertisement.data_bytes)
    resolved = resolver.resolve(advertisement.address)
    if payload not in DATA and resolved != peer and advertisement.address != peer:
        return False
    if not advertisement.address.is_resolvable or resolved != peer:
        raise RuntimeError('Private-rotation fixture did not resolve')
    return True


def validate_rotation_board(text):
    markers = []
    for stage in range(4):
        markers.append(f'PRIVATE_ROTATION_EXIT ACTIVE stage={stage}')
        if stage < 3:
            markers.extend([f'PRIVATE_ROTATION_EXIT HELD stage={stage} status=0',
                            f'PRIVATE_ROTATION_EXIT EXIT stage={stage} pending=true'])
        else:
            markers.append('PRIVATE_ROTATION_EXIT RECOVERED stage=3 stopped=true')
        markers.append(f'PRIVATE_ROTATION_EXIT STOPPED stage={stage} released=true')
        enables = 2 if stage == 2 else 1
        addresses = 2 if stage in (1, 2) else 1
        counts = (f'PRIVATE_ROTATION_EXIT COUNTS stage={stage} enables={enables} '
                  f'disables=1 addresses={addresses} closes=1')
        if text.splitlines().count(counts) != 2:
            raise RuntimeError('Missing exact private-rotation controller counts')
    markers.append('PRIVATE_ROTATION_EXIT COMPLETE interrupted=3 recovered=1 opens=4 closes=4')
    positions = [text.find(marker) for marker in markers]
    if (any(text.splitlines().count(marker) != 1 for marker in markers) or
            positions != sorted(positions) or 'UNEXPECTED_FINALLY' in text or 'EXCEPTION' in text):
        raise RuntimeError('Incomplete private-rotation client-death lifecycle')
