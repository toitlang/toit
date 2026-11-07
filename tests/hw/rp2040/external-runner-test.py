#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Check wiring-failure gating and restoration without accessing hardware."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "external_peripherals", Path(__file__).with_name("external-peripherals.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTest(unittest.TestCase):
    def exercise(self, fail_at=None, wiring_only=False):
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            paths = {}
            for name in ("wiring", "external", "restore"):
                paths[name] = Path(directory) / f"{name}.bin"
                paths[name].write_bytes(b"fixture")
            argv = ["runner", "--uploader", "upload", "--port", "test-port",
                    "--id", "test-id", "--wiring-image", str(paths["wiring"]),
                    "--restore-image", str(paths["restore"]), "--jag", "jag",
                    "--helper-device", "helper", "--helper-repo", directory]
            if not wiring_only:
                argv += ["--image", str(paths["external"])]

            def run(command, **kwargs):
                calls.append(Path(command[-1]).name)

            def wait(port, marker):
                name = marker.removesuffix(": READY")

                class Console:
                    def line(self, deadline):
                        if name == fail_at:
                            return f"{name}: FAIL wrong wire or transfer"
                        return f"{name}: PASS"

                return io.StringIO(), Console()

            with patch.object(runner.sys, "argv", argv), \
                 patch.object(runner.upload, "validate_image"), \
                 patch.object(runner.subprocess, "run", side_effect=run), \
                 patch.object(runner.stdio, "wait_application", side_effect=wait), \
                 contextlib.redirect_stdout(io.StringIO()):
                if fail_at:
                    with self.assertRaisesRegex(RuntimeError, "FAIL"):
                        runner.main()
                else:
                    runner.main()
        self.assertEqual(calls[-2:], ["restore.bin", "helper-idle-esp32.toit"])
        return calls

    def test_wrong_wiring_never_installs_output_fixture(self):
        calls = self.exercise(fail_at="peripheral-wiring-rp2040")
        self.assertNotIn("external.bin", calls)
        self.assertNotIn("external-peripherals-esp32.toit", calls)

    def test_transfer_failure_restores_both_devices(self):
        self.exercise(fail_at="external-peripherals-rp2040")

    def test_success_checks_wiring_before_outputs(self):
        self.assertEqual(self.exercise(), [
            "wiring.bin", "peripheral-wiring-esp32.toit",
            "external.bin", "external-peripherals-esp32.toit",
            "restore.bin", "helper-idle-esp32.toit",
        ])

    def test_wiring_only_does_not_install_outputs(self):
        self.assertNotIn("external.bin", self.exercise(wiring_only=True))


if __name__ == "__main__":
    unittest.main()
