// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// Runs a Toit program that was compiled to a WebAssembly GC module:
//   node tools/wasm/run-gc.mjs program.wasm [args...]

import { readFileSync } from "node:fs";
import { run } from "../../src/wasm/toit-gc.mjs";

const code = await run(readFileSync(process.argv[2]), {
  args: process.argv.slice(3),
  stdout: (line) => process.stdout.write(line + "\n"),
  stderr: (line) => process.stderr.write(line + "\n"),
});
process.exitCode = code;
