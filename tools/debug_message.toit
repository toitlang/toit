// Copyright (C) 2020 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import ar show *
import encoding.ubjson as ubjson
import host.file
import host.directory
import host.pipe
import io
import .snapshot

to-json_ o/ToitObject program/Program -> any:
  // TODO(florian): deal with cyclic structures.
  if o is ToitArray:
    array := o as ToitArray
    return array.content.map: to-json_ it program

  if o is ToitByteArray:
    // TODO(florian): improve byte-array handling.
    return "ByteArray"

  if o is ToitFloat:
    return (o as ToitFloat).value

  if o is ToitInteger:
    return (o as ToitInteger).value

  if o is ToitString:
    return (o as ToitString).content.to-string

  if o is ToitOddball:
    oddball := o as ToitOddball
    class-name := program.class-name-for oddball.class-id
    if class-name == "True_": return true
    if class-name == "False_": return false
    if class-name == "Null_": return null
    // TODO(florian): improve error handling.
    return "<unknown oddball>"

  if o is not ToitInstance: return {
    "<unknown type>"
  }

  instance := o as ToitInstance
  class-info /ClassInfo := program.class-info-for instance.class-id
  fields := instance.fields
  encoded-fields := {:}
  current-class := class-info
  field-index := fields.size - 1
  while current-class != null:
    current-class.fields.do:
      field-name := it
      field-val := fields[field-index--]
      // Superclass fields are shadowed.
      if not encoded-fields.contains field-name:
        encoded-fields[field-name] = to-json_ field-val program
    super-id := current-class.super-id
    current-class = super-id and program.class-info-for super-id
  // TODO(florian): improve error handling.
  assert: field-index == -1

  return {
    "class_name": class-info.name,
    "location_token": class-info.location-id,
    "fields": encoded-fields
  }

run-debug-snapshot snapshot-bytes json-message:
  tmp-directory := directory.mkdtemp "/tmp/debug_snapshot-"
  debug-toit := "$tmp-directory/debug.toit"
  try:
    ar-reader := ArReader (io.Reader snapshot-bytes)
    magic-bytes := ar-reader.find SnapshotBundle.MAGIC-NAME
    debug-snapshot := ar-reader.find "D-snapshot"
    debug-source-map := ar-reader.find "D-source-map"
    out-bytes := io.Buffer
    ar-writer := ArWriter out-bytes
    ar-writer.add SnapshotBundle.MAGIC-NAME magic-bytes.contents
    ar-writer.add SnapshotBundle.SNAPSHOT-NAME debug-snapshot.contents
    ar-writer.add SnapshotBundle.SOURCE-MAP-NAME debug-source-map.contents
    // The debug snapshot and source-map also works for itself.
    ar-writer.add "D-snapshot" debug-snapshot.contents
    ar-writer.add "D-source-map" debug-source-map.contents
    stream := file.Stream.for-write debug-toit
    (io.Writer.adapt stream).write out-bytes.bytes
    stream.close

    // TODO(florian): we should use `spawn` or something similar to
    //   launch the debug snapshot.
    toit-run-path := "toit.run"
    process := pipe.fork
        --use-path
        --create-stdin
        --create-stdout
        toit-run-path
        [
          toit-run-path,
          debug-toit,
        ]

    process.stdin.out.write (ubjson.encode json-message)
    process.stdin.close

    bytes := process.stdout.in.read-all
    process.stdout.close
    process.wait
    return bytes.to-string
  finally:
    if file.is-file debug-toit: file.delete debug-toit
    directory.rmdir tmp-directory
