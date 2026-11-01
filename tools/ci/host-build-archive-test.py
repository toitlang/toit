#!/usr/bin/env python3
# Zero-Clause BSD License

# Copyright (C) 2026 Toit contributors.

# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted.

# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
# FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
# OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.

"""Check that a transferred Ninja build survives a fresh checkout and CMake."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ARCHIVER = Path(__file__).with_name("host-build-archive.py").resolve()


class HostBuildArchiveTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="host-build-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "workspace with spaces"
        self.root.mkdir()
        self.archive = Path(self.temp.name) / "host-build.tar.gz"
        self.run_command("git", "init", "-q")
        (self.root / ".gitignore").write_text("build/\n.packages-bootstrap/\n")
        (self.root / "CMakeLists.txt").write_text('''
cmake_minimum_required(VERSION 3.20)
project(archive_test CXX)
add_executable(hello main.cc)
add_custom_target(check
  COMMAND ${CMAKE_COMMAND} -E echo "shard=$ENV{SHARD_START}"
  DEPENDS hello)
''')
        (self.root / "main.cc").write_text('#include "value.h"\nint main() { return VALUE; }\n')
        (self.root / "value.h").write_text("#define VALUE 0\n")
        self.run_command("git", "add", ".")
        self.run_command("git", "-c", "user.name=CI", "-c", "user.email=ci@example.com",
                         "commit", "-qm", "fixture")

    def run_command(self, *args, **kwargs):
        return subprocess.check_output(args, cwd=self.root, text=True,
                                       stderr=subprocess.STDOUT, **kwargs)

    def configure(self, shard):
        return self.run_command("cmake", "-S", ".", "-B", "build", "-G", "Ninja",
                                env=dict(os.environ, SHARD_START=str(shard)))

    def test_incremental_build_after_transfer(self):
        self.configure(1)
        self.run_command("cmake", "--build", "build", "--target", "check")
        source_times = {name: (self.root / name).stat().st_mtime_ns
                        for name in ("main.cc", "value.h", "CMakeLists.txt")}
        objects = list((self.root / "build").rglob("*.o"))
        # MSVC uses .obj; both forms must retain the timestamps in .ninja_deps.
        objects += list((self.root / "build").rglob("*.obj"))
        self.assertTrue(objects)
        binary = self.root / "build" / ("hello.exe" if os.name == "nt" else "hello")
        build_times = {path: path.stat().st_mtime_ns for path in [*objects, binary]}

        packages = self.root / ".packages-bootstrap"
        packages.mkdir()
        package = packages / "bootstrap.toit"
        package.write_text("bootstrap package\n")
        package_time = package.stat().st_mtime_ns
        if os.name != "nt":
            (self.root / "build" / "source-link").symlink_to(self.root / "main.cc")

        self.run_command(sys.executable, str(ARCHIVER), "pack", str(self.archive))
        shutil.rmtree(self.root / "build")
        shutil.rmtree(packages)
        # Checkouts set new timestamps even when the contents are identical.
        for name in source_times:
            path = self.root / name
            path.write_bytes(path.read_bytes())
        self.run_command(sys.executable, str(ARCHIVER), "unpack", str(self.archive))
        for name, mtime in source_times.items():
            self.assertEqual((self.root / name).stat().st_mtime_ns, mtime)
        self.assertEqual(package.stat().st_mtime_ns, package_time)
        if os.name != "nt":
            self.assertTrue((self.root / "build" / "source-link").is_symlink())

        self.configure(2)
        output = self.run_command("cmake", "--build", "build", "--target", "check")
        self.assertIn("shard=2", output)
        for path, mtime in build_times.items():
            self.assertEqual(path.stat().st_mtime_ns, mtime, output)
        self.assertIn("no work to do", self.run_command("ninja", "-C", "build", "-n", "hello"))
        # Preserving .ninja_deps matters: header changes must still rebuild.
        (self.root / "value.h").write_text("#define VALUE 1\n")
        self.assertNotIn("no work to do", self.run_command("ninja", "-C", "build", "-n", "hello"))

    def test_rejects_another_commit_before_extraction(self):
        (self.root / "build").mkdir()
        (self.root / "build" / "marker").write_text("original")
        self.run_command(sys.executable, str(ARCHIVER), "pack", str(self.archive))
        self.run_command("git", "-c", "user.name=CI", "-c", "user.email=ci@example.com",
                         "commit", "--allow-empty", "-qm", "different commit")
        (self.root / "build" / "marker").write_text("unchanged")
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.run_command(sys.executable, str(ARCHIVER), "unpack", str(self.archive))
        self.assertIn("different commit", error.exception.output)
        self.assertEqual((self.root / "build" / "marker").read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()
