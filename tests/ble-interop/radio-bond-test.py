# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Optional Bumble fixture-oracle checks; no radio or capability grant."""

import asyncio
from contextlib import redirect_stdout
import io
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

from bumble import att, hci, smp

runner = runpy.run_path(str(Path(__file__).with_name("radio-bond.py")))


class PeripheralOracleTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.ready = asyncio.Event()
        self.handlers = {}
        self.services = []
        async def advertise(**kwargs):
            self.ready.set()
        self.device = SimpleNamespace(
            EVENT_CONNECTION="connection", on=self.handlers.__setitem__,
            add_service=self.services.append, start_advertising=advertise)
        self.args = SimpleNamespace(peer_address="12:34:56:78:9A:BC", phase="pair", private=False,
                                    adapter_address="12:34:56:78:9A:BD")
        self.key = SimpleNamespace(ltk=SimpleNamespace(authenticated=True, value=bytes(16)))
        self.store = SimpleNamespace(get=AsyncMock(return_value=self.key))
        self.numeric = SimpleNamespace(confirmed=True)
        self.connection_handlers = {}
        self.connection = SimpleNamespace(
            peer_address=hci.Address(self.args.peer_address, hci.Address.PUBLIC_DEVICE_ADDRESS),
            is_encrypted=True, authenticated=True, EVENT_DISCONNECTION="disconnection",
            on=self.connection_handlers.__setitem__)
        self.output = redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.task = asyncio.create_task(runner["run_peripheral"](
            self.args, self.device, self.store, self.numeric))
        await asyncio.wait_for(self.ready.wait(), 1)
        self.read = self.services[0].characteristics[0].value.read

    async def asyncTearDown(self):
        self.task.cancel()
        await asyncio.gather(self.task, return_exceptions=True)
        self.output.__exit__(None, None, None)

    async def test_live_authentication_cannot_replace_stored_evidence(self):
        for encrypted, authenticated, key_length, expected in (
            (False, True, 16, att.ATT_INSUFFICIENT_ENCRYPTION_ERROR),
            (True, False, 16, att.ATT_INSUFFICIENT_AUTHENTICATION_ERROR),
            (True, True, 15, att.ATT_INSUFFICIENT_AUTHENTICATION_ERROR),
        ):
            with self.subTest(encrypted=encrypted, authenticated=authenticated, key_length=key_length):
                self.connection.is_encrypted = encrypted
                self.key.ltk.authenticated = authenticated
                self.key.ltk.value = bytes(key_length)
                with self.assertRaises(att.ATT_Error) as raised:
                    await self.read(self.connection)
                self.assertEqual(raised.exception.error_code, expected)
        self.assertTrue(self.connection.authenticated)

    async def test_initial_pairing_requires_numeric_approval(self):
        self.numeric.confirmed = False
        with self.assertRaisesRegex(RuntimeError, "Numeric Comparison"):
            await self.read(self.connection)

    async def test_success_requires_counts_and_public_identity_lookup(self):
        self.handlers["connection"](self.connection)
        for _ in range(11):
            self.assertEqual(await self.read(self.connection), b"\x2b")
        self.connection_handlers["disconnection"](19)
        await self.task
        self.store.get.assert_awaited_with("12:34:56:78:9A:BC/P")

    async def test_short_read_run_fails(self):
        self.handlers["connection"](self.connection)
        await self.read(self.connection)
        self.connection_handlers["disconnection"](19)
        with self.assertRaisesRegex(RuntimeError, "counts"):
            await self.task

    async def test_unexpected_peer_fails(self):
        self.connection.peer_address = hci.Address("01:02:03:04:05:06", hci.Address.PUBLIC_DEVICE_ADDRESS)
        self.handlers["connection"](self.connection)
        with self.assertRaisesRegex(RuntimeError, "Unexpected central"):
            await self.task


class PrivateOracleTest(unittest.TestCase):
    def test_local_irk_survives_restart_without_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "irk.bin"
            key = runner["load_local_irk"](path, "pair")
            self.assertEqual(len(key), 16)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(runner["load_local_irk"](path, "resume"), key)
            with self.assertRaises(FileExistsError):
                runner["load_local_irk"](path, "pair")
            self.assertEqual(path.read_bytes(), key)
            path.write_bytes(key[:-1])
            with self.assertRaisesRegex(RuntimeError, "local IRK"):
                runner["load_local_irk"](path, "resume")

    def test_private_addresses_require_actual_resolution_and_matching_log(self):
        identity = hci.Address("12:34:56:78:9A:BC", hci.Address.PUBLIC_DEVICE_ADDRESS)
        # Public test key; never used for a hardware campaign.
        irk = bytes(range(16))
        connection = SimpleNamespace(peer_resolvable_address=hci.Address.generate_private_address(irk))
        device = SimpleNamespace(address_resolver=smp.AddressResolver([(irk, identity)]),
                                 random_address=hci.Address.generate_private_address(irk))
        addresses = runner["resolved_private_addresses"](device, connection, identity)
        fresh = (f'AUTH_PERSIST PRIVATE local={addresses["central"]} '
                 f'peer={addresses["peripheral"]} resolved=true\n').encode()
        runner["check_private_log"](fresh, addresses)
        for malformed in (b"", fresh.replace(b"resolved=true", b"resolved=false"),
                          fresh.replace(addresses["central"].encode(), b"000000000000"),
                          fresh.replace(addresses["peripheral"].encode(), b"000000000000")):
            with self.assertRaisesRegex(RuntimeError, "observations"):
                runner["check_private_log"](malformed, addresses)
        device.address_resolver = smp.AddressResolver([])
        with self.assertRaisesRegex(RuntimeError, "independently resolved"):
            runner["resolved_private_addresses"](device, connection, identity)
        device.address_resolver = smp.AddressResolver([(irk, identity)])
        device.random_address = hci.Address.generate_static_address()
        with self.assertRaisesRegex(RuntimeError, "Peripheral"):
            runner["resolved_private_addresses"](device, connection, identity)


if __name__ == "__main__":
    unittest.main()
