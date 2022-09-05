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
import bytes
import encoding.ubjson as ubjson
import host.file
import host.directory
import host.pipe
import .snapshot
import reader show BufferedReader
import writer show Writer

to_json_ o/ToitObject program/Program -> any:
  // TODO(florian): deal with cyclic structures.
  if o is ToitArray:
    array := o as ToitArray
    return array.content.map: to_json_ it program

  if o is ToitByteArray:
    // TODO(florian): improve byte-array handling.
    return "ByteArray"

  if o is ToitFloat:
    return (o as ToitFloat).value

  if o is ToitInteger:
    return (o as ToitInteger).value

  if o is ToitString:
    return (o as ToitString).content.to_string

  if o is ToitOddball:
    oddball := o as ToitOddball
    class_name := program.class_name_for oddball.class_id
    if class_name == "True_": return true
    if class_name == "False_": return false
    if class_name == "Null_": return null
    // TODO(florian): improve error handling.
    return "<unknown oddball>"

  if o is not ToitInstance: return {
    "<unknown type>"
  }

  instance := o as ToitInstance
  class_info /ClassInfo := program.class_info_for instance.class_id
  fields := instance.fields
  encoded_fields := {:}
  current_class := class_info
  field_index := fields.size - 1
  while current_class != null:
    current_class.fields.do:
      field_name := it
      field_val := fields[field_index--]
      // Superclass fields are shadowed.
      if not encoded_fields.contains field_name:
        encoded_fields[field_name] = to_json_ field_val program
    super_id := current_class.super_id
    current_class = super_id and program.class_info_for super_id
  // TODO(florian): improve error handling.
  assert: field_index == -1

  return {
    "class_name": class_info.name,
    "location_token": class_info.location_id,
    "fields": encoded_fields
  }

run_debug_snapshot snapshot_bytes json_message:
  tmp_directory := directory.mkdtemp "/tmp/debug_snapshot-"
  debug_toit := "$tmp_directory/debug.toit"
  try:
    ar_reader := ArReader (bytes.Reader snapshot_bytes)
    magic_bytes := ar_reader.find SnapshotBundle.MAGIC_NAME
    debug_snapshot := ar_reader.find "D-snapshot"
    debug_source_map := ar_reader.find "D-source-map"
    out_bytes := bytes.Buffer
    ar_writer := ArWriter out_bytes
    ar_writer.add SnapshotBundle.MAGIC_NAME magic_bytes.content
    ar_writer.add SnapshotBundle.SNAPSHOT_NAME debug_snapshot.content
    ar_writer.add SnapshotBundle.SOURCE_MAP_NAME debug_source_map.content
    // The debug snapshot and source-map also works for itself.
    ar_writer.add "D-snapshot" debug_snapshot.content
    ar_writer.add "D-source-map" debug_source_map.content
    stream := file.Stream.for_write debug_toit
    (Writer stream).write out_bytes.bytes
    stream.close

    // TODO(florian): we should use `spawn` or something similar to
    //   launch the debug snapshot.
    toit_run_path := "toit.run"
    pipes := pipe.fork
        true                // use_path
        pipe.PIPE_CREATED   // stdin
        pipe.PIPE_CREATED   // stdout
        pipe.PIPE_INHERITED // stderr
        toit_run_path
        [
          toit_run_path,
          debug_toit,
        ]
    to   := pipes[0]
    from := pipes[1]
    pid  := pipes[3]

    (Writer to).write (ubjson.encode json_message)
    to.close

    sub_reader := BufferedReader from
    sub_reader.buffer_all
    bytes := sub_reader.read_bytes sub_reader.buffered
    return bytes.to_string
  finally:
    if file.is_file debug_toit: file.delete debug_toit
    directory.rmdir tmp_directory
