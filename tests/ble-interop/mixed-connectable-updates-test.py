# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import unittest
from mixed_connectable_updates import validate_board, validate_peer


def fixture():
    def batch(index):
        return f'MIXED_UPDATE_CENTRAL BATCH index={index} reads=100 retained=4 full-gcs=10'
    lines = [batch(0)]
    for phase in range(4):
        lines += [f'CONNECTABLE_UPDATE APPLIED phase={phase} gc=true', batch(phase + 1)]
    lines += ['MIXED_UPDATE CLEANUP peripheral-released=true survivor-open=true',
              'CONNECTABLE_UPDATE_APP COMPLETE writes=100 retained=4 full-gcs=104', batch(5),
              'MIXED_UPDATE_CENTRAL COMPLETE reads=600 batches=6 full-gcs=60',
              'MIXED_UPDATE_PROVIDER COMPLETE opens=1 closes=1 data=4 response=4 parameters=1 removes=1 disables=0 enables=15 terminations=15 phase-reads=100,100,100,100,100,100 full-gcs=30',
              'MIXED_UPDATE_SUPERVISOR COMPLETE child-groups=2 exits=0']
    return '\n'.join(lines)


class MixedTest(unittest.TestCase):
    def test_complete(self):
        self.assertEqual(validate_board(fixture()), 104)
        validate_peer('MIXED_UPDATE_PEER COMPLETE reads=600 retained=4 full-gcs=60')

    def test_counts_gc_and_closure(self):
        text = fixture()
        for before, after in [('phase-reads=100', 'phase-reads=99'), ('full-gcs=10\n', 'full-gcs=9\n'),
                              ('full-gcs=104', 'full-gcs=103'), ('full-gcs=30', 'full-gcs=19'),
                              ('terminations=15', 'terminations=14'), ('disables=0', 'disables=1'),
                              ('response=4', 'response=5'), ('exits=0', 'exits=1'),
                              ('survivor-open=true', 'survivor-open=false')]:
            with self.subTest(before=before), self.assertRaises(RuntimeError):
                validate_board(text.replace(before, after))

    def test_order_missing_and_duplicate(self):
        lines = fixture().splitlines()
        swapped = lines.copy()
        swapped[1], swapped[2] = swapped[2], swapped[1]
        for bad in ('\n'.join(swapped), '\n'.join(lines[1:]), fixture() + '\n' + lines[-1]):
            with self.assertRaises(RuntimeError):
                validate_board(bad)

    def test_peer_cannot_be_missing_or_partial(self):
        text = 'MIXED_UPDATE_PEER COMPLETE reads=600 retained=4 full-gcs=60'
        for bad in ('', text.replace('600', '599'), text.replace('60\n', '59\n') + '\nEXCEPTION',
                    text.replace('full-gcs=60', 'full-gcs=59'), text + '\n' + text):
            with self.assertRaises(RuntimeError):
                validate_peer(bad)


if __name__ == '__main__':
    unittest.main()
