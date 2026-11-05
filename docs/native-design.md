# Native code

Toit programs can be compiled to C++ and then to machine code, instead of
running as bytecodes. This document describes how that works and where the
pieces are. It is for people who work on the compiler or the runtime.

## Using it

```
toit compile --native -o hello hello.toit
```

This compiles the program and the system program to C++, compiles that with
`clang++`, and links it with the runtime from the SDK. The result is a normal
executable. `--native-source` writes the generated C++ instead.

The C++ compiler has to guarantee tail calls, which Clang does. `TOIT_CXX`
selects a different one. Native code is supported for 64-bit release builds
on the host, except on Windows.

## One engine per executable

An executable runs either bytecodes or native code, never both. The two
engines implement the same small interface, declared at the end of the
`Interpreter` class in `src/interpreter.h`:

- `run`: runs the current process until it yields, stops or is preempted.
- `start_address`: the return address that processes and tasks start from.
- `return_bci`: the bci that stack traces show for a return address.
- `spawn_image`: the image of a program that is spawned from a snapshot.

The bytecode engine is `src/interpreter_run.cc`, and the native engine is
`src/interpreter_native.cc`. The linker picks one: interpreter executables
link `toit_interpreter`, and native executables link `toit_native_main`,
which also has the native runtime (`src/native.cc`) and `main`
(`src/native_main.cc`). Everything else is shared. The bytecode version of
`return_bci` is a weak default in `src/objects.cc`, because the compiler also
walks stacks.

## The ABI

`src/native_abi.h` is the interface between generated code and the runtime.
It is copied into every generated file, so it can't include anything from
the VM, and its hash is the version that generated code is checked against.
`src/native.cc` has static asserts for the layouts that are duplicated in it.

Generated code uses the interpreter's stack and frame layout. Every basic
block is a C++ function, and calls, returns and jumps between blocks are tail
calls, so the C stack stays flat and all Toit frames are on the Toit stack.
That means that garbage collection, stack growth, tasks and unwinding work
the way they do for bytecodes. All functions have the same parameters:

- `sp`: the Toit stack, which is in memory except for its top.
- `c`: the `NativeContext` with what the code needs from the process.
- `x` and `y`: scratch values whose meaning depends on the callee.
- `t`: the top of the stack.

The top of the stack is spilled before calling the runtime, which always sees
the whole stack in memory. Return addresses are the addresses of functions,
which are aligned, so the garbage collector sees them as smis. Native frames
have a constant frame marker, `Stack::native_frame_marker()`.

The slow paths are in `NativeRuntime`. The functions that take the usual
parameters are entered with tail calls and continue with a tail call to `x`.
The rest are plain calls that don't run Toit code.

## The program

A native program still has a program heap: classes, literals, globals and the
program's roots. It is stored as a relocatable image in the executable, and
`NativeRuntime::load_image` relocates it when a process group starts.

The bytecodes are gone. Each method is replaced by a record of the same size:
the method header followed by the original id of the method, which is what
stack traces use to find names and positions in the source map. The targets
of non-local branches have records too. Method ids, like the ones in lambdas
and in the entry points, are the offsets of the records, so the index of the
record finds the code for a method (`native_record_index` in `src/native.h`).
The code for each record is in the `code` table of the `NativeProgram`, as
an offset relative to the table entry, so that the table needs no relocations.

A `NativeProgram` is matched with its `Program` by the uuid of the snapshot it
was compiled from and the length of its records.

## Calls

The compiler uses the propagated types to call methods directly where it can,
and to inline accessors and other small methods.

Virtual calls go through one dispatch table that is part of the generated
code. Its rows overlap, like the interpreter's, so a call site jumps to
`vtable[class_id + selector_offset]` and passes a key for the selector and
arity in `y`. The method's virtual entry checks the key, so the call site
doesn't need to. When the check fails, `NativeRuntime::virtual_fallback`
looks the selector up again, and calls the program's `lookup_failure` if the
receiver doesn't have the method. The program's own dispatch table only has
the entry points.

Primitives are called directly, so the primitive tables are not needed, and
only the primitives that a program uses are linked in. The ones that the
platform doesn't have are stubs that fail (`src/native_module_stubs.cc`).

## Stack traces

The `returns` table of the `NativeProgram` maps the return addresses of calls
to the bcis of the original call sites, delta encoded. It's only used for
stack traces, so it is optimized for size.

## Firmware

Containers can be installed in firmware envelopes from source, and the
envelope keeps their sources, unless they are installed with `--strip`. When
the firmware is extracted with `--combine`, these containers are compiled
together with the system program, so they share the code of the libraries.
Without `--combine`, the containers run their snapshots, like any other:

```
toit tool firmware -e firmware.envelope container install hello hello.toit
toit tool firmware -e firmware.envelope extract --format=image -o snapshots.img
toit tool firmware -e firmware.envelope extract --combine --format=image -o combined.img
```

A combined container has the id it would have if it ran from its snapshot:
the image id, which is computed from the uuid of the snapshot and the
assets (`image-id` in `tools/image.toit`). The firmware tool compiles the
sources with `toit compile --snapshot -O2`, so the ids are the same as the
ids of images of the same program that are compiled the same way and
installed in other ways, like with `jag container install -O2`. The ids are
in the `combined` system asset, so the system program doesn't compute any.

Containers in the firmware, bundled or combined, can still be uninstalled.
That writes a mark, an allocation in the flash registry of the type
`FLASH_ALLOCATION_TYPE_UNINSTALLED` with the id of the image. Marks are
written and freed like programs, and like programs, they are stamped with the
uuid of the firmware, so they are valid exactly as long as installed programs
are. If the firmware changes, but keeps its uuid, an image that is in both
firmwares stays uninstalled, and the marks of images that aren't in the new
firmware are freed at boot. Installing an image with the id of an image in
the firmware frees the mark and erases the new image again, so the
firmware's image, with its flags, is installed again.

## Where to look

| File | What it has |
|---|---|
| `src/compiler/native_generator.cc` | Turns a program into C++. |
| `src/compiler/native_code_writer.h` | Writes the C++ in a readable layout. |
| `src/compiler/native_build.cc` | Builds executables with the SDK's compiler. |
| `src/native_abi.h` | The interface between generated code and the runtime. |
| `src/native.cc` | The runtime for native code. |
| `src/interpreter_native.cc` | The native engine. |
| `src/native_main.cc` | `main` for native executables. |
| `src/native-sdk.cmake` | What the SDK ships for building native code. |
| `tests/native/` | Tests that are compiled to native code. |
