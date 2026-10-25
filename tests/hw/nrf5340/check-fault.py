# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Verify native fault recovery, or the optional debugger halt policy, on the E83."""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esp-serial", required=True)
    parser.add_argument("--nrf-serial", required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--halt", action="store_true")
    parser.add_argument("--elf", type=Path, help="Matching native ELF; required with --halt")
    args = parser.parse_args()
    if args.halt and not args.elf:
        parser.error("--halt requires the matching --elf")
    args.log_dir.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, "-u", str(Path(__file__).with_name("check-gpio.py")),
               "--esp-serial", args.esp_serial, "--nrf-serial", args.nrf_serial,
               "--image", str(args.image.resolve()), "--log-dir", str(args.log_dir.resolve()),
               "--native", "--allow-reboots", "--boot-marker", "NRF5340 NATIVE FAULT BOOT",
               "--release-pin", "18", "--expect", "NRF5340 NATIVE FAULT PASS",
               "--seconds", "4" if args.halt else "30"]
    with (args.log_dir / "paired.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=150)
    console = (args.log_dir / "console.log").read_text()
    phases = [int(value) for value in re.findall(r"NATIVE FAULT phase=(\d+) cause=0x2", console)]
    injections = [int(value) for value in re.findall(r"NATIVE FAULT injecting phase=(\d+)", console)]
    reasons = [int(value) for value in re.findall(r"native fatal error=(\d+); resetting chip", console)]
    if not args.halt:
        assert result.returncode == 0, (args.log_dir / "paired.log").read_text()
        assert phases == list(range(7)), phases
        assert injections == list(range(6)), injections
        # Zephyr reports an ARM-specific undefined-instruction reason (36),
        # not the generic K_ERR_CPU_EXCEPTION (0).
        assert reasons == [4, 4, 36, 4, 4, 36], reasons
        assert console.count("NRF5340 NATIVE FAULT BOOT") == 7
        assert "NATIVE FAULT interrupt-context phase=4" in console
        assert "NATIVE FAULT interrupt-context phase=5" in console
        assert "Paired test PASS (38 fixture requests, output released, 7 boots observed)" in (args.log_dir / "paired.log").read_text()
        print("NRF5340 NATIVE FAULT RECOVERY PASS: 6 faults, 7 boots, 38 fixture requests")
        return

    assert result.returncode != 0, "Halt configuration unexpectedly reached the final PASS"
    assert "Missing expected console marker: NRF5340 NATIVE FAULT PASS" in (args.log_dir / "paired.log").read_text()
    assert phases == [0] and injections == [0] and not reasons, console
    assert console.count("NRF5340 NATIVE FAULT BOOT") == 1
    # Prove that the core is actually in Zephyr's halt loop, rather than
    # treating a missing serial reply as proof of a halted fault.
    symbols = subprocess.check_output(["arm-none-eabi-nm", "-S", str(args.elf)], text=True)
    match = re.search(r"^([0-9a-f]+) ([0-9a-f]+) \w arch_system_halt$", symbols, re.M)
    assert match, "ELF has no arch_system_halt symbol"
    start, size = (int(value, 16) for value in match.groups())
    spec = importlib.util.spec_from_file_location("nrf_deploy", ROOT / "tools/nrf5340/deploy.py")
    deploy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(deploy)
    with deploy.debugger(ROOT / ".cache/nrf5340/openocd/src/openocd",
                         args.log_dir / "halt-openocd.log") as debug:
        debug.call("halt")
        registers = debug.call("get_reg pc")
        match = re.search(r"pc (0x[0-9a-fA-F]+)", registers)
        assert match, registers
        pc = int(match.group(1), 16)
        assert start <= pc < start + size, f"PC {pc:#x} is outside the halt loop"
    message = f"NRF5340 NATIVE FAULT HALT PASS: PC={pc:#x}, halt range={start:#x}..{start + size:#x}"
    (args.log_dir / "halt-check.log").write_text(message + "\n")
    print(message)


if __name__ == "__main__":
    main()
