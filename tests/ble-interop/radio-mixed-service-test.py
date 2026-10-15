# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional mixed-service result checks; no radio or privileged operations."""

import asyncio
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from bumble.keys import PairingKeys

spec = importlib.util.spec_from_file_location('mixed_radio', Path(__file__).with_name('radio-mixed-service.py'))
mixed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mixed)


def complete_log():
    lines = ['[toit] INFO: starting <test>',
             'MIXED_INDEPENDENT CONFIG receive-acl-packets=4 central-peer=84f703a00b3a']
    for order in ('false', 'true'):
        lines += ['MIXED_CENTRAL CYCLE cycle=0 reads=300',
                  'MIXED_PERIPHERAL COMPLETE cycle=0 local-reads=100',
                  'MIXED_CENTRAL CYCLE cycle=1 reads=500',
                  'MIXED_PERIPHERAL COMPLETE cycle=1 local-reads=100',
                  'MIXED_CENTRAL COMPLETE reads=500',
                  f'MIXED_PROVIDER ROUND_COMPLETE peripheral-first={order} opens=1 closes=1 peer-reads=200 full-gcs=12']
    return '\n'.join(lines + ['MIXED_PROVIDER COMPLETE rounds=2',
                              '[toit] INFO: entering deep sleep without wakeup time', ''])


def secure_logs():
    owner = complete_log().replace('peer-reads=200', 'peer-reads=202')
    security = []
    peer = ['[toit] INFO: starting <peer>']
    for cycle, order in enumerate(('false', 'true')):
        security += [f'MIXED_SECURE_PROVIDER NUMERIC role=0 value={123 + cycle} fixture-approval=true',
                     'MIXED_SECURE_PROVIDER SECURED role=0 encrypted=true authenticated=true']
        for incoming in range(2):
            security += [f'MIXED_SECURE_PROVIDER NUMERIC role=1 value={800 + cycle * 2 + incoming} fixture-approval=true',
                         'MIXED_SECURE_PROVIDER SECURED role=1 encrypted=true authenticated=true']
        security += [f'MIXED_SECURE_PROVIDER ROUND_SECURITY peripheral-first={order} pairings=3']
        peer += [f'MIXED_SECURE_PEER NUMERIC cycle={cycle} value={123 + cycle} fixture-approval=true',
                 f'MIXED_SECURE_PEER SECURED cycle={cycle} encrypted=true authenticated=true',
                 f'MIXED_SECURE_PEER CYCLE_COMPLETE cycle={cycle}']
    owner = owner.replace('MIXED_PROVIDER COMPLETE rounds=2',
                          '\n'.join(security + ['MIXED_PROVIDER COMPLETE rounds=2']))
    peer += ['MIXED_SECURE_PEER COMPLETE cycles=2',
             'MIXED_INDEPENDENT_AUTH_PEER COMPLETE protected-reads=1000 connections=2 closes=1',
             '[toit] INFO: entering deep sleep without wakeup time']
    return owner, '\n'.join(peer)


class VerdictTest(unittest.TestCase):
    def test_outgoing_private_requires_matching_discovery_and_connection(self):
        identity = '8a884ba356a9'
        addresses = ['420001123456', '420002123456']
        resolved = ''.join(f'MIXED_RESUME S3 PRIVATE peer={address} identity={identity} resolved=true\n'
                           for address in addresses)
        scanned = ''.join(f'MIXED_PRIVATE_DISCOVERED peer={address} identity={identity} stopped=true\n'
                          for address in addresses)
        mixed.validate_private_peer(resolved + scanned, addresses, identity, count=2, discovered=True)
        for invalid in ('', scanned.replace(addresses[0], addresses[1]),
                        scanned.replace('stopped=true', 'stopped=false'),
                        scanned.replace(identity, '84f703a00b3a'), scanned + scanned):
            with self.assertRaises(RuntimeError):
                mixed.validate_private_peer(resolved + invalid, addresses, identity, count=2, discovered=True)

    def test_private_peer_requires_four_distinct_matching_resolved_addresses(self):
        addresses = [f'42000{index}123456' for index in range(4)]
        identity = '8a884ba356a9'
        text = ''.join(f'MIXED_RESUME S3 PRIVATE peer={address} identity={identity} resolved=true\n'
                       for address in addresses)
        mixed.validate_private_peer(text, addresses, identity)
        for invalid in (text.replace(addresses[0], addresses[1]),
                        text.replace(identity, '84f703a00b3a'),
                        text.replace('resolved=true', 'resolved=false'), text + text):
            with self.assertRaises(RuntimeError):
                mixed.validate_private_peer(invalid, addresses, identity)
        with self.assertRaises(RuntimeError):
            mixed.validate_private_peer(text, [addresses[0]] * 4, identity)
        with self.assertRaises(RuntimeError):
            mixed.validate_private_peer(text.replace('4200', 'c200'),
                                        [address.replace('4200', 'c200') for address in addresses], identity)

    def test_local_irk_private_exclusive_and_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'local.irk'
            value = mixed.local_irk(path, 'pair')
            self.assertEqual(len(value), 16)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(mixed.local_irk(path, 'resume'), value)
            with self.assertRaises(FileExistsError):
                mixed.local_irk(path, 'pair')
            path.chmod(0o644)
            with self.assertRaises(RuntimeError):
                mixed.local_irk(path, 'resume')
            path.chmod(0o600)
            path.write_bytes(value[:15])
            with self.assertRaises(RuntimeError):
                mixed.local_irk(path, 'resume')

    def test_bond_phases_require_matching_counts_and_unchanged_records(self):
        for resume in (False, True):
            flag = str(resume).lower()
            owner = complete_log().replace('peer-reads=200', 'peer-reads=202')
            owner += f'\nMIXED_INDEPENDENT_BOND OWNER resume-only={flag}\n'
            peer = f'[toit] INFO: starting <peer>\nMIXED_INDEPENDENT_BOND PEER resume-only={flag}\n'
            if not resume:
                owner += ('MIXED_RESUME S3 NUMERIC role=0 value=123 fixture-approval=true\n'
                          'MIXED_RESUME S3 NUMERIC role=1 value=456 fixture-approval=true\n'
                          'MIXED_RESUME S3 SAVED slot=0 authenticated=true\n'
                          'MIXED_RESUME S3 SAVED slot=1 authenticated=true\n')
                peer += ('MIXED_RESUME PEER NUMERIC role=1 value=123 fixture-approval=true\n'
                         'MIXED_RESUME PEER SAVED slot=0 authenticated=true\n')
            owner += 'MIXED_RESUME S3 RESUMED role=0 authenticated=true\n' * (2 if resume else 1)
            owner += 'MIXED_RESUME S3 RESUMED role=1 authenticated=true\n' * (4 if resume else 3)
            peer += 'MIXED_RESUME PEER RESUMED role=1 authenticated=true\n' * (2 if resume else 1)
            owner += f'MIXED_RESUME S3 COMPLETE fresh={0 if resume else 2} resumed={6 if resume else 4} stored=2 unchanged={flag}\n'
            peer += (f'MIXED_RESUME PEER COMPLETE fresh={0 if resume else 1} resumed={2 if resume else 1} stored=1 unchanged={flag}\n'
                     'MIXED_SECURE_PEER COMPLETE cycles=2\n'
                     'MIXED_INDEPENDENT_BOND_PEER COMPLETE protected-reads=1000 connections=2 closes=1\n'
                     '[toit] INFO: entering deep sleep without wakeup time\n')
            phase = 'resume' if resume else 'pair'
            mixed.validate_bond(owner, peer, phase)
            for bad in (owner.replace('stored=2', 'stored=1'),
                        owner.replace('unchanged=' + flag, 'unchanged=' + str(not resume).lower()),
                        owner.replace('RESUMED role=1 authenticated=true', 'RESUMED role=1 authenticated=false', 1),
                        owner + 'MIXED_RESUME S3 NUMERIC role=1 value=999 fixture-approval=true\n',
                        owner + 'MIXED_RESUME S3 SAVED slot=1 authenticated=true\n'):
                with self.assertRaises(RuntimeError):
                    mixed.validate_bond(bad, peer, phase)
            if not resume:
                with self.assertRaises(RuntimeError):
                    mixed.validate_bond(owner, peer.replace('value=123', 'value=124'), phase)
            else:
                incoming = ('[toit] INFO: starting <peer>\n'
                            'MIXED_INDEPENDENT_BOND INCOMING resume-only=true\n'
                            'MIXED_RESUME PEER COMPLETE fresh=0 resumed=4 stored=1 unchanged=true\n'
                            'MIXED_INDEPENDENT_BOND_INCOMING COMPLETE protected-reads=400 denied=4 connections=4\n'
                            '[toit] INFO: entering deep sleep without wakeup time\n')
                for cycle in range(4):
                    incoming += ('MIXED_RESUME PEER RESUMED role=0 authenticated=true\n'
                                 f'MIXED_RESUME LINUX CYCLE cycle={cycle} protected-reads=100 denied=1\n')
                mixed.validate_bond(owner, incoming, 'resume', reverse=True)
                for bad in (incoming.replace('denied=1', 'denied=0', 1),
                            incoming.replace('cycle=3', 'cycle=2'),
                            incoming.replace('resumed=4', 'resumed=2'),
                            incoming + 'MIXED_RESUME PEER NUMERIC role=0 value=777 fixture-approval=true\n'):
                    with self.assertRaises(RuntimeError):
                        mixed.validate_bond(owner, bad, 'resume', reverse=True)

    def test_resumed_read_requires_stored_authentication_and_no_new_pairing(self):
        connection = SimpleNamespace(is_encrypted=True, authenticated=True, sc=True)
        stored = PairingKeys(ltk=PairingKeys.Key(bytes(16), authenticated=True))
        mixed.require_resumed(connection, stored, [])
        for encrypted, authenticated, size, keys in (
            (False, True, 16, []), (True, False, 16, []),
            (True, True, 15, []), (True, True, 16, [object()]),
        ):
            connection.is_encrypted = encrypted
            stored.ltk.authenticated = authenticated
            stored.ltk.value = bytes(size)
            with self.assertRaises(RuntimeError):
                mixed.require_resumed(connection, stored, keys)
        connection.is_encrypted = True
        with self.assertRaises(RuntimeError):
            mixed.require_resumed(connection, None, [])

    def test_complete_both_orders(self):
        self.assertEqual(mixed.validate_owner(complete_log()), [12, 12])

    def test_reverse_role_requires_the_configured_outgoing_peer(self):
        reverse = complete_log().replace('central-peer=84f703a00b3a', 'central-peer=8a884ba356a9')
        self.assertEqual(mixed.validate_owner(reverse, '8a884ba356a9'), [12, 12])
        with self.assertRaises(RuntimeError):
            mixed.validate_owner(reverse)

    def test_authentication_requires_both_roles_and_matching_other_peer(self):
        owner, peer = secure_logs()
        self.assertEqual(mixed.validate_owner(owner, peer_reads=202), [12, 12])
        mixed.validate_security(owner, peer)
        for before, after in (('value=123', 'value=999'), ('authenticated=true', 'authenticated=false'),
                              ('pairings=3', 'pairings=2'), ('closes=1', 'closes=0'),
                              ('protected-reads=1000', 'protected-reads=999'),
                              ('CYCLE_COMPLETE cycle=1', 'CYCLE_COMPLETE cycle=0'),
                              ('ROUND_SECURITY peripheral-first=true', 'ROUND_SECURITY peripheral-first=false')):
            with self.subTest(change=(before, after)):
                bad_owner, bad_peer = owner, peer
                if before in peer:
                    bad_peer = peer.replace(before, after, 1)
                else:
                    bad_owner = owner.replace(before, after, 1)
                with self.assertRaises(RuntimeError):
                    mixed.validate_security(bad_owner, bad_peer)

    def test_reverse_authentication_requires_all_incoming_pairings_and_denials(self):
        owner, _ = secure_logs()
        lines = ['[toit] INFO: starting <peer>',
                 'MIXED_INDEPENDENT_AUTH_INCOMING READY peer=f412fac150fe']
        for cycle in range(4):
            lines += [f'MIXED_SECURE_LINUX NUMERIC cycle={cycle} value={800 + cycle} fixture-approval=true',
                      f'MIXED_SECURE_LINUX CYCLE cycle={cycle} protected-reads=100 denied=1 reason=19']
        lines += ['MIXED_SECURE_LINUX COMPLETE protected-reads=400 denied=4',
                  'MIXED_INDEPENDENT_AUTH_INCOMING COMPLETE protected-reads=400 denied=4 connections=4',
                  '[toit] INFO: entering deep sleep without wakeup time']
        peer = '\n'.join(lines)
        mixed.validate_secure_incoming(owner, peer)
        for before, after in (('value=802', 'value=800'), ('denied=1', 'denied=0'),
                              ('reason=19', 'reason=8'), ('protected-reads=100', 'protected-reads=99'),
                              ('cycle=3', 'cycle=2'), ('connections=4', 'connections=3'),
                              (lines[-1], '')):
            with self.subTest(change=(before, after)):
                with self.assertRaises(RuntimeError):
                    mixed.validate_secure_incoming(owner, peer.replace(before, after, 1))

    def test_incoming_peer_requires_all_cycles_and_normal_disconnects(self):
        lines = ['[toit] INFO: starting <test>',
                 'MIXED_INDEPENDENT_INCOMING READY peer=f412fac150fe']
        lines += [f'MIXED_LINUX CYCLE cycle={cycle} reads=100 reason=19' for cycle in range(4)]
        lines += ['MIXED_LINUX COMPLETE reads=400',
                  'MIXED_INDEPENDENT_INCOMING COMPLETE reads=400 connections=4',
                  '[toit] INFO: entering deep sleep without wakeup time']
        valid = '\n'.join(lines)
        mixed.validate_incoming(valid)
        for before, after in (('cycle=2', 'cycle=1'), ('reads=100', 'reads=99'),
                              ('reason=19', 'reason=8'), ('connections=4', 'connections=3'),
                              (lines[-1], ''), (lines[-2], lines[-2] + '\n' + lines[-2])):
            with self.subTest(change=(before, after)):
                with self.assertRaises(RuntimeError):
                    mixed.validate_incoming(valid.replace(before, after, 1))

    def test_missing_or_duplicate_completion(self):
        for marker in ('MIXED_CENTRAL COMPLETE reads=500',
                       'MIXED_PERIPHERAL COMPLETE cycle=1 local-reads=100',
                       'MIXED_PROVIDER COMPLETE rounds=2',
                       '[toit] INFO: entering deep sleep without wakeup time'):
            for replacement in ('', marker + '\n' + marker):
                with self.subTest(marker=marker, replacement=replacement):
                    with self.assertRaises(RuntimeError):
                        mixed.validate_owner(complete_log().replace(marker, replacement, 1))

    def test_incorrect_lifetime_traffic_gc_and_order(self):
        for before, after in (('closes=1', 'closes=0'), ('peer-reads=200', 'peer-reads=199'),
                              ('full-gcs=12', 'full-gcs=0'), ('peripheral-first=true', 'peripheral-first=false'),
                              ('receive-acl-packets=4', 'receive-acl-packets=0')):
            with self.subTest(change=(before, after)):
                with self.assertRaises(RuntimeError):
                    mixed.validate_owner(complete_log().replace(before, after, 1))

    def test_board_failure_and_reboot_are_not_hidden_by_good_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'board.log'
            for extra in ('EXCEPTION error.\n', '[toit] INFO: starting <second>\n',
                          'Controller disable failed\n', 'ASSERTION_FAILED\n'):
                path.write_text(complete_log() + extra)
                with self.subTest(extra=extra):
                    with self.assertRaises(RuntimeError):
                        mixed.board_text(path)
            path.write_bytes(b'\xff startup noise\n' + complete_log().replace('\n', '\r\n').encode())
            self.assertEqual(mixed.validate_owner(mixed.board_text(path)), [12, 12])


class NumericTest(unittest.IsolatedAsyncioTestCase):
    async def test_bond_comparison_uses_the_storage_fixture_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'board.log'
            path.write_text('[toit] INFO: starting <test>\n'
                            'MIXED_SECURE_PROVIDER NUMERIC role=1 value=111 fixture-approval=true\n'
                            'MIXED_RESUME S3 NUMERIC role=1 value=222 fixture-approval=true\n')
            numeric = mixed.Numeric(path, 0, prefix='MIXED_RESUME S3')
            self.assertTrue(await numeric.compare_numbers(222, 6))

    async def test_reference_store_is_private_exclusive_and_retained(self):
        # The command sets this before Bumble performs atomic file replacement.
        previous = os.umask(0o077)
        self.addCleanup(os.umask, previous)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'keys.json'
            store, _ = await mixed.open_bond_store(path, 'pair')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(RuntimeError):
                await mixed.open_bond_store(path, 'resume')
            # Public offline test material; never used for a hardware campaign.
            key = PairingKeys(ltk=PairingKeys.Key(bytes(range(16)), authenticated=True))
            await store.update('01:02:03:04:05:06/P', key)
            retained = path.read_bytes()
            reopened, original = await mixed.open_bond_store(path, 'resume')
            self.assertEqual(original, retained)
            self.assertEqual((await reopened.get('01:02:03:04:05:06/P')).ltk, key.ltk)
            with self.assertRaises(FileExistsError):
                await mixed.open_bond_store(path, 'pair')
            self.assertEqual(path.read_bytes(), retained)
            path.chmod(0o644)
            with self.assertRaises(RuntimeError):
                await mixed.open_bond_store(path, 'resume')

    async def test_outgoing_approval_uses_only_the_central_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'board.log'
            path.write_text('[toit] INFO: starting <test>\n'
                            'MIXED_SECURE_PROVIDER NUMERIC role=1 value=123 fixture-approval=true\n'
                            'MIXED_SECURE_PROVIDER NUMERIC role=0 value=456 fixture-approval=true\n')
            with self.assertRaisesRegex(RuntimeError, 'mismatch'):
                await mixed.Numeric(path, 0, role=0).compare_numbers(123, 6)
            self.assertTrue(await mixed.Numeric(path, 0, role=0).compare_numbers(456, 6))

    async def test_matches_only_current_cycle_and_rejects_repeated_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'board.log'
            path.write_text('[toit] INFO: starting <test>\n'
                            'MIXED_SECURE_PROVIDER NUMERIC role=1 value=123 fixture-approval=true\n')
            numeric = mixed.Numeric(path, 1)
            # Even a matching earlier number cannot approve a new connection.
            with self.assertRaises(TimeoutError):
                await asyncio.wait_for(numeric.compare_numbers(123, 6), 0.02)
            self.assertFalse(numeric.confirmed)
            with path.open('a') as output:
                output.write('MIXED_SECURE_PROVIDER NUMERIC role=1 value=456 fixture-approval=true\n')
            self.assertTrue(await numeric.compare_numbers(456, 6))
            with self.assertRaisesRegex(RuntimeError, 'repeated'):
                await numeric.compare_numbers(456, 6)

    async def test_mismatch_and_extra_pairing_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'board.log'
            text = ('[toit] INFO: starting <test>\n'
                    'MIXED_SECURE_PROVIDER NUMERIC role=1 value=123 fixture-approval=true\n')
            path.write_text(text)
            with self.assertRaisesRegex(RuntimeError, 'mismatch'):
                await mixed.Numeric(path, 0).compare_numbers(456, 6)
            path.write_text(text + text.splitlines()[-1] + '\n')
            with self.assertRaisesRegex(RuntimeError, 'extra pairing'):
                await mixed.Numeric(path, 0).compare_numbers(123, 6)


if __name__ == '__main__':
    unittest.main()
