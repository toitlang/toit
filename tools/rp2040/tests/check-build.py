#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Verify application selection and imported-source rebuilds in an RP2040 build."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    args = parser.parse_args()
    build = args.build.resolve()
    cache = {}
    for line in (build / "CMakeCache.txt").read_text().splitlines():
        if line and not line.startswith(("#", "//")) and "=" in line:
            key, value = line.split("=", 1)
            cache[key.split(":", 1)[0]] = value
    keys = ("TOIT_RP2040_PROGRAM", "TOIT_RP2040_PROJECT_ROOT")
    original = {key: cache[key] for key in keys}

    def configure(values):
        subprocess.run(["cmake", "-S", cache["CMAKE_HOME_DIRECTORY"], "-B", str(build),
                        *[f"-D{key}={value}" for key, value in values.items()]], check=True)

    def compile_snapshot():
        subprocess.run(["cmake", "--build", str(build), "--target",
                        "boot.snapshot", "application.snapshot"],
                       check=True)
        return (build / "application.snapshot").read_bytes()

    with tempfile.TemporaryDirectory(prefix="dependency-test-", dir=build) as directory:
        root = Path(directory)
        entry = root / "entry.toit"
        dependency = root / "dependency.toit"
        entry.write_text("import .dependency as dependency\nmain:\n  dependency.run\n")
        dependency.write_text('run:\n  print "first dependency"\n')
        try:
            configure({keys[0]: str(entry), keys[1]: str(root)})
            first = compile_snapshot()
            system_timestamp = (build / "boot.snapshot").stat().st_mtime_ns
            timestamp = (build / "application.snapshot").stat().st_mtime_ns
            assert compile_snapshot() == first
            assert (build / "application.snapshot").stat().st_mtime_ns == timestamp, \
                "Unchanged inputs rebuilt the snapshot"
            # Only the depfile knows about this source: it is outside the SDK's
            # library/system globs and is not the application's entry point.
            dependency.write_text('run:\n  print "changed dependency"\n')
            assert compile_snapshot() != first, "Imported source change was ignored"
            entry.write_text('main:\n  print "different application"\n')
            second = compile_snapshot()
            assert second != first, "Application source change was ignored"
            other = root / "other.toit"
            other.write_text('main:\n  print "selected application"\n')
            configure({keys[0]: str(other), keys[1]: str(root)})
            assert compile_snapshot() != second, "Application selection was ignored"
            # Resolve local package paths relative to the application's own
            # root, rather than the generated system image's build directory.
            package = root / "local"
            (package / "src").mkdir(parents=True)
            (package / "package.yaml").write_text("name: local\n")
            (package / "src" / "local.toit").write_text('run:\n  print "local package"\n')
            (root / "package.yaml").write_text("name: application\n")
            entry.write_text("import local\nmain:\n  local.run\n")
            for path in ("local", str(package)):
                (root / "package.lock").write_text(
                    "prefixes:\n  local: local\npackages:\n  local:\n"
                    f"    path: {path}\n")
                configure({keys[0]: str(entry), keys[1]: str(root)})
                compile_snapshot()
            assert (build / "boot.snapshot").stat().st_mtime_ns == system_timestamp, \
                "Application changes rebuilt the system snapshot"
        finally:
            configure(original)
            subprocess.run(["cmake", "--build", str(build), "--target", "toit-rp2040",
                            "--parallel", "4"], check=True)
    print("PASS: application selection, imported dependencies, and incremental builds")


if __name__ == "__main__":
    main()
