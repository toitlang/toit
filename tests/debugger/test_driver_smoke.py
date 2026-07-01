"""Smoke test for tools/debug/debug_driver.py.

Runs the driver in scripted mode against tests/debugger/targets/count_to.toit
through the full flow: methods → break count-to → continue → inspect → step
sequences.  Asserts exit 0 and that the transcript contains the method name
``count-to`` in a paused-pause line (i.e. name resolution actually worked).
"""

import os, subprocess, sys, textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TARGET = os.path.join(HERE, "targets", "count_to.toit")
DRIVER = os.path.join(ROOT, "tools", "debug", "debug_driver.py")


def test_driver_smoke_named_pause(tmp_path):
    """Driver reports a named pause (count-to) and exits 0."""
    script = tmp_path / "cmds.txt"
    script.write_text(textwrap.dedent("""\
        methods
        break count-to 10
        continue
        inspect
        continue
        continue
        continue
        continue
        continue
    """))
    result = subprocess.run(
        [sys.executable, DRIVER, "--script", str(script), TARGET],
        capture_output=True,
        text=True,
        timeout=60,
        cwd=ROOT,
    )
    transcript = result.stdout + result.stderr
    assert result.returncode == 0, (
        f"driver exited {result.returncode}\n--- stdout ---\n{result.stdout}\n"
        f"--- stderr ---\n{result.stderr}")
    # Name resolution must have produced a human-readable *pause* line — not
    # merely list count-to in the methods registry. Asserting on the actual
    # "paused in count-to" line means the test fails if the paused-line name
    # resolution regresses (the registry listing alone would not catch that).
    assert "paused in count-to" in transcript, (
        f"expected 'paused in count-to' in transcript, got:\n{transcript}")
