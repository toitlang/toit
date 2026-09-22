# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Exercise optional suite process cleanup without Bumble, Toit or hardware."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import unittest


@unittest.skipUnless(os.name == "posix", "Runner uses POSIX process groups")
class CleanupTest(unittest.TestCase):
    def check_cleanup(self, mode):
        # Both the peer and its simulated VM inherit stdout. EOF proves that
        # cleanup reaches the descendant too, without relying on zombie PIDs.
        peer = "\n".join([
            "import json, os, subprocess, sys, time",
            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])",
            "print(json.dumps({'peer': os.getpid(), 'child': child.pid}), flush=True)",
            "time.sleep(60)" if mode != "exit" else "sys.exit(0)",
        ])
        harness = "\n".join([
            "import subprocess, sys",
            f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})",
            "import run",
            "def fixture():",
            "    try:",
            f"        return run.run_peer([sys.executable, '-c', {peer!r}], '.', sys.stdout,",
            f"                            timeout={1 if mode == 'timeout' else 30})",
            "    except subprocess.TimeoutExpired:",
            "        return 124",
            "run.main = fixture",
            "sys.exit(run.cli())",
        ])
        process = subprocess.Popen([sys.executable, "-c", harness],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        group = None
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(process.stdout, selectors.EVENT_READ)
                self.assertTrue(ready.select(timeout=5), "peer did not start")
            record = json.loads(process.stdout.readline())
            group = record["peer"]
            if mode == "term":
                process.terminate()
            elif mode == "interrupt":
                process.send_signal(signal.SIGINT)
            # communicate waits for pipe EOF as well as the runner's exit.
            # A surviving peer or VM keeps this blocked until the deadline.
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(stdout, "")
            if mode == "interrupt":
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("KeyboardInterrupt", stderr)
            else:
                expected = {"exit": 0, "timeout": 124, "term": 143}[mode]
                self.assertEqual(process.returncode, expected, stderr)
        finally:
            if group is not None:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_peer_exit_cleans_up_remaining_vm(self):
        self.check_cleanup("exit")

    def test_timeout_cleans_up_peer_and_vm(self):
        self.check_cleanup("timeout")

    def test_sigterm_cleans_up_peer_and_vm(self):
        self.check_cleanup("term")

    def test_sigint_cleans_up_peer_and_vm(self):
        self.check_cleanup("interrupt")


if __name__ == "__main__":
    unittest.main()
