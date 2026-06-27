import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, ROOT)
TOIT = os.path.join(ROOT, "build/host/sdk/bin/toit")
TARGET = os.path.join(HERE, "targets/count_to.toit")


def _snapshot(tmp):
    snap = os.path.join(tmp, "count_to.snapshot")
    subprocess.run([TOIT, "compile", "-s", "-o", snap, TARGET], check=True)
    return snap


# Pinned, snapshot-specific constants for breaking inside `count-to`.
#
# Discovered once against the count_to.snapshot this test compiles, using
#   `toit tool snapshot bytecodes count_to.snapshot`
# and a `dbg:methods` dump (see .superpowers/sdd/task-4-report.md):
#   - `count-to` (arity 1) compiles to a method whose program-relative entry bci
#     is 285; `main` (arity 0) is at 263.
#   - the `for` loop body `sum += i` begins at offset 10 from the entry
#     (entry+10 = bci 295, the first `load local` of the body), so a breakpoint
#     there fires once per iteration with the loop variable `i` taking the
#     values 0,1,2,3,4.
# We look the id up by entry bci (not a hard-coded id) so the test still finds
# count-to if the dispatch-table numbering shifts, as long as the bytecode
# layout is stable.
COUNT_TO_ENTRY_BCI = 285
COUNT_TO_SUM_OFF = 10
# `main` (arity 0) compiles to entry bci 263; it is the frame that calls
# `count-to`, so a `dbg:out` from inside `count-to` lands back here.
MAIN_ENTRY_BCI = 263

# Pinned step/over/out landing sites, discovered empirically (like the ns-oevm
# `assert_over`/`assert_out` harness) by scripting a session and reading the
# actual `dbg:paused step <id> <off>` lines the VM emits. The session breaks at
# the `sum += i` site (off 10), clears the breakpoint, then issues one
# step/over/out and observes where it re-parks:
#   - step: the very next bytecode in `count-to`            -> off 11 (same method)
#   - over: the `sum += i` site makes no Toit call, so over
#           behaves like step here: the next bytecode        -> off 11 (same method)
#   - out:  runs the rest of `count-to` and returns to the
#           caller `main`                                    -> main, off 5
# Re-pin these if the count_to.snapshot bytecode layout changes.
STEP_LANDING_OFF = 11
OVER_LANDING_OFF = 11
OUT_LANDING_OFF = 5


def _count_to_id(methods):
    for mid, (entry_bci, arity) in methods.items():
        if entry_bci == COUNT_TO_ENTRY_BCI and arity == 1:
            return mid
    raise AssertionError(f"count-to (entry_bci={COUNT_TO_ENTRY_BCI}) not in registry: {methods}")


def _main_id(methods):
    for mid, (entry_bci, arity) in methods.items():
        if entry_bci == MAIN_ENTRY_BCI and arity == 0:
            return mid
    raise AssertionError(f"main (entry_bci={MAIN_ENTRY_BCI}) not in registry: {methods}")


def test_inspect_reads_live_locals(tmp_path):
    snap = _snapshot(str(tmp_path))
    from tools.debug.dbg_protocol import run_session
    # Break at the `sum += i` site, then walk the loop: the first `continue`
    # leaves the stop-at-entry pause; each following `inspect`/`continue` pair
    # reads one iteration's frame and steps to the next. Five iterations cover
    # i = 0,1,2,3,4; the final `continue` lets the program run to completion.
    out = run_session(
        TOIT, snap,
        script_after_methods=lambda mid: (
            [f"dbg:break {mid} {COUNT_TO_SUM_OFF}", "dbg:continue"]
            + ["dbg:inspect", "dbg:continue"] * 5),
        method_picker=_count_to_id)
    stacks = [p for p in out if p["kind"] == "stack"]
    assert len(stacks) == 5, out
    # i = 0,1,2,3,4 (and sum = 0,0,1,3,6) are live frame locals we read back, so
    # the extremes must show up as some register value across the iterations.
    assert any("0" in s["regs"].values() for s in stacks), stacks
    assert any("4" in s["regs"].values() for s in stacks), stacks
    # Clean resume: the app still prints its result after the final continue.
    assert any(p.get("text") == "result=10" for p in out), out


def test_breakpoint_parks_then_resumes(tmp_path):
    snap = _snapshot(str(tmp_path))
    # Drive with the debug session: set a breakpoint that exists, continue once
    # per loop iteration, then let it finish. Asserts the app still prints 10
    # (clean resume) AND that we paused at least once.
    from tools.debug.dbg_protocol import run_session
    out = run_session(
        TOIT, snap,
        script_after_methods=lambda mid: [f"dbg:break {mid} 0"] + ["dbg:continue"] * 6)
    assert any(p["kind"] == "ready" for p in out), out
    assert any(p["kind"] == "paused" for p in out), out
    assert any(p.get("text") == "result=10" for p in out), out


def test_methods_registry_and_break_by_id(tmp_path):
    snap = _snapshot(str(tmp_path))
    from tools.debug.dbg_protocol import run_session
    out = run_session(TOIT, snap, script_after_methods=lambda mid: [f"dbg:break {mid} 0", "dbg:continue", "dbg:continue"])
    # registry must include the count-to method with a numeric id
    assert any(p["kind"] == "ok" and p["verb"] == "methods" for p in out)
    assert any(p["kind"] == "ok" and p["verb"] == "break" for p in out)
    assert any(p["kind"] == "paused" and p["mode"] == "break" for p in out)


def test_break_unknown_id_errors_and_clear_is_acknowledged(tmp_path):
    snap = _snapshot(str(tmp_path))
    from tools.debug.dbg_protocol import run_session
    out = run_session(
        TOIT, snap,
        script_after_methods=lambda mid: [
            "dbg:break 99999 0",      # id not in the registry
            f"dbg:break {mid} 0",     # valid id
            f"dbg:clear {mid} 0",     # remove it again
            "dbg:continue", "dbg:continue"])
    # Unknown method id is rejected, not silently dropped.
    assert any(p["kind"] == "error" and p["msg"] == "no-method" for p in out), out
    # break/clear of a real id are both acknowledged.
    assert any(p["kind"] == "ok" and p["verb"] == "break" for p in out), out
    assert any(p["kind"] == "ok" and p["verb"] == "clear" for p in out), out
    # Cleared breakpoint means the app still runs to completion.
    assert any(p.get("text") == "result=10" for p in out), out


def _run_step_session(tmp_path, verb):
    """Break inside `count-to`, clear the breakpoint, then issue one step verb.

    Returns ``(out, count_to_id, main_id)``. The breakpoint is cleared before
    the step so the only remaining pause is the step landing (the loop would
    otherwise re-hit the breakpoint before an `out`/`over` completes).
    """
    snap = _snapshot(str(tmp_path))
    from tools.debug.dbg_protocol import run_session
    ids = {}

    def picker(methods):
        ids["count_to"] = _count_to_id(methods)
        ids["main"] = _main_id(methods)
        return ids["count_to"]

    out = run_session(
        TOIT, snap,
        script_after_methods=lambda mid: [
            f"dbg:break {mid} {COUNT_TO_SUM_OFF}", "dbg:continue",
            f"dbg:clear {mid} {COUNT_TO_SUM_OFF}", f"dbg:{verb}", "dbg:continue"],
        method_picker=picker)
    return out, ids["count_to"], ids["main"]


def test_step_advances_within_same_method(tmp_path):
    out, count_to_id, _ = _run_step_session(tmp_path, "step")
    assert any(p["kind"] == "ok" and p["verb"] == "step" for p in out), out
    steps = [p for p in out if p["kind"] == "paused" and p["mode"] == "step"]
    # A single step pauses exactly once, on the next bytecode of `count-to`
    # (same method id, off advanced past the breakpoint's off 10).
    assert len(steps) == 1, out
    assert steps[0]["id"] == count_to_id, out
    assert steps[0]["off"] == STEP_LANDING_OFF, out
    assert steps[0]["off"] > COUNT_TO_SUM_OFF, out
    # Clean resume to completion.
    assert any(p.get("text") == "result=10" for p in out), out


def test_over_stays_within_method(tmp_path):
    out, count_to_id, _ = _run_step_session(tmp_path, "over")
    assert any(p["kind"] == "ok" and p["verb"] == "over" for p in out), out
    steps = [p for p in out if p["kind"] == "paused" and p["mode"] == "step"]
    assert len(steps) == 1, out
    # `over` does not descend into callees: it stays inside `count-to`.
    assert steps[0]["id"] == count_to_id, out
    assert steps[0]["off"] == OVER_LANDING_OFF, out
    assert any(p.get("text") == "result=10" for p in out), out


def test_out_returns_to_caller(tmp_path):
    out, count_to_id, main_id = _run_step_session(tmp_path, "out")
    assert any(p["kind"] == "ok" and p["verb"] == "out" for p in out), out
    steps = [p for p in out if p["kind"] == "paused" and p["mode"] == "step"]
    assert len(steps) == 1, out
    # `out` runs until `count-to` returns: the landing is in the caller `main`,
    # a shallower frame, NOT inside count-to.
    assert steps[0]["id"] == main_id, out
    assert steps[0]["id"] != count_to_id, out
    assert steps[0]["off"] == OUT_LANDING_OFF, out
    assert any(p.get("text") == "result=10" for p in out), out
