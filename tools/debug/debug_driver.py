#!/usr/bin/env python3
"""Operator debug driver — the local porta stand-in for the Toit host debugger.

Usage:
    debug_driver.py [--script <cmds.txt>] <source.toit>

The driver:
  1. Compiles <source.toit> to a snapshot via ``toit compile -s``.
  2. Builds a name↔entry_bci map from ``toit tool snapshot bytecodes`` (offline,
     no VM change needed — see dbg_protocol.build_name_map).
  3. Launches ``toit.run --debug <snap>`` with stdin wired to a pipe and stdout
     captured (reuses _inner_toit_run + _Reader from dbg_protocol).
  4. Fetches the method registry via ``dbg:methods`` and cross-references
     entry_bci values to resolve numeric ids to names.
  5. Runs a command loop (interactive stdin or --script file):

     methods              — print the method registry with resolved names
     break <name|id> [off]— set a breakpoint (name is resolved to id)
     clear <name|id> [off]— clear a breakpoint
     continue             — resume execution
     inspect [frame]      — read a stack frame
     step                 — step to the next bytecode
     over                 — step over (skip callees)
     out                  — run until the current frame returns

  Pretty-prints ``dbg:paused`` and ``dbg:stack`` with resolved method names.
"""

import argparse, os, re, subprocess, sys, tempfile

# Make ``tools.debug.dbg_protocol`` importable when the driver is invoked
# directly (python3 tools/debug/debug_driver.py …) from any cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
sys.path.insert(0, _ROOT)

from tools.debug.dbg_protocol import (
    parse_line, format_methods, build_name_map,
    _inner_toit_run, _Reader)

TOIT = os.path.join(_ROOT, "build", "host", "sdk", "bin", "toit")


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def _fmt(p: dict, id_to_name: dict) -> str:
    """Return a human-readable string for a parsed VM output line."""
    k = p["kind"]
    if k == "ready":
        return "VM ready"
    if k == "paused":
        name = id_to_name.get(p["id"], f"#{p['id']}")
        return f"paused in {name} at off {p['off']} (mode: {p['mode']})"
    if k == "stack":
        regs = " ".join(f"r{r}={v}" for r, v in sorted(p["regs"].items()))
        return f"stack off={p['off']}{' ' + regs if regs else ''}"
    if k == "ok":
        return f"ok: {p['verb']}"
    if k == "error":
        return f"error: {p['msg']}"
    if k == "app":
        return p["text"]
    return p.get("text", str(p))


# ---------------------------------------------------------------------------
# Name/id resolution
# ---------------------------------------------------------------------------

def _resolve_to_id(token: str, name_to_id: dict) -> int:
    """Resolve a name or numeric id string to an integer method id.

    Accepts a bare integer (passed through) or a method name looked up in
    *name_to_id*.  Raises ``ValueError`` for unknown names.
    """
    if re.match(r'^-?\d+$', token):
        return int(token)
    if token in name_to_id:
        return name_to_id[token]
    raise ValueError(f"unknown method name: {token!r}  (known: {sorted(name_to_id)})")


# ---------------------------------------------------------------------------
# Core driver
# ---------------------------------------------------------------------------

def run_driver(source: str, commands_iter, timeout: float = 30.0):
    """Compile *source*, launch the VM in debug mode, and run *commands_iter*.

    Returns the exit code: 0 on clean completion, 1 on errors.
    """
    # ------------------------------------------------------------------
    # Step 1: compile
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory() as tmpdir:
        snap = os.path.join(tmpdir, "prog.snapshot")
        try:
            subprocess.run(
                [TOIT, "compile", "-s", "-o", snap, source],
                check=True)
        except subprocess.CalledProcessError as e:
            print(f"compile failed: {e}", file=sys.stderr)
            return 1

        # ------------------------------------------------------------------
        # Step 2: build offline name map (Approach 1 — CLI tooling)
        # ------------------------------------------------------------------
        try:
            name_to_entry, entry_to_name = build_name_map(TOIT, snap)
        except subprocess.CalledProcessError as e:
            print(f"bytecodes query failed: {e}", file=sys.stderr)
            return 1

        # ------------------------------------------------------------------
        # Step 3: launch VM in debug mode
        # ------------------------------------------------------------------
        inner = _inner_toit_run(TOIT)
        proc = subprocess.Popen(
            [inner, "--debug", snap],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1)
        reader = _Reader(proc.stdout)

        def send(cmd: str):
            try:
                proc.stdin.write(cmd.rstrip("\n") + "\n")
                proc.stdin.flush()
            except (BrokenPipeError, ValueError):
                pass

        # State: index of the next unprinted line in reader.lines.
        printed = [0]
        id_to_name: dict = {}
        name_to_id: dict = {}

        def flush_output():
            while printed[0] < len(reader.lines):
                line = reader.lines[printed[0]]
                printed[0] += 1
                p = parse_line(line)
                print(_fmt(p, id_to_name))

        exit_code = 0
        try:
            # Wait for dbg:ready.
            reader.wait_for(
                lambda ls: any(parse_line(l)["kind"] == "ready" for l in ls),
                timeout)
            reader.settle(quiet=0.3, maxwait=4.0)
            flush_output()

            # ------------------------------------------------------------------
            # Step 4: fetch method registry and build id↔name maps
            # ------------------------------------------------------------------
            send("dbg:methods")
            reader.wait_for(
                lambda ls: any(
                    parse_line(l) == {"kind": "ok", "verb": "methods"}
                    for l in ls),
                timeout)
            reader.settle(quiet=0.3, maxwait=4.0)

            registry = format_methods("\n".join(reader.lines))
            # Suppress raw registry lines; jump past them.
            printed[0] = len(reader.lines)

            # Cross-reference entry_bci to build id↔name maps.
            for mid, (entry_bci, _arity) in registry.items():
                name = entry_to_name.get(entry_bci)
                if name:
                    id_to_name[mid] = name
                    name_to_id[name] = mid

            # ------------------------------------------------------------------
            # Step 5: command loop
            # ------------------------------------------------------------------
            for raw_line in commands_iter:
                raw_line = raw_line.rstrip("\n")
                cmd_line = raw_line.strip()
                if not cmd_line or cmd_line.startswith("#"):
                    continue

                parts = cmd_line.split()
                verb = parts[0]

                # --- operator commands ---
                if verb == "methods":
                    # Print the registry with resolved names.
                    print(f"Methods ({len(registry)} registered):")
                    for mid, (entry_bci, arity) in sorted(registry.items()):
                        name = id_to_name.get(mid, f"#{mid}")
                        print(f"  {mid:4d}  entry_bci={entry_bci}  arity={arity}  {name}")
                    continue

                if verb in ("break", "clear"):
                    if len(parts) < 2:
                        print(f"usage: {verb} <name|id> [off]")
                        continue
                    try:
                        mid = _resolve_to_id(parts[1], name_to_id)
                    except ValueError as exc:
                        print(f"error: {exc}")
                        continue
                    off = int(parts[2]) if len(parts) > 2 else 0
                    send(f"dbg:{verb} {mid} {off}")

                elif verb == "continue":
                    send("dbg:continue")

                elif verb == "inspect":
                    if len(parts) > 1:
                        send(f"dbg:inspect {parts[1]}")
                    else:
                        send("dbg:inspect")

                elif verb in ("step", "over", "out"):
                    send(f"dbg:{verb}")

                else:
                    print(f"unknown command: {verb!r}")
                    continue

                reader.settle(quiet=0.4, maxwait=6.0)
                flush_output()

            # Give the VM time to run to completion after the last command.
            reader.wait_for(lambda ls: reader.eof, timeout=timeout)
            reader.settle(quiet=0.3, maxwait=4.0)
            flush_output()

        except Exception as exc:
            print(f"driver error: {exc}", file=sys.stderr)
            exit_code = 1

        finally:
            try:
                proc.stdin.close()
            except Exception:
                pass
            try:
                proc.wait(timeout=10.0)
            except Exception:
                proc.kill()

    return exit_code


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Toit host debug driver (porta stand-in)")
    parser.add_argument("source", help="Toit source file to compile and debug")
    parser.add_argument(
        "--script", metavar="FILE",
        help="Read commands from FILE instead of interactive stdin")
    args = parser.parse_args()

    if args.script:
        with open(args.script) as fh:
            rc = run_driver(args.source, fh)
    else:
        # Interactive: read from stdin with a prompt.
        try:
            import readline  # noqa: F401 — enables line editing on POSIX
        except ImportError:
            pass  # readline is unavailable on some platforms; not required.
        def _prompt_iter():
            while True:
                try:
                    line = input("dbg> ")
                except EOFError:
                    break
                yield line
        rc = run_driver(args.source, _prompt_iter())

    sys.exit(rc)


if __name__ == "__main__":
    main()
