# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Recovery failure injection with a memory-model debugger, without hardware."""
import json
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/nrf5340"))
import recover


def images():
    app = bytearray(b"\xa5" * 0x100000)
    struct.pack_into("<II", app, 0, 0x20001000, 0x101)
    uicr = bytearray(b"\xff" * 4096)
    for offset in (0, 0x1c):
        struct.pack_into("<I", uicr, offset, 0x50fa50fa)
    return {"application.bin": bytes(app), "application-uicr-restorable.bin": bytes(uicr),
            "controller.bin": struct.pack("<II", 0x21001000, 0x01000011) + bytes(248)}


class Debugger:
    def __init__(self, files):
        self.app = bytearray(files["application.bin"])
        self.uicr = bytearray(files["application-uicr-restorable.bin"])
        self.net = bytearray(b"\x42" * 0x40000)
        self.healthy = True
        self.commands = []
        self.selected = 0
        self.kmu_status = 0
        self.forceoff = 1
        self.state = "running"
        self.target = recover.APP
        self.erases = 0
        self.protected = False
        self.busy = False
        self.fail_command = None
        self.fail_after_erase = False
        self.corrupt_write = False
        self.key_reads = set()

    def call(self, command):
        self.commands.append(command)
        if self.fail_command and self.fail_command(command):
            self.healthy = False
            raise TimeoutError("injected transport failure")
        tokens = command.split()
        if tokens[0] == "poll":
            return ""
        if tokens[0] == "targets":
            self.target = tokens[1]
            return ""
        if command == "resume":
            self.state = "running"
            return ""
        if command == "reset halt":
            self.state = "halted"
            self.forceoff = 1
            return ""
        if tokens[0] == recover.DAP:
            ap, register = int(tokens[2]), int(tokens[3], 0)
            if len(tokens) == 4:
                return str({0xfc: 0x12880000, 0x18: int(not self.protected),
                            8: int(self.busy)}[register])
            value = int(tokens[4], 0)
            if register == 4 and value == 1:
                assert ap == 3
                self.erases += 1
                self.app[:] = b"\xff" * len(self.app)
                self.net[:] = b"\xff" * len(self.net)
                self.uicr[:] = b"\xff" * len(self.uicr)
                struct.pack_into("<I", self.uicr, 0, 0x50fa50fa)
                if self.fail_after_erase:
                    self.healthy = False
                    raise TimeoutError("erase accepted but reply lost")
            elif register not in (0, 4):
                raise AssertionError("Unexpected control write")
            return ""
        if tokens[0] in (recover.APP, recover.NET):
            operation = tokens[1]
            if operation == "curstate":
                return self.state
            if operation == "arp_halt":
                self.state = "halted"
                return ""
            if operation in ("arp_waitstate", "arp_examine", "arp_poll"):
                return ""
            if operation == "read_memory":
                address, width, count = [int(t, 0) for t in tokens[2:]]
                assert width == 32 and count <= 64
                length = count * 4
                fixed = {recover.FORCEOFF: self.forceoff, recover.SELECT: self.selected,
                         recover.KMU_STATUS: self.kmu_status, 0xff020c: 0x5340,
                         0xff0204: 0x11223344, 0xff0208: 0x55667788}
                if address in fixed:
                    return " ".join(str(fixed[address + offset * 4]) for offset in range(count))
                if address < len(self.app):
                    data = self.app[address:address + length]
                elif recover.UICR <= address < recover.UICR + 4096:
                    offset = address - recover.UICR
                    if offset >= 0x800:
                        slot = (offset - 0x800) // 16
                        assert self.selected == slot + 1
                        self.key_reads.add(slot)
                        self.kmu_status = 1
                    data = self.uicr[offset:offset + length]
                elif 0x01000000 <= address < 0x01040000:
                    offset = address - 0x01000000
                    data = self.net[offset:offset + length]
                else:
                    raise AssertionError(f"Unexpected read {address:x}")
                return " ".join(str(w) for w in struct.unpack(f"<{count}I", data))
            if operation == "mww":
                address, value = [int(t, 0) for t in tokens[2:]]
                if address == recover.SELECT:
                    self.selected = value
                    self.kmu_status = 0
                elif address == recover.FORCEOFF:
                    self.forceoff = value
                elif address not in (recover.WORKAROUND, 0xe000edfc):
                    raise AssertionError(f"Unexpected write {address:x}")
                return ""
        if tokens[:2] == ["flash", "write_image"]:
            match = re.fullmatch(r"flash write_image \{([^}]+)\} (\S+) bin", command)
            assert match, "Unexpected flash operation (including erase)"
            path, address = match.groups()
            address = int(address, 0)
            data = Path(path).read_bytes()
            if address == 0:
                assert self.target == recover.APP
                memory, offset = self.app, 0
            elif address >= 0x01000000:
                assert self.target == recover.NET
                memory, offset = self.net, address - 0x01000000
            else:
                assert self.target == recover.APP and address in (recover.UICR, recover.UICR + 0x1c)
                assert len(data) == 4  # Never write the masked key window.
                memory, offset = self.uicr, address - recover.UICR
            for i, byte in enumerate(data):
                memory[offset + i] &= byte
            if self.corrupt_write:
                memory[offset + 8] = 0
            return ""
        raise AssertionError(f"Unsupported command: {command}")


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.files = images()
        self.debug = Debugger(self.files)

    def run_recovery(self, **kwargs):
        kwargs.setdefault("device_id", "4433221188776655")
        return recover.recover(self.debug, self.files, self.directory, **kwargs)

    def test_device_mismatch_prevents_erase(self):
        with self.assertRaisesRegex(RuntimeError, "identity"):
            self.run_recovery(execute=True, device_id="0000000000000000")
        self.assertEqual(self.debug.erases, 0)

    def test_recovery_without_device_id_never_opens_target(self):
        with self.assertRaisesRegex(ValueError, "device ID"):
            self.run_recovery(execute=True, device_id=None)
        self.assertEqual(self.debug.commands, [])

    def test_check_only_reads_all_flash_and_keys_then_resumes(self):
        result = self.run_recovery()
        self.assertEqual(result["status"], "checked-no-erase")
        self.assertEqual(self.debug.erases, 0)
        self.assertEqual(self.debug.state, "running")
        self.assertEqual(self.debug.key_reads, set(range(128)))
        self.assertEqual(self.debug.selected, 0)
        self.assertFalse(any(c.startswith("flash") for c in self.debug.commands))

    def test_check_preserves_already_halted_state(self):
        self.debug.state = "halted"
        self.run_recovery()
        self.assertNotIn("resume", self.debug.commands)

    def test_full_recovery_restores_storage_and_installs_controller_without_running(self):
        result = self.run_recovery(execute=True)
        self.assertEqual(result["status"], "restored-and-verified-not-started")
        self.assertEqual(self.debug.erases, 1)
        self.assertEqual(self.debug.app, self.files["application.bin"])
        self.assertEqual(self.debug.uicr, self.files["application-uicr-restorable.bin"])
        controller = self.files["controller.bin"]
        self.assertEqual(self.debug.net[:len(controller)], controller)
        self.assertEqual(self.debug.net[len(controller):], b"\xff" * (0x40000 - len(controller)))
        self.assertEqual(self.debug.forceoff, 1)
        self.assertNotIn("resume", self.debug.commands)

    def test_stale_backup_aborts_before_erase(self):
        self.debug.app[-1] ^= 1  # Includes the last byte of the storage journal.
        with self.assertRaisesRegex(RuntimeError, "backup"):
            self.run_recovery(execute=True)
        self.assertEqual(self.debug.erases, 0)

    def test_nonempty_key_aborts_and_restores_kmu_selection(self):
        self.debug.uicr[0x800 + 127 * 16] = 0
        with self.assertRaisesRegex(RuntimeError, "slot 128"):
            self.run_recovery(execute=True)
        self.assertEqual(self.debug.selected, 0)
        self.assertEqual(self.debug.erases, 0)

    def test_erase_protection_never_disabled(self):
        self.debug.protected = True
        with self.assertRaisesRegex(RuntimeError, "protection"):
            self.run_recovery(execute=True)
        self.assertEqual(self.debug.erases, 0)
        self.assertFalse(any(c.startswith(recover.DAP) and len(c.split()) == 5
                             for c in self.debug.commands))

    def test_ambiguous_erase_is_not_retried_or_resumed(self):
        self.debug.fail_after_erase = True
        with self.assertRaisesRegex(TimeoutError, "reply lost"):
            self.run_recovery(execute=True)
        self.assertEqual(self.debug.erases, 1)
        self.assertNotIn("resume", self.debug.commands)
        self.assertFalse(any(c.startswith("flash") for c in self.debug.commands))
        self.assertEqual(json.loads((self.directory / "state.json").read_text())["stage"],
                         "erase-may-have-started")

    def test_erase_timeout_prevents_reset_and_programming(self):
        original = self.debug.call

        def call(command):
            result = original(command)
            if self.debug.erases:
                self.debug.busy = True
            return result

        self.debug.call = call
        with self.assertRaisesRegex(RuntimeError, "completion"):
            self.run_recovery(execute=True, erase_timeout=0)
        self.assertEqual(self.debug.erases, 1)
        self.assertNotIn("reset halt", self.debug.commands)
        self.assertFalse(any(c.startswith("flash") for c in self.debug.commands))

    def test_failed_restore_does_not_install_controller(self):
        self.debug.corrupt_write = True
        with self.assertRaisesRegex(RuntimeError, "Restored application"):
            self.run_recovery(execute=True)
        self.assertFalse(any("controller.bin}" in c for c in self.debug.commands))
        self.assertNotIn("resume", self.debug.commands)

    def test_transport_failure_never_resumes_or_continues(self):
        for prefix in (f"{recover.APP} read_memory 0x0 ", "flash write_image",
                       f"{recover.NET} arp_examine", f"{recover.NET} read_memory"):
            with self.subTest(prefix=prefix):
                self.debug = Debugger(self.files)
                self.debug.fail_command = lambda command: command.startswith(prefix)
                with self.assertRaises(TimeoutError):
                    self.run_recovery(execute=True)
                self.assertTrue(self.debug.commands[-1].startswith(prefix))
                self.assertNotIn("resume", self.debug.commands)
                self.assertTrue((self.directory / "not-resumed.txt").exists())


if __name__ == "__main__":
    unittest.main()
