# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Offline checks for recovery backup integrity and safe bundle publication."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("prepare_recovery", ROOT / "tools/nrf5340/prepare-recovery.py")
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "bundle"
        app = bytearray(b"\xff" * recovery.APP_SIZE)
        struct.pack_into("<II", app, 0, 0x20001000, 0x101)
        app[recovery.STORAGE_BASE:recovery.STORAGE_BASE + 16] = b"preserved record"
        app[recovery.FIRMWARE_LIMIT:recovery.FIRMWARE_LIMIT + 16] = b"settings record!"
        uicr = bytearray(b"\xff" * recovery.UICR_SIZE)
        for offset in (0, 0x1c):
            struct.pack_into("<I", uicr, offset, recovery.UNPROTECTED)
        raw = uicr[:0x800] + struct.pack("<I", 0xdeaddead) * 512
        self.plan = {
            "network_original_recoverable": False,
            "application_restore": {
                "application": self.record("app.bin", app),
                "application-uicr": dict(self.record("uicr.bin", uicr),
                                         nonempty_key_slots=0, all_key_slots_readable=True),
                "application-uicr-raw": self.record("raw.bin", raw),
                "network": {"backed_up": False},
            },
            "images": {},
        }
        for name in ("controller", "native-probe", "optional-vm"):
            sp, pc = (0x21001000, 0x01000011) if name == "controller" else (0x20001000, 0x11)
            data = struct.pack("<II", sp, pc) + bytes(248)
            self.plan["images"][name] = dict(self.record(name + ".bin", data, "path"),
                                              vectors=[hex(sp), hex(pc)])

    def record(self, name, data, key="file"):
        (self.root / name).write_bytes(data)
        return {key: name, "size": len(data), "sha256": recovery.digest(data)}

    def prepare(self):
        path = self.root / "plan.json"
        path.write_text(json.dumps(self.plan))
        return recovery.prepare(path, self.root, self.output)

    def test_complete_bundle_keeps_storage_and_separates_raw_evidence(self):
        manifest = self.prepare()
        self.assertFalse(manifest["hardware_validated"])
        self.assertEqual(manifest["status"], "prepared-offline-not-authorized")
        self.assertEqual(manifest["files"]["application-uicr-restorable.bin"]["program_address"], 0xff8000)
        self.assertIsNone(manifest["files"]["evidence/application-uicr-raw.bin"]["program_address"])
        self.assertEqual((self.output / "evidence/storage.bin").read_bytes(),
                         (self.root / "app.bin").read_bytes()[recovery.STORAGE_BASE:])
        for name, record in manifest["files"].items():
            data = (self.output / name).read_bytes()
            self.assertEqual(record["sha256"], recovery.digest(data))
            self.assertEqual(record["size"], len(data))
        self.assertEqual(json.loads((self.output / "manifest.json").read_text()), manifest)

    def test_tampered_file_rejected_before_any_output(self):
        (self.root / "controller.bin").write_bytes(bytes(256))
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_settings_backup_preserved_separately(self):
        self.prepare()
        self.assertEqual((self.output / "evidence/settings.bin").read_bytes(),
                         (self.root / "app.bin").read_bytes()[recovery.FIRMWARE_LIMIT:recovery.STORAGE_BASE])

    def test_probe_cannot_overlap_settings(self):
        data = struct.pack("<II", 0x20001000, 0x11) + bytes(recovery.FIRMWARE_LIMIT - 7)
        self.plan["images"]["native-probe"] = self.record("overlap-settings.bin", data, "path")
        self.plan["images"]["native-probe"]["vectors"] = ["0x20001000", "0x11"]
        with self.assertRaisesRegex(ValueError, "overlaps persistent storage"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_truncated_full_backup_rejected_even_with_matching_hash(self):
        self.plan["application_restore"]["application"] = self.record("short.bin", bytes(256))
        with self.assertRaisesRegex(ValueError, "size"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_masked_or_nonempty_keys_cannot_be_restored(self):
        original = copy.deepcopy(self.plan["application_restore"]["application-uicr"])
        for offset, value in ((0x800, 0xdeaddead), (0x800, 0), (0x400, 0), (0x20, 0)):
            with self.subTest(offset=offset, value=value):
                data = bytearray((self.root / "uicr.bin").read_bytes())
                struct.pack_into("<I", data, offset, value)
                record = dict(original, **self.record("unsafe.bin", data))
                self.plan["application_restore"]["application-uicr"] = record
                with self.assertRaisesRegex(ValueError, "UICR"):
                    self.prepare()
        self.assertFalse(self.output.exists())

    def test_missing_kmu_evidence_is_rejected(self):
        for field, value in (("nonempty_key_slots", 1), ("all_key_slots_readable", False)):
            record = self.plan["application_restore"]["application-uicr"]
            original = record[field]
            record[field] = value
            with self.assertRaisesRegex(ValueError, "KMU"):
                self.prepare()
            record[field] = original

    def test_reset_vector_must_address_correct_core_image(self):
        for stack, pc in ((0x20001000, 0x01000011), (0x21001004, 0x01000011),
                          (0x21001000, 0x01000010), (0x21001000, 0x01000101)):
            with self.subTest(stack=stack, pc=pc):
                data = struct.pack("<II", stack, pc) + bytes(248)
                self.plan["images"]["controller"] = dict(self.record("bad.bin", data, "path"),
                                                          vectors=[hex(stack), hex(pc)])
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_probe_cannot_overlap_storage(self):
        data = struct.pack("<II", 0x20001000, 0x11) + bytes(recovery.STORAGE_BASE)
        self.plan["images"]["native-probe"] = dict(self.record("large.bin", data, "path"),
                                                    vectors=["0x20001000", "0x11"])
        with self.assertRaisesRegex(ValueError, "storage"):
            self.prepare()

    def test_existing_bundle_never_overwritten(self):
        self.prepare()
        before = (self.output / "manifest.json").read_bytes()
        with self.assertRaisesRegex(ValueError, "existing"):
            self.prepare()
        self.assertEqual((self.output / "manifest.json").read_bytes(), before)

    def test_failed_publication_does_not_leave_valid_bundle(self):
        with patch.object(recovery.os, "rename", side_effect=OSError("disk failure")):
            with self.assertRaisesRegex(OSError, "disk failure"):
                self.prepare()
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob(".recovery-*")), [])

    def test_disappearing_source_after_validation_does_not_change_bundle(self):
        original = recovery.collect
        expected = (self.root / "app.bin").read_bytes()

        def collect_then_replace(plan, root):
            files = original(plan, root)
            (root / "app.bin").write_bytes(b"new build")
            return files

        with patch.object(recovery, "collect", side_effect=collect_then_replace):
            self.prepare()
        self.assertEqual((self.output / "application.bin").read_bytes(), expected)


if __name__ == "__main__":
    unittest.main()
