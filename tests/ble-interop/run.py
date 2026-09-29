# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Explicitly run the optional Bumble BLE regression matrix; never installs packages."""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def run_peer(command, cwd, stream, timeout=45):
    # Each peer launches a Toit child. Kill the whole isolated process group
    # even if the peer hangs, is interrupted, or exits before its child.
    process = subprocess.Popen(command, cwd=cwd, stdout=stream,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            process.wait()


def cases():
    for mtu in (23, 247, 517):
        yield (f"transactions-{mtu}", "bumble-att.py", ["--mtu", str(mtu), "--transactions"],
               "att-server.toit", ["type-pages"],
               {"mtu": mtu, "multi_attribute_transactions": 3, "radio": False})
    yield ("type-pages-517", "bumble-att.py", ["--mtu", "517", "--type-pages"],
           "att-server.toit", ["type-pages"],
           {"mtu": 517, "type_page_pairs": 16, "radio": False})
    for mtu in (23, 247, 517):
        yield (f"descriptors-{mtu}", "bumble-att.py", ["--mtu", str(mtu), "--descriptors"],
               "descriptor-server.toit", [], {"mtu": mtu, "descriptors": True,
                                               "writable_description": True,
                                               "synthetic_security": True, "radio": False})
    for mtu in (23, 64, 128, 247, 517):
        yield (f"att-mtu-{mtu}", "bumble-att.py", ["--mtu", str(mtu), "--boundaries"],
               "att-server.toit", [], {"mtu": mtu, "boundaries": True})
    for mtu in (23, 247):
        yield (f"notifications-{mtu}", "bumble-att.py", ["--mtu", str(mtu), "--updates"],
               "att-server.toit", [], {"updates_received": 4})
    for mode, flag, expected in (
        ("confirmed", [], {"updates_received": 2, "confirmations_dropped": 0,
                           "confirmations_corrupted": 0}),
        ("timeout", ["--drop-confirmation"], {"updates_received": 1, "confirmations_dropped": 1}),
        ("malformed", ["--malformed-confirmation"], {"updates_received": 1, "confirmations_corrupted": 1}),
    ):
        yield (f"indication-{mode}", "bumble-att.py", ["--mtu", "23", "--indications"] + flag,
               "indication-server.toit", [], expected)
    yield ("toit-client", "bumble-server.py", [], "att-client.toit", [],
           {"role": "toit-client", "exchanges": 131})
    for legacy in (False, True):
        for role in ("initiator", "responder"):
            for bumble_io in (0, 2):
                toit_io = 2 if bumble_io == 0 else 0
                options = ["--toit-role", role, "--bumble-io", str(bumble_io)]
                if legacy:
                    options += ["--legacy"]
                name = f"passkey-{'legacy' if legacy else 'sc'}-{role}-toit-io-{toit_io}"
                yield (name, "bumble-passkey.py", options, "smp-passkey.toit",
                       [role, str(toit_io)],
                       {"legacy": legacy, "toit_role": role, "bumble_io": bumble_io,
                        "key_match": True})
            yield (f"passkey-{'legacy' if legacy else 'sc'}-{role}-wrong", "bumble-passkey.py",
                   ["--toit-role", role, "--bumble-io", "0", "--wrong"] + (["--legacy"] if legacy else []),
                   "smp-passkey.toit", [role, "2"], {"wrong_passkey_rejected": True})
    for role in ("initiator", "responder"):
        for own_io in (1, 3):
            for peer_io in range(5):
                options = ["--toit-role", role, "--peer-io", str(peer_io), "--rounds", "3"]
                arguments = ["responder"] if role == "responder" else []
                if own_io == 1:
                    options += ["--toit-display"]
                    arguments += ["display"]
                yield (f"smp-{role}-just-works-io-{own_io}-{peer_io}", "bumble-smp.py",
                       options, "smp-initiator.toit", arguments,
                       {"toit_role": role, "key_match": True, "rejected": False,
                        "numeric_comparison": False, "controller_encryption": False,
                        "peer_io": peer_io, "toit_io": own_io,
                        "rounds": 3, "distinct_toit_nonces": 3})
        yield (f"smp-{role}-numeric-keyboard-display", "bumble-smp.py",
               ["--toit-role", role, "--numeric", "--peer-no-mitm", "--peer-io", "4", "--rounds", "3"],
               "smp-initiator.toit", (["responder"] if role == "responder" else []) + ["numeric"],
               {"toit_role": role, "key_match": True, "rejected": False,
                "numeric_comparison": True, "controller_encryption": False,
                "peer_no_mitm": True, "peer_io": 4, "toit_io": 1,
                "rounds": 3, "distinct_toit_nonces": 3})
        yield (f"smp-{role}-numeric-peer-no-mitm", "bumble-smp.py",
               ["--toit-role", role, "--numeric", "--peer-no-mitm", "--rounds", "3"],
               "smp-initiator.toit", (["responder"] if role == "responder" else []) + ["numeric"],
               {"toit_role": role, "rejected": False, "key_match": True,
                "controller_encryption": False, "numeric_comparison": True,
                "peer_no_mitm": True, "rounds": 3, "distinct_toit_nonces": 3})
        for mode in ("just-works", "numeric", "reject"):
            options = ["--toit-role", role]
            arguments = ["responder"] if role == "responder" else []
            if mode != "just-works":
                options += ["--numeric"]
                arguments += ["numeric"]
            if mode == "reject":
                options += ["--reject"]
            yield (f"smp-{role}-{mode}", "bumble-smp.py", options, "smp-initiator.toit",
                   arguments, {"toit_role": role, "rejected": mode == "reject",
                               "key_match": mode != "reject", "controller_encryption": False,
                               "numeric_comparison": mode != "just-works"})
        yield (f"smp-{role}-bad-dhkey", "bumble-smp.py",
               ["--toit-role", role, "--corrupt-dhkey"], "smp-initiator.toit",
               (["responder"] if role == "responder" else []) + ["bad-dhkey"],
               {"toit_role": role, "rejected": True, "key_match": False,
                "dhkey_checks_corrupted": 1, "encryption_requests": 0,
                "controller_encryption": False, "numeric_comparison": False})
        yield (f"smp-{role}-invalid-public-key", "bumble-smp.py",
               ["--toit-role", role, "--invalid-public-key"], "smp-initiator.toit",
               (["responder"] if role == "responder" else []) + ["bad-public-key"],
               {"toit_role": role, "rejected": True, "key_match": False,
                "public_keys_replaced": 1, "encryption_requests": 0,
                "controller_encryption": False, "numeric_comparison": False})
        for shape in ("zero-y", "one-y", "flip-y"):
            yield (f"smp-{role}-invalid-public-key-{shape}", "bumble-smp.py",
                   ["--toit-role", role, "--invalid-public-key-shape", shape],
                   "smp-initiator.toit",
                   (["responder"] if role == "responder" else []) + ["bad-public-key", shape],
                   {"toit_role": role, "rejected": True, "key_match": False,
                    "public_keys_replaced": 1, "public_key_shape": shape,
                    "tester_even_scalar": True,
                    "encryption_requests": 0, "controller_encryption": False,
                    "numeric_comparison": False})

    yield ("smp-initiator-same-x-valid-point", "bumble-smp.py",
           ["--invalid-public-key-shape", "same-x"], "smp-initiator.toit",
           ["bad-public-key", "same-x"],
           {"toit_role": "initiator", "rejected": True, "key_match": False,
            "public_keys_replaced": 1, "public_key_shape": "same-x",
            "same_x_valid_point": True, "tester_even_scalar": False,
            "encryption_requests": 0, "controller_encryption": False})

    for numeric in (False, True):
        yield (f"smp-initiator-security-request-{'numeric' if numeric else 'just-works'}",
               "bumble-smp.py", ["--security-request"] + (["--numeric"] if numeric else []),
               "smp-initiator.toit", ["numeric"] if numeric else [],
               {"toit_role": "initiator", "rejected": False, "key_match": True,
                "security_requests": 1, "encryption_requests": 0,
                "controller_encryption": False, "numeric_comparison": numeric})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit-run", type=Path, required=True)
    parser.add_argument("--snapshot-compiler", type=Path,
                        help="Optional toit.compile executable; precompile fixtures for VM-only sanitizer runs")
    parser.add_argument("--output", type=Path, required=True, help="New directory for logs and results")
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("The suite runner requires POSIX process groups for peer/VM cleanup")
    version = importlib.metadata.version("bumble")
    if version != "0.0.234":
        parser.error("Use the isolated requirements.txt environment (Bumble 0.0.234)")
    root = Path(__file__).resolve().parents[2]
    vm = args.toit_run.resolve()
    if not vm.is_file():
        parser.error("--toit-run must identify a built host VM")
    compiler = args.snapshot_compiler.resolve() if args.snapshot_compiler else None
    if compiler and not compiler.is_file():
        parser.error("--snapshot-compiler must identify a built toit.compile executable")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    results = []
    source_paths = list(Path(__file__).parent.glob("*.py")) + list(Path(__file__).parent.glob("*.toit"))
    source_paths += list((root / "lib/ble/experimental").rglob("*.toit"))
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in source_paths}
    matrix = list(cases())
    snapshots = {}
    if compiler:
        for fixture in sorted({case[3] for case in matrix}):
            snapshot = output / f"{Path(fixture).stem}.snapshot"
            with (output / f"{Path(fixture).stem}.compile.log").open("w") as stream:
                command = [str(compiler), "-w", str(snapshot),
                           str(Path(__file__).with_name(fixture))]
                status = run_peer(command, root, stream)
                if status != 0:
                    raise subprocess.CalledProcessError(status, command)
            snapshots[fixture] = snapshot
    for name, script, options, fixture, arguments, expected in matrix:
        program = ([str(snapshots[fixture])] if compiler else
                   ["--project-root", str(root / "tests"),
                    str(Path(__file__).with_name(fixture))])
        command = [sys.executable, str(Path(__file__).with_name(script)), *options,
                   str(vm), *program, *arguments]
        started = time.monotonic()
        verdict = None
        failure = None
        exit_code = None
        log = output / f"{name}.log"
        try:
            with log.open("w") as stream:
                exit_code = run_peer(command, root, stream)
            lines = log.read_text().splitlines()
            verdict = json.loads(lines[-1]) if lines else None
            if exit_code != 0 or not isinstance(verdict, dict) or verdict.get("result") != "PASS":
                raise ValueError("peer failed or did not emit a terminal PASS verdict")
            for key, value in expected.items():
                if verdict.get(key) != value:
                    raise ValueError(f"incorrect {key}: expected {value!r}")
        except (subprocess.TimeoutExpired, ValueError, OSError) as error:
            failure = str(error)
        results.append({"case": name, "passed": failure is None, "exit_code": exit_code,
                        "failure": failure, "seconds": time.monotonic() - started,
                        "command": command, "verdict": verdict})
        print(f"{name}: {'PASS' if failure is None else 'FAIL'}", flush=True)
        (output / "results.json").write_text(json.dumps({
            "bumble": version, "python": sys.version, "cases": results,
            "vm_sha256": hashlib.sha256(vm.read_bytes()).hexdigest(),
            "compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest() if compiler else None,
            "snapshots_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest()
                                 for name, path in snapshots.items()},
            "sanitizer_options": {name: os.environ.get(name)
                                  for name in ("ASAN_OPTIONS", "LSAN_OPTIONS", "UBSAN_OPTIONS")},
            "sources_sha256": hashes,
            "complete": len(results) == len(matrix),
            "passed": len(results) == len(matrix) and all(r["passed"] for r in results),
        }, indent=2) + "\n")
    return 0 if all(result["passed"] for result in results) else 1


def cli():
    # CI cancellation must unwind run_peer's process-group cleanup. The default
    # SIGTERM action exits immediately, leaving its isolated peer and VM alive.
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)

    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        return main()
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    if not __debug__:
        raise RuntimeError("Run without Python -O: assertions in peer tests are required")
    sys.exit(cli())
