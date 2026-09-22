# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Bounded RPA checks layered on the ordinary advertising-update verdict."""

from advertising_updates import DATA, RESPONSE, UpdateSequence

# Public fixture key, in specification order. Never use for deployed identities.
TEST_IRK = bytes(range(1, 17))


class PrivateUpdates(UpdateSequence):
    def __init__(self):
        super().__init__()
        self.addresses = [[set() for _ in range(4)] for _ in range(3)]
        self.visits = [[] for _ in range(3)]

    def observe_private(self, now, payload, address, **flags):
        super().observe(now, payload, **flags)
        stream = 2 if flags['scan_response'] else int(flags['scannable'])
        phase = self.highest[stream]
        addresses = self.addresses[stream][phase]
        addresses.add(address)
        if len(addresses) > 16:
            raise RuntimeError('Private update address bound exceeded')
        visits = self.visits[stream]
        if not visits or visits[-1][1] != address:
            if any(previous == address for _, previous in visits):
                raise RuntimeError('Old private address reappeared')
            if visits and not 0.25 <= now - visits[-1][0] <= 2.5:
                raise RuntimeError('Private update rotation interval outside bounds')
            if len(visits) == 64:
                raise RuntimeError('Private update rotation bound exceeded')
            visits.append((now, address))

    def finish(self, now):
        verdict = super().finish(now)
        counts = [[len(addresses) for addresses in row] for row in self.addresses]
        if any(count < 3 for row in counts for count in row):
            raise RuntimeError('Insufficient rotation during an update phase')
        advertised = set().union(*self.addresses[1])
        if not set().union(*self.addresses[2]) <= advertised:
            raise RuntimeError('Scan response from unobserved advertising address')
        verdict.update(private=True, addresses_per_phase=counts,
                       rotations=[len(visits) - 1 for visits in self.visits])
        return verdict


def select_private(advertisement, peer, resolver):
    """Select the fixture and reject its identifiable payload under a wrong identity."""
    payload = bytes(advertisement.data_bytes)
    resolved = resolver.resolve(advertisement.address)
    identifiable = payload and (payload in DATA[0] or payload in DATA[1] or payload in RESPONSE)
    if not identifiable and resolved != peer and advertisement.address != peer:
        return False
    if not advertisement.address.is_resolvable or resolved != peer:
        raise RuntimeError('Updated fixture report did not resolve')
    return True
