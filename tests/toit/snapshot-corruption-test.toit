// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ar show ArReader
import expect show *
import host.file
import io show LITTLE-ENDIAN

import .utils

// The snapshot reader used to trust its input. Malformed snapshots made it
// exit, hit a FATAL, or read and write out of bounds. It now rejects them,
// and 'toit run' fails with an INVALID_ARGUMENT error instead of crashing.

// Offsets in the snapshot header.
MAGIC-OFFSET ::= 0
TABLE-LENGTH-OFFSET ::= 24
// The length of the class-bits list follows the 32-byte header.
CLASS-BITS-LENGTH-OFFSET ::= 32

main args:
  toit-exe := ToitExecutable args

  with-tmp-dir: | tmp-dir/string |
    src-path := "$tmp-dir/hello.toit"
    file.write-contents --path=src-path """
      main: print "hello world"
      """
    snapshot-path := "$tmp-dir/hello.snapshot"
    toit-exe.backticks ["compile", "--snapshot", "-o", snapshot-path, src-path]
    bundle := file.read-contents snapshot-path
    offsets := (ArReader.from-bytes bundle).find --offsets "snapshot"
    snapshot-start := offsets.from

    expect ((toit-exe.backticks ["run", snapshot-path]).contains "hello world")

    corrupted-path := "$tmp-dir/corrupted.snapshot"
    [
      // A wrong magic marker used to exit the VM.
      MAGIC-OFFSET,
      // A negative table length used to crash with a segmentation fault.
      TABLE-LENGTH-OFFSET,
      // A negative list length used to hit a FATAL, and a huge one to crash
      // with a segmentation fault.
      CLASS-BITS-LENGTH-OFFSET,
    ].do: | offset/int |
      [0x7fff_ffff, -1].do: | value/int |
        corrupted := bundle.copy
        LITTLE-ENDIAN.put-int32 corrupted (snapshot-start + offset) value
        file.write-contents --path=corrupted-path corrupted
        result := toit-exe.fork ["run", corrupted-path]
        expect-null result.exit-signal
        expect-equals 1 result.exit-code
        expect-not (result.stdout.contains "hello world")
        expect (result.stderr.contains "INVALID_ARGUMENT")
