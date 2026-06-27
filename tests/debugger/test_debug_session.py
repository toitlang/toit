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
