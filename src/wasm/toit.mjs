// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
 * JavaScript API for the WebAssembly build of the Toit VM.
 *
 * Works in browsers, web workers, and Node.js:
 *
 *   import { run } from "./toit.mjs";
 *   const snapshot = await (await fetch("hello.snapshot")).arrayBuffer();
 *   const exitCode = await run(new Uint8Array(snapshot), {
 *     args: ["foo"],
 *     stdout: (line) => console.log(line),
 *   });
 *
 * Snapshots are created on the host with 'toit compile --snapshot'.
 */

import createToitVM from "./toit-vm.mjs";

const SNAPSHOT_PATH = "/program.snapshot";

/**
 * Runs a Toit program.
 *
 * Every call instantiates a fresh VM, so programs don't share any state.
 *
 * @param {Uint8Array|ArrayBuffer} snapshot The program, as a snapshot bundle.
 * @param {object} [options]
 * @param {string[]} [options.args] The arguments passed to the program's main.
 * @param {(line: string) => void} [options.stdout] Called for each line the
 *     program writes to stdout. Defaults to console.log.
 * @param {(line: string) => void} [options.stderr] Called for each line the
 *     program writes to stderr. Defaults to console.error.
 * @param {Object<string, Function>} [options.functions] JavaScript functions
 *     the program can call with 'js.call'. Arguments and results are
 *     converted with JSON. Functions may return promises. Global functions
 *     are available too, unless they are shadowed by these.
 * @param {object} [options.module] Additional Emscripten module settings,
 *     like 'locateFile' to find the .wasm file in a different location.
 * @returns {Promise<number>} The exit code of the program.
 */
export async function run(snapshot, options = {}) {
  const bytes = snapshot instanceof Uint8Array ? snapshot : new Uint8Array(snapshot);
  let resolveExit;
  let rejectExit;
  const exited = new Promise((resolve, reject) => {
    resolveExit = resolve;
    rejectExit = reject;
  });
  const module = await createToitVM({
    ...options.module,
    print: options.stdout ?? ((line) => console.log(line)),
    printErr: options.stderr ?? ((line) => console.error(line)),
    toitFunctions: options.functions ?? {},
    onExit: (code) => resolveExit(code),
    onAbort: (reason) => rejectExit(new Error(`Toit VM aborted: ${reason}`)),
  });
  module.FS.writeFile(SNAPSHOT_PATH, bytes);
  // On Node.js, Emscripten sets the exit code of the embedding process when
  // the program exits. Restore it, since the program is just a library call.
  const nodeProcess = globalThis.process;
  const savedExitCode = nodeProcess?.exitCode;
  try {
    // Main boots the VM and returns. The program then runs in steps that are
    // scheduled on the JavaScript event loop, until it exits.
    module.callMain([SNAPSHOT_PATH, ...(options.args ?? [])]);
    return await exited;
  } finally {
    if (nodeProcess) nodeProcess.exitCode = savedExitCode;
  }
}
