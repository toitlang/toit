# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Host checks for deployment format validation and preservation of allocations."""
import importlib.util
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("nrf_deploy", ROOT / "tools/nrf5340/deploy.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
SDK = bytes(range(16))
ID = uuid.UUID("155f1b6c-1019-4086-9c87-e58bc2672595")


def encoded_image(assets=False):
    data = bytearray(deploy.PAGE * (2 if assets else 1))
    struct.pack_into("<II", data, 0, deploy.MARKER, 0)
    data[8:24] = ID.bytes
    struct.pack_into("<H", data, 30, 1)
    data[32:48] = SDK
    struct.pack_into("<I", data, 48, 128)
    if assets:
        struct.pack_into("<I", data, deploy.PAGE, 5)
        data[deploy.PAGE + 4:deploy.PAGE + 9] = b"hello"
    return b"".join(struct.pack("<I", 1 << 12 if offset == 0 else 0) + data[offset:offset + 128]
                    for offset in range(0, len(data), 128))


def record(kind, offset, size, identity=ID, sdk=SDK):
    header = bytearray(deploy.HEADER_SIZE)
    struct.pack_into("<I", header, 0, deploy.MARKER)
    header[8:24] = identity.bytes
    header[29] = kind
    struct.pack_into("<H", header, 30, size // deploy.PAGE)
    header[32:48] = deploy.DATA_UUID if kind == 1 else sdk
    seed = deploy.MARKER if kind == 1 else deploy.crc(struct.pack("<I", deploy.BASE + offset), deploy.MARKER)
    struct.pack_into("<I", header, 4, deploy.crc(header[8:], seed))
    return header


class DeploymentTests(unittest.TestCase):
    def test_firmware_cannot_overlap_settings(self):
        with self.assertRaisesRegex(ValueError, "880 KiB"):
            deploy.firmware_sdk(bytes(deploy.FIRMWARE_LIMIT + 1))

    def test_relocation_and_assets_round_trip(self):
        image = deploy.Image(encoded_image(assets=True), SDK)
        address = deploy.BASE + 2 * deploy.PAGE
        relocated = image.relocate(address, 3, 0x12345678)
        self.assertEqual(deploy.u32(relocated, 48), address + 128)
        self.assertEqual(relocated[deploy.PAGE + 4:deploy.PAGE + 9], b"hello")
        storage = bytearray(b"\xff" * deploy.STORAGE_SIZE)
        storage[2 * deploy.PAGE:4 * deploy.PAGE] = relocated
        found = deploy.scan(storage, SDK)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["id"], str(ID))
        self.assertEqual(found[0]["flags"], 0x83)
        self.assertEqual(found[0]["data"], 0x12345678)

    def test_reject_wrong_sdk_and_malformed_image(self):
        valid = encoded_image()
        with self.assertRaisesRegex(ValueError, "SDK"):
            deploy.Image(valid, b"x" * 16)
        for bad in (valid[:-1], b"\0" * len(valid)):
            with self.assertRaises(ValueError):
                deploy.Image(bad, SDK)
        outside = bytearray(valid)
        struct.pack_into("<I", outside, 52, deploy.PAGE + 1)
        with self.assertRaisesRegex(ValueError, "Relocation"):
            deploy.Image(outside, SDK)

    def test_reject_invalid_asset_length_and_relocations(self):
        encoded = bytearray(encoded_image(assets=True))
        assets_at = deploy.PAGE // 128 * 132
        struct.pack_into("<I", encoded, assets_at + 4, deploy.PAGE)
        with self.assertRaisesRegex(ValueError, "assets length"):
            deploy.Image(encoded, SDK)
        encoded = bytearray(encoded_image(assets=True))
        struct.pack_into("<I", encoded, assets_at, 1)
        with self.assertRaisesRegex(ValueError, "Assets"):
            deploy.Image(encoded, SDK)

    def test_preserve_data_and_foreign_programs(self):
        storage = bytearray(b"\xff" * deploy.STORAGE_SIZE)
        storage[:48] = record(1, 0, 2 * deploy.PAGE)
        # A header-looking payload inside data must not become another allocation.
        storage[deploy.PAGE:deploy.PAGE + 48] = record(0, deploy.PAGE, deploy.PAGE)
        storage[3 * deploy.PAGE:3 * deploy.PAGE + 48] = record(0, 3 * deploy.PAGE, deploy.PAGE, sdk=b"z" * 16)
        found = deploy.scan(storage, SDK)
        self.assertEqual([allocation["offset"] for allocation in found], [0, 3 * deploy.PAGE])
        self.assertFalse(found[1]["compatible"])
        self.assertEqual(deploy.free_slot(found, deploy.PAGE), 2 * deploy.PAGE)
        self.assertEqual(deploy.free_slot(found, 2 * deploy.PAGE), 4 * deploy.PAGE)
        with self.assertRaisesRegex(ValueError, "No contiguous space"):
            deploy.free_slot(found, deploy.CAPACITY)

    def test_valid_header_outside_partition_is_rejected(self):
        storage = bytearray(b"\xff" * deploy.STORAGE_SIZE)
        storage[:48] = record(1, 0, deploy.CAPACITY + deploy.PAGE)
        with self.assertRaisesRegex(ValueError, "outside"):
            deploy.scan(storage, SDK)

    def test_pending_journal_requires_firmware_recovery(self):
        storage = bytearray(b"\xff" * deploy.STORAGE_SIZE)
        descriptor = struct.pack("<II", 0, 123)
        descriptor += struct.pack("<II", deploy.crc(descriptor, deploy.JOURNAL_MAGIC), deploy.JOURNAL_MAGIC)
        storage[deploy.CAPACITY:deploy.CAPACITY + 16] = descriptor
        with self.assertRaisesRegex(ValueError, "journal needs recovery"):
            deploy.scan(storage, SDK)
        # An incomplete descriptor has not authorized a destination erase.
        storage[deploy.CAPACITY + 12:deploy.CAPACITY + 16] = b"\xff" * 4
        self.assertEqual(deploy.scan(storage, SDK), [])

    def test_destination_cannot_touch_firmware_or_journal(self):
        image = deploy.Image(encoded_image(), SDK)
        for address in (0, deploy.BASE - deploy.PAGE, deploy.BASE + 1, deploy.BASE + deploy.CAPACITY):
            with self.assertRaisesRegex(ValueError, "outside"):
                image.relocate(address, 1, 0)

    def test_crc_known_vector(self):
        self.assertEqual(deploy.crc(b"123456789", 0), 0xcbf43926)

    def test_timed_out_transport_cannot_accept_another_command(self):
        class BrokenSocket:
            writes = 0
            closed = False

            def sendall(self, data):
                self.writes += 1

            def recv(self, size):
                raise TimeoutError("simulated USB stall")

            def close(self):
                self.closed = True

        connection = BrokenSocket()
        debug = deploy.Debug(connection)
        with self.assertRaises(TimeoutError):
            debug.call("halt")
        with self.assertRaisesRegex(RuntimeError, "unusable"):
            debug.call("resume")
        self.assertEqual(connection.writes, 1)
        self.assertTrue(connection.closed)

    def test_programming_failure_does_not_restart_unverified_flash(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            calls = []

            class FailedWrite:
                healthy = True

                def call(self, command):
                    calls.append(command)
                    if command.endswith("curstate"):
                        return "running"
                    if "read_memory" in command:
                        return " ".join(["0xffffffff"] * 64)
                    if command.startswith("flash write_image erase"):
                        raise RuntimeError("simulated programming failure")
                    return ""

            args = SimpleNamespace(action="install", firmware=directory / "base.bin", run_boot=True,
                                   critical=False, data=0)
            with self.assertRaisesRegex(RuntimeError, "simulated programming failure"):
                deploy.operate(FailedWrite(), args, deploy.Image(encoded_image(), SDK), SDK, directory)
            self.assertNotIn("reset run", calls)
            self.assertTrue((directory / "not-resumed.txt").exists())


if __name__ == "__main__":
    unittest.main()
