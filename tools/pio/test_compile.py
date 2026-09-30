# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license in lib/LICENSE.
import importlib.util
from pathlib import Path
import subprocess
import json
import unittest
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("pio_compile", Path(__file__).with_name("compile.py"))
compiler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compiler)


class GeneratorTest(unittest.TestCase):
    def test_checked_in_programs(self):
        raw = subprocess.check_output([str(ROOT / "build/pioasm/pioasm"), "-o", "json",
                                       str(ROOT / "tests/pio/programs.pio")], text=True)
        document = json.loads(raw)
        generated = compiler.generate(document)
        self.assertEqual(generated, (ROOT / "tests/pio/programs.toit").read_text())
        self.assertIn("--auto-push", generated)
        self.assertIn("--in-shift=pio.SHIFT-LEFT", generated)
        self.assertIn("--fifo=2", generated)

    def test_metadata(self):
        source = """.program metadata
.pio_version 1
.origin 4
.side_set 1 opt pindirs
.in 1 left auto 8
.out 1 right auto 24
.set 1
.fifo tx
.clock_div 2.5
.mov_status irq set 2
.define public value 7
public entry:
.wrap_target
    nop side 1 [2]
.wrap
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metadata.pio"
            path.write_text(source)
            raw = subprocess.check_output([str(ROOT / "build/pioasm/pioasm"), "-o", "json", str(path)], text=True)
        generated = compiler.generate(json.loads(raw))
        for expected in ["--origin=4", "--pio-version=1", "--side-count=1",
                         "--side-optional", "--side-pindirs", "--push-threshold=8",
                         "--pull-threshold=24", "--clock-divider=2.5", "--mov-status=2",
                         "METADATA-ENTRY ::= 0", "METADATA-VALUE ::= 7"]:
            self.assertIn(expected, generated)

    def test_colliding_exports(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            compiler.generate({"publicSymbols": {"foo_bar": 1, "FOO_BAR": 2}, "programs": []})

    def test_invalid_names(self):
        for name in ["", "1name", "a.b", "a--b"]:
            with self.assertRaises(ValueError):
                compiler.constant(name)


if __name__ == "__main__":
    unittest.main()
