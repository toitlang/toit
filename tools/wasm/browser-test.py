#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

"""Runs the WebAssembly demo programs in a headless browser.

Serves the demo (see build-demo.sh), opens it in headless Firefox with
'?autorun=...', and waits for the page to post the results of the programs.
"""

import argparse
import functools
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Program name -> (expected exit code, lines that must be in the output).
EXPECTATIONS = {
  "hello": (0, ["Hello from Toit!", "Running on Wasm (wasm32).", "Arguments: [from, the, browser]"]),
  "tasks": (0, ["producer 2: message 4", "All messages received."]),
  "dom": (0, ["Rendered 30 frames."]),
  "fetch": (0, ["Languages: Toit, C++, JavaScript"]),
  "fib": (0, ["fib(30) = 832040"]),
  "throw": (1, ["negative: -4"]),
}


class Handler(http.server.SimpleHTTPRequestHandler):
  def __init__(self, *args, on_report=None, **kwargs):
    self.on_report = on_report
    super().__init__(*args, **kwargs)

  def do_POST(self):
    length = int(self.headers.get("Content-Length", 0))
    body = self.rfile.read(length)
    self.send_response(204)
    self.end_headers()
    if self.path == "/__report": self.on_report(json.loads(body))

  def log_message(self, format, *args):
    pass


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--demo", default=os.path.join(ROOT, "build/wasm/demo"))
  parser.add_argument("--firefox", default="firefox")
  parser.add_argument("--timeout", type=int, default=120)
  parser.add_argument("programs", nargs="*", default=list(EXPECTATIONS.keys()))
  args = parser.parse_args()

  report = {}
  done = threading.Event()
  def on_report(results):
    report.update(results)
    done.set()

  handler = functools.partial(Handler, directory=args.demo, on_report=on_report)
  server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
  threading.Thread(target=server.serve_forever, daemon=True).start()
  url = "http://127.0.0.1:%d/?autorun=%s" % (server.server_port, ",".join(args.programs))

  with tempfile.TemporaryDirectory() as profile:
    with open(os.path.join(profile, "user.js"), "w") as f:
      f.write('user_pref("browser.shell.checkDefaultBrowser", false);\n')
      f.write('user_pref("datareporting.policy.dataSubmissionEnabled", false);\n')
      f.write('user_pref("browser.aboutwelcome.enabled", false);\n')
    browser = subprocess.Popen(
        [args.firefox, "--headless", "--no-remote", "--profile", profile, url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
      finished = done.wait(args.timeout)
    finally:
      browser.terminate()
      browser.wait()
      server.shutdown()

  if not finished:
    print("Timed out waiting for the browser.")
    return 1

  failures = 0
  for name in args.programs:
    result = report.get(name, {"error": "missing"})
    expected_code, expected_lines = EXPECTATIONS[name]
    problems = []
    if "error" in result:
      problems.append(result["error"])
    else:
      if result["code"] != expected_code:
        problems.append("exit code %d, expected %d" % (result["code"], expected_code))
      output = "\n".join(result["lines"])
      problems += ["missing '%s'" % line for line in expected_lines if line not in output]
    print("%-5s %s%s" % ("FAIL" if problems else "PASS", name, ": " + "; ".join(problems) if problems else ""))
    if problems:
      failures += 1
      for line in result.get("lines", []): print("      | " + line)
  return 1 if failures else 0


if __name__ == "__main__":
  sys.exit(main())
