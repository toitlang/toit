# WebAssembly

The Toit VM can be compiled to WebAssembly with [Emscripten](https://emscripten.org).
It runs Toit programs (snapshots) in browsers and in Node.js.

There is also an experimental compiler backend that compiles Toit programs
directly to WebAssembly with garbage collection. See
[wasm-gc-backend.md](wasm-gc-backend.md).

Snapshots are compiled on the host with the regular SDK. Snapshots are platform
independent, so no special compiler is needed:

```sh
toit compile --snapshot -o hello.snapshot hello.toit
```

## Building

Requirements: Emscripten (4.x or newer), and the host SDK, which compiles the
system program that is embedded in the VM.

```sh
make wasm
```

This builds (in `build/wasm/sdk`):

- `bin/toit.run.js` and `bin/toit.run.wasm`: a command line runner for Node.js.
  It has access to the real file system:
  ```sh
  node build/wasm/sdk/bin/toit.run.js hello.snapshot arg1 arg2
  ```
- `wasm/toit-vm.mjs` and `wasm/toit-vm.wasm`: the VM as an ES module, for
  browsers and other JavaScript embedders.
- `wasm/toit.mjs`: the JavaScript API (see below).

Other targets:

- `make test-wasm`: runs the Toit tests on the Node.js runner. Tests that need
  unsupported features are listed in `tests/wasm-skip.txt`.
  `tools/wasm/run-tests.py` can also run individual tests.
- `make wasm-demo`: builds the browser demo in `examples/wasm` into
  `build/wasm/demo`. Serve it with any static web server, for example
  `python3 -m http.server -d build/wasm/demo`.
- `make test-wasm-browser`: runs the demo programs in headless Firefox.

For a debug build of the VM (with assertions), configure a separate build
directory with `-DCMAKE_BUILD_TYPE=Debug`.

## JavaScript API

```js
import { run } from "./toit.mjs";

const snapshot = new Uint8Array(await (await fetch("hello.snapshot")).arrayBuffer());
const exitCode = await run(snapshot, {
  args: ["foo"],
  stdout: (line) => console.log(line),
  stderr: (line) => console.error(line),
  // Functions the program can call with 'js.call'.
  functions: {
    fetchText: async (url) => (await fetch(url)).text(),
  },
});
```

Every call to `run` instantiates a fresh VM. The returned promise resolves
with the exit code when the program terminates.

## Calling JavaScript from Toit

The `js` library (`lib/js.toit`) is available on the Wasm platform:

```toit
import js

main:
  print (js.eval "navigator.userAgent")
  // Blocks only the calling task until the promise settles.
  text := js.call "fetchText" ["https://example.com"]
  print (js.call "Math.max" [1, 5, 3])
```

Values are converted with JSON in both directions.

## Design

The browser's main thread must never block, and threads (SharedArrayBuffer)
are only available on cross-origin isolated pages. The WebAssembly VM
therefore runs on a single thread and is driven by the JavaScript event loop.

- `TOIT_WASM` is the platform (`src/top.h`). It also defines `TOIT_POSIX`,
  since Emscripten emulates enough of POSIX (files, time, environment), and
  the feature macro `TOIT_NO_THREADS`.
- With `TOIT_NO_THREADS`, mutexes are plain flags that detect dead-locks
  (`src/mutex.h`), and threads can't be spawned (`src/os_no_threads.cc`).
- The scheduler doesn't block waiting for processes. The embedder starts the
  boot program with `Scheduler::start_boot_program` and then repeatedly calls
  `Scheduler::run_next`, which runs one ready process until it yields,
  terminates or passes a deadline.
- Without a ticker thread, the interpreter preempts itself: at calls and
  backwards branches it counts down, and regularly compares the clock with
  its preemption deadline (`PREEMPTION_TICK` in `src/interpreter_run.cc`).
- Event sources don't have threads. The event loop polls them
  (`EventSource::poll`), which dispatches ready events and returns when the
  source wants to be polled again (for example for the next timer). Work that
  would run on an `AsyncEventThread` (like RSA key generation) runs when
  polled.
- `src/toit_wasm.cc` runs the VM in steps that are scheduled with
  `emscripten_set_immediate` and `emscripten_set_timeout`. A step polls the
  event sources and runs ready processes for at most 20ms, so the page stays
  responsive. Events that come from JavaScript (like settled promises of
  `js.call`) schedule a step themselves.
- The GC allocates its pages with `aligned_alloc` from the linear memory. The
  GC metadata covers the whole (maximum) linear memory, and is taken directly
  from `sbrk`, so the unused parts are never touched.
- The VM embeds the same system program as the host's `toit.run`
  (`system/extensions/host/toit.run.toit`).

## Limitations

- No network (TCP, UDP, TLS), subprocesses, or serial ports.
- Standard input isn't supported yet.
- Time zones: Emscripten's `localtime` and `mktime` always use the time zone
  of the JavaScript engine, and ignore `TZ`.
- The emulated flash (used for storage and container images) is 4MB.
- Compute-heavy code runs roughly 2-4 times slower than the native VM.
