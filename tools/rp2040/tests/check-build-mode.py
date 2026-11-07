#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Verify an ordinary make build replaces a cached, non-runnable envelope base."""
import argparse
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[3]


def read_cache(build):
    result = {}
    for line in (build / "CMakeCache.txt").read_text().splitlines():
        if line and not line.startswith(("#", "//")) and "=" in line:
            key, value = line.split("=", 1)
            result[key.split(":", 1)[0]] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="An existing ordinary VM build")
    args = parser.parse_args()
    build = args.build.resolve()
    cache = read_cache(build)
    assert cache["TOIT_RP2040_BUILD_VM"] == "ON"
    assert cache["TOIT_RP2040_TEST_FAULT"] == ""
    assert cache["TOIT_RP2040_TEST_STORAGE_INTERRUPTION"] == "OFF"

    def configure(mode):
        subprocess.run(["cmake", "-S", str(ROOT / "toolchains/rp2040"),
                        "-B", str(build), f"-DTOIT_RP2040_ENVELOPE_BASE={mode}"],
                       check=True)

    def compile_native():
        subprocess.run(["cmake", "--build", str(build), "--target", "toit-rp2040",
                        "--parallel", "4"], check=True)

    def symbols():
        output = subprocess.check_output(
            [cache["CMAKE_NM"], str(build / "toit-rp2040.elf")], text=True)
        return {line.split()[-1] for line in output.splitlines() if line.split()}

    passed = False
    try:
        configure("ON")
        compile_native()
        assert "toit_program_0" not in symbols(), "Fixture still contains a system image"
        subprocess.run([
            "make", "rp2040", f"RP2040_VM_BUILD={build}",
            f"RP2040_BOARD={cache['PICO_BOARD']}",
            f"RP2040_PROGRAM={cache['TOIT_RP2040_PROGRAM']}",
            f"RP2040_PROJECT_ROOT={cache['TOIT_RP2040_PROJECT_ROOT']}",
            f"TOIT_BIN={cache['TOIT_HOST']}",
            f"BUILD_TYPE={cache['CMAKE_BUILD_TYPE']}",
            "RP2040_CMAKE_FLAGS=",
        ], cwd=ROOT, check=True)
        assert read_cache(build)["TOIT_RP2040_ENVELOPE_BASE"] == "OFF", \
            "Ordinary make retained envelope-base mode"
        embedded = symbols()
        assert {"toit_program_0", "toit_program_1"} <= embedded, \
            "Ordinary image is missing its system or application"
        passed = True
    finally:
        if not passed:
            # Even a regression failure must leave this build runnable again.
            configure("OFF")
            compile_native()
    print("PASS: ordinary make replaces envelope base with system and application")


if __name__ == "__main__":
    main()
