# Fuzzing harnesses

Three harnesses for the parts of the VM that take untrusted input.

## libFuzzer harnesses (C++)

- `message-decoder-fuzzer.cc`: decodes the input as TISON (`tison.decode`
  is the decoder entry point untrusted code reaches directly). Decoded
  values are then sent through the inter-process path (`MessageEncoder`,
  `MessageDecoder` of the receiving process, external allocations) and
  must re-encode to the same bytes. Raw bytes are not fed to the IPC
  decoder: IPC buffers contain raw pointers by design and are only produced
  by the VM.
- `snapshot-reader-fuzzer.cc`: reads the input as a program snapshot (the
  bytes `snapshot.launch` receives) or, if it is an ar archive, as a
  snapshot bundle. The reader must return an invalid image for malformed
  input and never crash.

Build (needs clang with libFuzzer, and a normal `make sdk` build first,
whose boot snapshot the harnesses embed):

```
tests/fuzz/build.sh            # Creates build/fuzz/fuzz/*-fuzzer.
```

Run (the VM's `operator new` and ASan's `delete[]` disagree, hence
`alloc_dealloc_mismatch=0`; the message harness keeps a process heap alive
across inputs, hence `detect_leaks=0`):

```
export ASAN_OPTIONS=alloc_dealloc_mismatch=0:detect_leaks=0
build/fuzz/fuzz/snapshot-reader-fuzzer -max_len=131072 CORPUS_DIR
build/fuzz/fuzz/message-decoder-fuzzer -max_len=8192 CORPUS_DIR
```

Seed corpora: raw snapshots (`ar p program.snapshot snapshot`) and bundles
of small programs for the reader; `tison.encode` outputs of assorted values
(lists, maps, strings, byte arrays, nested values, large ints, floats) for
the decoder.

## Primitive fuzz driver (Toit)

`primitive-fuzz.toit` calls each primitive of the allowed (pure,
process-local) set with random arguments of right and wrong types and
expects every call to return or throw. The wrappers in `primitives.toit`
are generated:

```
toit run tests/fuzz/gen-primitive-fuzz.toit > tests/fuzz/primitives.toit
toit run tests/fuzz/primitive-fuzz.toit -- <seed> <iterations> [<trace-from>]
```

Runs are deterministic per seed; to reproduce a crash rerun with
`<trace-from>` at the last printed progress iteration. Calls that take more
than 0.5 s are printed as `slow:` (primitives are not preemptible).
