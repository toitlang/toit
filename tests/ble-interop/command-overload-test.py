# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Offline controls for independent overload evidence; no hardware."""

from types import SimpleNamespace
import unittest
from unittest.mock import patch
import radio_command_overload as runner

COMPLETE = '''COMMAND_OVERLOAD_PROVIDER ABORT error=L2CAP_QUEUE_OVERFLOW high-water=32
COMMAND_OVERLOAD_APP RECOVERED received=64 retained=4 full-gcs=65
COMMAND_OVERLOAD_APP COMPLETE
COMMAND_OVERLOAD_PROVIDER COMPLETE
'''


class Connection:
    EVENT_DISCONNECTION = 'disconnection'

    def __init__(self, overload):
        self.overload = overload
        self.writes = 0
        self.value = None
        self.is_encrypted = False

    def on(self, event, callback):
        self.ended = callback

    async def disconnect(self):
        self.ended(22)

    async def encrypt(self):
        self.is_encrypted = True

    async def write_value(self, handle, value, with_response):
        if with_response:
            raise RuntimeError('Expected command')
        self.writes += 1
        self.value = value
        if self.overload and self.writes == 40:
            self.ended(19)

    async def read_value(self, handle):
        return self.value


class OverloadTest(unittest.IsolatedAsyncioTestCase):
    async def run_case(self, text, native=False):
        connections = []
        events = []
        markers = []

        async def connect(*args, **kwargs):
            connection = Connection(not connections)
            connections.append(connection)
            return connection

        async def characteristic(client, uuid):
            return SimpleNamespace(handle=3)

        async def marker(path, value):
            markers.append(value)

        with patch.object(runner, 'Peer', lambda connection: SimpleNamespace(gatt_client=connection)), \
             patch.object(runner, 'command_characteristic', characteristic):
            await runner.exercise(SimpleNamespace(board_log=None, peer_address='01:02:03:04:05:06', native_overload=native,
                                                  authenticated_overload=False),
                                  SimpleNamespace(connect=connect), marker, lambda path: text,
                                  lambda **event: events.append(event))
        self.assertEqual([connection.writes for connection in connections], [40, 64])
        error = 'HCI_QUEUE_OVERFLOW' if native else 'L2CAP_QUEUE_OVERFLOW'
        self.assertIn(f'COMMAND_OVERLOAD_APP OVERFLOW error={error} received=1', markers)
        self.assertTrue(any(event.get('recovered') == 64 for event in events))

    async def test_complete(self):
        await self.run_case(COMPLETE)

    async def test_native_requires_native_diagnostics(self):
        with self.assertRaises(RuntimeError):
            await self.run_case(COMPLETE, native=True)
        native = COMPLETE.replace('ABORT error=L2CAP_QUEUE_OVERFLOW high-water=32',
                                  'QUEUE fault=HCI_QUEUE_OVERFLOW capacity=8 queued=8 high-water=8')
        native += 'NATIVE_OVERLOAD_PAUSE milliseconds=500 sequence=1\n'
        native += 'COMMAND_OVERLOAD_APP TERMINATED canceled=false reason=HCI_QUEUE_OVERFLOW received=1\n'
        await self.run_case(native, native=True)
        with self.assertRaises(RuntimeError):
            await self.run_case(native.replace('queued=8', 'queued=0'), native=True)

    async def test_weak_recovery_or_wrong_failure_rejected(self):
        for text in (COMPLETE.replace('full-gcs=65', 'full-gcs=0'),
                     COMPLETE.replace('L2CAP_QUEUE_OVERFLOW', 'OTHER_ERROR'),
                     COMPLETE.replace('COMMAND_OVERLOAD_PROVIDER COMPLETE', ''),
                     COMPLETE + 'EXCEPTION'):
            with self.assertRaises(RuntimeError):
                await self.run_case(text)


class AuthenticationTest(unittest.IsolatedAsyncioTestCase):
    async def test_numeric_uses_only_current_phase(self):
        prefix = 'COMMAND_OVERLOAD_PROVIDER NUMERIC value='
        text = prefix + '111111 fixture-approval=true\n'
        numeric = runner.Numeric(None, lambda path: text, lambda **event: None)
        text += prefix + '222222 fixture-approval=true\n'
        with self.assertRaisesRegex(RuntimeError, 'mismatch'):
            await numeric.compare_numbers(111111, 6)
        self.assertFalse(numeric.confirmed)
        self.assertTrue(await numeric.compare_numbers(222222, 6))
        with self.assertRaisesRegex(RuntimeError, 'repeated'):
            await numeric.compare_numbers(222222, 6)

    def test_live_flag_does_not_substitute_for_authenticated_key(self):
        connection = SimpleNamespace(sc=True, is_encrypted=True, authenticated=True)
        numeric = SimpleNamespace(confirmed=True)
        key = SimpleNamespace(authenticated=True, value=bytes(16))
        keys = [SimpleNamespace(ltk=key)]
        runner.require_authenticated(connection, numeric, keys)
        for field in ('sc', 'is_encrypted'):
            setattr(connection, field, False)
            with self.assertRaises(RuntimeError):
                runner.require_authenticated(connection, numeric, keys)
            setattr(connection, field, True)
        numeric.confirmed = False
        with self.assertRaises(RuntimeError):
            runner.require_authenticated(connection, numeric, keys)
        numeric.confirmed = True
        for invalid in ([], keys + keys, [SimpleNamespace(ltk=None)],
                        [SimpleNamespace(ltk=SimpleNamespace(authenticated=False, value=bytes(16)))],
                        [SimpleNamespace(ltk=SimpleNamespace(authenticated=True, value=bytes(15)))]):
            with self.assertRaises(RuntimeError):
                runner.require_authenticated(connection, numeric, invalid)

    async def test_resumed_bond_requires_two_encrypted_sessions_and_deletion(self):
        native = COMPLETE.replace('ABORT error=L2CAP_QUEUE_OVERFLOW high-water=32',
                                  'QUEUE fault=HCI_QUEUE_OVERFLOW capacity=8 queued=8 high-water=8')
        native += 'NATIVE_OVERLOAD_PAUSE milliseconds=500 sequence=1\n'
        native += 'COMMAND_OVERLOAD_APP TERMINATED canceled=false reason=HCI_QUEUE_OVERFLOW received=1\n'
        native += 'COMMAND_OVERLOAD_PROVIDER AUTHENTICATED encrypted=true authenticated=true\n' * 2
        native += 'COMMAND_BOND_PROVIDER READY mode=resume session=1\n'
        native += 'COMMAND_BOND_PROVIDER READY mode=resume session=2\n'
        native += 'COMMAND_BOND_PROVIDER candidate-deleted=true\n'
        connections = []
        events = []
        marker_values = []
        key = SimpleNamespace(authenticated=True, value=bytes(16))

        class KeyStore:
            saved = SimpleNamespace(ltk=key)

            async def get(self, identity): return self.saved
            async def delete(self, identity): self.saved = None
            async def get_all(self): return [self.saved] if self.saved else []

        async def connect(*args, **kwargs):
            connection = Connection(not connections)
            connections.append(connection)
            return connection

        async def characteristic(client, uuid): return SimpleNamespace(handle=3)
        async def marker(path, value): marker_values.append(value)

        device = SimpleNamespace(connect=connect, keystore=KeyStore())
        args = SimpleNamespace(board_log=None, peer_address='01:02:03:04:05:06',
                               native_overload=True, authenticated_overload=True,
                               bond_phase='resume')
        with patch.object(runner, 'Peer', lambda connection: SimpleNamespace(gatt_client=connection)), \
             patch.object(runner, 'command_characteristic', characteristic):
            await runner.exercise(args, device, marker, lambda path: native,
                                  lambda **event: events.append(event))
        self.assertTrue(all(connection.is_encrypted for connection in connections))
        self.assertIsNone(device.keystore.saved)
        self.assertTrue(any(event.get('independent_store_empty') for event in events))


if __name__ == '__main__':
    unittest.main()
