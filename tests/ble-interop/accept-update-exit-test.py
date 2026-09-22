# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

import unittest
from accept_update_exit import validate_board


class ExitTest(unittest.TestCase):
    def test_exit_order_cleanup_and_gc(self):
        lines = []
        for stage in range(2):
            lines += [f'ACCEPT_EXIT ADVERTISING stage={stage}',
                      f'ACCEPT_CANCEL HELD stage={stage} opcode={0x2008 + stage} status=0',
                      f'ACCEPT_EXIT EXIT stage={stage} pending=true full-gcs=2',
                      f'ACCEPT_EXIT STOPPED stage={stage} closes=1 enables=1 disables=0 data=2 response={stage + 1}']
        lines += ['ACCEPT_EXIT ADVERTISING stage=2',
                  'ACCEPT_EXIT RECOVERED reads=20 retained=4 full-gcs=21',
                  'ACCEPT_EXIT STOPPED stage=2 closes=1 enables=1 disables=1 data=1 response=1',
                  'ACCEPT_EXIT_PROVIDER COMPLETE opens=3 closes=3 interrupted=2 recovered=1',
                  'ACCEPT_EXIT_SUPERVISOR COMPLETE groups=4 exits=0']
        text = '\n'.join(lines)
        self.assertEqual(validate_board(text), 25)
        bad_values = [text.replace('pending=true', 'pending=false'), text.replace('response=1', 'response=2'),
                      text.replace('exits=0', 'exits=1'), text.replace('full-gcs=21', 'full-gcs=20'),
                      text.replace('full-gcs=2\n', 'full-gcs=1\n'), text + '\n' + lines[-1],
                      '\n'.join(lines[1:]), text + '\nACCEPT_EXIT_UNEXPECTED_FINALLY stage=0',
                      '\n'.join(lines[:2] + [lines[3], lines[2]] + lines[4:])]
        for bad in bad_values:
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                validate_board(bad)


if __name__ == '__main__':
    unittest.main()
