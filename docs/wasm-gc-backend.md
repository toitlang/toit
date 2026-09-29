# WebAssembly GC backend (experimental)

Besides the [Emscripten build of the VM](wasm.md), which interprets
snapshots, the compiler has an experimental backend that compiles Toit
programs directly to WebAssembly. Toit objects are WebAssembly GC objects, so
the JavaScript engine's garbage collector manages them, and Toit code runs as
JIT-compiled WebAssembly.

This is a prototype. Most of the language and core library work (see
[Status](#status)), but several subsystems are missing.

## Usage

The backend is enabled with a deploy flag of the compiler. It writes the
module in the WebAssembly text format, which Binaryen's `wasm-as` assembles:

```sh
toit.compile -Xwasm_output=hello.wat -w hello.snapshot hello.toit
wasm-as --enable-gc --enable-reference-types --enable-exception-handling \
    --enable-multivalue --enable-tail-call --enable-bulk-memory \
    --enable-nontrapping-float-to-int --enable-sign-ext \
    -g -o hello.wasm hello.wat
# Optional: shrinks the module by ~20% and speeds it up.
wasm-opt <same --enable flags> -O2 -o hello.wasm hello.wasm
node tools/wasm/run-gc.mjs hello.wasm arg1 arg2
```

`toit.compile` is the compiler of the host SDK
(`build/host/sdk/lib/toit/bin/toit.compile`). The snapshot is a by-product.
`-g` keeps the function names, which are needed for stack traces.

In browsers, `src/wasm/toit-gc.mjs` runs the module. It has the same API as
the Emscripten VM's `toit.mjs`, except that it takes the compiled module
instead of a snapshot:

```js
import { run } from "./toit-gc.mjs";

const bytes = await (await fetch("hello.wasm")).arrayBuffer();
const exitCode = await run(bytes, {
  args: ["foo"],
  stdout: (line) => console.log(line),
  stderr: (line) => console.error(line),
  // Functions the program can call with 'js.call'.
  functions: { fetchText: async (url) => (await fetch(url)).text() },
});
```

Tests: `make test-wasm-gc` runs the Toit tests with the backend
(`tools/wasm/run-tests.py --backend gc`). Tests that are known to fail are
listed in `tests/wasm-gc-expected-failures.txt`, grouped by reason.

When working on the runtime, set `TOIT_WASM_RUNTIME` to
`src/compiler/wasm_runtime.wat`, so the compiler reads it from there instead of
using the copy that is embedded in `toit.compile`.

## Engine requirements

The generated modules use:

- WebAssembly GC (structs, arrays, `i31ref`, casts).
- Exception handling with `exnref` (`try_table`, `throw_ref`).
- Tail calls, multi-value, bulk memory.
- JavaScript Promise Integration (JSPI: `WebAssembly.Suspending` and
  `WebAssembly.promising`) for tasks.

They have been tested with Node.js 26 (V8 14.6), Chrome 154 and Firefox 156.
Safari hasn't been tested.

## Design

The files:

- `src/compiler/wasm_backend.{h,cc}`: the backend. It translates the IR of the
  final compiler pass (after optimizations, tree shaking and the construction
  of the dispatch table) to WebAssembly text.
- `src/compiler/wasm_runtime.wat`: the hand-written runtime: helpers,
  primitives, and the exports for the JavaScript host. It is embedded in the
  compiler, and prepended to the generated code.
- `src/wasm/toit-gc.mjs`: the JavaScript host.

### Values

Every Toit value is an `eqref`:

- Small integers are `i31ref`s. Integers that don't fit into 31 bits are
  boxed in a `$LargeInt` struct with an `i64`. Arithmetic has inlined fast
  paths for small integers, and falls back to the runtime.
- `null` is the null reference.
- All other objects are structs that are subtypes of `$Object`, whose first
  field is the class id. Every class has its own struct type, mirroring the
  class hierarchy, with one field per Toit field.
- Strings, byte arrays, arrays and floats have special struct types.
  Strings and byte arrays hold their content in an `(array (mut i8))`.
- The literals (strings and byte arrays) are passive data segments.

### Calls

- Methods take and return `eqref`s. Static calls are direct calls, and Toit
  tail calls use `return_call`.
- Virtual calls use Toit's dispatch table as WebAssembly function table: the
  target is at `class-id + selector-offset`. As the table is compressed, the
  selector offset of every slot is stored in an array, and checked before the
  call (the equivalent of the interpreter's lookup check).
- Frequent operators (`==`, `<`, `+`, `[]`, `size`, ...) are inlined with the
  same fast paths as the interpreter's `INVOKE_*` bytecodes, for small
  integers, floats, arrays, lists and byte arrays.

### Blocks, lambdas and control flow

- Blocks are `$Block` structs with a function reference and the environment
  of the function that created them. A function whose locals are used by its
  blocks allocates an environment struct for those locals. Blocks follow the
  `parent` links of environments to reach the locals of outer functions.
- Blocks and lambdas have uniform signatures: they get the number of passed
  arguments, and the arguments padded with nulls to the maximum arity of the
  program. This implements Toit's rule that blocks and lambdas can be called
  with more arguments than they declare.
- Toit exceptions are WebAssembly exceptions with the `$throw` tag.
- Non-local returns from blocks throw `$nlr` with the environment of the
  targeted function, which catches it and returns. `break` and `continue` in
  blocks work the same way with `$nlbr`.
- `try`/`finally` catches all exceptions with `catch_all_ref`, runs the
  handler, and continues unwinding with `throw_ref`.

### Primitives

The runtime implements the primitives (`$prim.<module>.<name>`), with the
same argument checks and errors as the VM. They return a `$Failure` struct if
they fail, which the generated code unpacks and passes to the primitive's
failure block. Primitives that the runtime doesn't have always fail with
`UNIMPLEMENTED` (and the host prints their name once).

A few primitives are implemented by the JavaScript host: TISON and base64
encoding, and the `js` library (see [wasm.md](wasm.md)).

### Tasks

Toit tasks are coroutines. Each task runs in its own call of the exported
`run_task` function, which is wrapped with `WebAssembly.promising`, and so
gets its own stack. Switching tasks (`task_transfer`) and waiting for
messages call imports that are wrapped with `WebAssembly.Suspending`: they
suspend the WebAssembly stack of the current task and resume another one.

The scheduling itself is the Toit code of the core library, as with the VM.
There is no preemption: a task runs until it waits or yields. Timers are
`setTimeout`s, but a task that never yields still sees them expire, because
the host checks the timers when the task checks for messages.

### The system process

A Toit program normally runs next to a system process that provides
services. The host emulates the part of it that programs need: it prints
traces, and it answers service discovery as if there were no services, so
`print` falls back to writing to stdout.

### Stack traces

`encode_error` captures a JavaScript stack trace and associates it with the
returned trace object. It is only formatted when the trace is printed: the
names of the WebAssembly functions (`m<id>.<holder>.<name>`, and
`b<id>.<outer>` for blocks) are turned into Toit names. Capturing is costly
(~0.3µs per frame in V8), so traces are limited to 20 frames.

### Differences from the VM

- Small integers have 31 bits (like the 32-bit VM, but unlike the 62 bits of
  the 64-bit VM). Larger integers are boxed.
- Arrays have no size limit, so large lists don't use the arraylets of
  `LargeArray_`.
- Stack overflows can't be caught: JavaScript engines don't let WebAssembly
  code catch them. The host reports them as an uncaught `STACK_OVERFLOW`.
- Finalizers never run, and there are no weak references.
- No heap statistics or memory limits (the engine's GC manages memory).

## Status

With `make test-wasm-gc`, 290 of the 334 tests that run on the Emscripten VM
pass. The failing ones need:

- Crypto (SHA, AES, RSA, X.509, TLS) and zlib primitives.
- Services that the program provides itself (the emulated system process only
  knows about printing).
- Finalizers and weak references.
- Catching stack overflows.
- Heap statistics, the file system, flash storage, and subprocesses.

## Performance

Rough numbers from a noisy machine (minimum of three runs, `wasm-opt -O2`,
Node.js 26):

| Benchmark                               | Native VM (x64) | Emscripten VM | WasmGC backend |
|-----------------------------------------|----------------:|--------------:|---------------:|
| `fib 30` (calls)                        |           57 ms |        152 ms |          23 ms |
| Integer loop, sum grows beyond 2^30     |          421 ms |       1348 ms |         914 ms |
| 1M small strings added to a list        |          514 ms |        662 ms |         810 ms |
| Map with 300k entries                   |          333 ms |        593 ms |         352 ms |
| 5M float additions                      |          296 ms |        572 ms |         233 ms |
| Join and split 200k strings             |          775 ms |        757 ms |    850-1400 ms |
| 50k exceptions thrown and caught        |          134 ms |        169 ms |     280-510 ms |

- Calls and floats are much faster than with the interpreters.
- Integers that don't fit into 31 bits are allocated. The Emscripten VM
  (a 32-bit VM) has the same problem.
- Exceptions are slower because of the JavaScript stack traces.
- The generated code doesn't use the types that the compiler's type
  propagation computes yet: every value is an `eqref`, and every access
  checks and casts.

A "hello world" module is 132KB (37KB gzipped) after `wasm-opt -O2`, compared
to 900KB (410KB gzipped) for the Emscripten VM plus the snapshot.

## Next steps

- Services: compile the system program as well (or a smaller version of it),
  and run it as a second module or in the same module, so services work.
- Crypto and zlib: compile the C implementations (MbedTLS, the VM's zlib code)
  to a separate WebAssembly module with linear memory and call it from the
  runtime. WebCrypto is asynchronous, which doesn't fit the synchronous
  primitives.
- Finalizers with `FinalizationRegistry`, weak maps with `WeakRef`.
- Stack overflow detection with an explicit call-depth counter.
- Speed: use the propagated types to avoid casts and boxing, implement the
  `hash_find` intrinsic, and inline caches for polymorphic calls.
- Emit the binary format directly, to drop the dependency on Binaryen.
- Use core stack switching instead of JSPI, once engines ship it.
