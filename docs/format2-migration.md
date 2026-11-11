# Format 2 as the default (migration step 3)

Branch `plan/format2-default` (from `sandbox-integration`). The plan agreed
with the project owner: one interpreter (the Rust core, verified/core) and
one bytecode format (format 2). This step makes format 2 the default for
every program on host builds; the next step deletes the C++ interpreter and
format 1. Artifacts and scripts:
/home/flo/work/opentoit-sandbox-artifacts/format2-default.

## The default and how to switch back

| What | Default now | Format 1 |
|---|---|---|
| Compiler (toit.compile, toit.run, `toit compile/run`) | format 2 when the build has the verified core | `-Xbytecode_format=1`, or `TOIT_BYTECODE_FORMAT=1` in the environment |
| Embedded programs (toit CLI, toit.run boot snapshot with the system process, run image) | the build's format | CMake `-DTOIT_BYTECODE_FORMAT=1` |
| The whole build (compiler default and embedded programs) | `TOIT_BYTECODE_FORMAT=2` if `TOIT_VERIFIED_CORE` is on, else 1 | `cmake -DTOIT_BYTECODE_FORMAT=1` |

Precedence in the compiler (src/compiler/program_builder.cc,
`requested_bytecode_format`): an explicit `-Xbytecode_format=N`, then
`TOIT_BYTECODE_FORMAT` from the environment, then the build's default
(`TOIT_DEFAULT_BYTECODE_FORMAT`, from the CMake cache variable
`TOIT_BYTECODE_FORMAT`). The old CMake option `TOIT_SYSTEM_FORMAT2` is gone:
a build configured with `-DTOIT_BYTECODE_FORMAT=1` is the old default
build, one with `-DTOIT_BYTECODE_FORMAT=2` is the old `build/host-f2`.
Running the suite "everything in format 1" is a build with
`-DTOIT_BYTECODE_FORMAT=1` (no environment needed); for one program,
`-Xbytecode_format=1` or `TOIT_BYTECODE_FORMAT=1`.

The VM runs both formats as before: format 1 on the C++ interpreter,
format 2 on the core (`Program::is_format2`, the `TBC2` tag), so programs
of both formats can be compared on one VM.

## Trusted and untrusted compilation

There are two kinds of format-2 code:

- **Trusted (first-party), the default.** The compiler emits the
  trusted-only unchecked twins of the field accesses (format note 20) and
  the built-ins of note 19. No certificate. The program runs on the
  verified loop without verification (the trusted token). It cannot run as
  an untrusted container: the launch and install verifier reject the twins
  ("unchecked opcode ... in a program not in the unchecked mode").
- **Untrusted.** Only checked opcodes (the built-ins are verified and
  stay), and `toit.compile -w` ships the certificate
  (verified/spec/format/18-shipped-certificate.md) that the device checks
  at install.

The user-facing switch is `--untrusted`:

    toit compile --untrusted --snapshot -o prog.snapshot prog.toit   # toit.compile --untrusted -w ...
    toit run --untrusted prog.toit                                    # compiles untrusted, runs sandboxed
    toit.run --untrusted -w prog.snapshot prog.toit                   # writes the snapshot (no certificate)

`--untrusted` implies format 2 (`toit.compile --untrusted
-Xbytecode_format=1` is an error). `-Xuntrusted` is the same flag.
Low-level overrides: `-Xv2_unchecked=false` or `TOIT_V2_UNCHECKED=0`
compile checked code without making the program untrusted; the sandbox
tests use this for their trusted drivers, which start their own image as
an untrusted container.

## -O2 and the type propagator

(See the section below, filled in at milestone M3.)

## Devices

ESP32 targets keep format 1: the IDF component compiles the system
snapshot and the entry program with `TOIT_BYTECODE_FORMAT=1`
(toolchains/idf/components/toit/CMakeLists.txt), and the EC618 rule in the
Makefile does the same. Cross builds (Raspberry Pi, Windows, ...) have no
verified core, so their `TOIT_BYTECODE_FORMAT` defaults to 1, and their
embedded programs, compiled by the host compiler, get
`TOIT_BYTECODE_FORMAT=${TOIT_BYTECODE_FORMAT}` (src/CMakeLists.txt).
`toit compile --os/--arch` (executables for another target, from the
cross builds' vessels) defaults to format 1 too.

## Milestones

- M1: the compiler's default is format 2 on builds with the core; the
  CMake cache variable `TOIT_BYTECODE_FORMAT` replaces `TOIT_SYSTEM_FORMAT2`;
  `--untrusted` for toit.compile (no twins, certificate); trusted
  compilation (twins) is the default and ships no certificate; devices and
  cross builds keep format 1; the sandbox tests compile their images
  without twins and the CLI tests write their snapshots with
  `toit.run --untrusted -w`.

## Left to do

(Filled in as the work proceeds.)
