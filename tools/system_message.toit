#!/usr/bin/env toit

// Copyright (C) 2018 Toitware ApS.
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

import encoding.base64 as base64
import host.file
import host.pipe
import .snapshot
import .mirror as mirror

handle_system_message encoded_system_message snapshot_content:
  program := null
  if snapshot_content:
    program = (SnapshotBundle snapshot_content).decode
  m := mirror.decode encoded_system_message program:
    pipe.print_to_stdout it
    return
  if pipe.stdout.is_a_terminal:
    pipe.print_to_stdout m.terminal_stringify
  else:
    pipe.print_to_stdout m.stringify
  pipe.print_to_stdout ""

usage prog_name:
  pipe.print_to_stderr """
    Usage:
      $prog_name <snapshot>
      $prog_name <snapshot> <system message or heap_dump file>
      $prog_name <snapshot> -b <base64-encoded-ubjson>
      # Eg snapshot file can be toit.run.snapshot
      # For system messages like heap dumps the snapshot can be 'nosnapshot'

    If no system-message file is given, the stack trace is read from stdin."""
  exit 1

main args:
  prog_name := "system_message"
  if not 1 <= args.size <= 3: usage prog_name
  snapshot := args[0]
  snapshot_content := null
  if snapshot != "nosnapshot":
    if not file.is_file snapshot:
      pipe.print_to_stderr "No such snapshot file: $snapshot"
      usage prog_name
    snapshot_content = file.read_content snapshot
    if not SnapshotBundle.is_bundle_content snapshot_content:
      pipe.print_to_stderr "Not a snapshot file: $snapshot"
      usage prog_name
  encoded_system_message := null
  if args.size == 3:
    if args[1] != "-b" or args[2].contains ".": usage prog_name
    encoded_system_message = base64.decode args[2]
  else if args.size == 2:
    if not file.is_file args[1]:
      pipe.print_to_stderr "No such ubjson file: $args[1]"
      usage prog_name
    encoded_system_message = file.read_content args[1]
  else:
    p := pipe.from "cat"
    encoded_system_message = ByteArray 0
    while byte_array := p.read: encoded_system_message += byte_array
  if encoded_system_message.size < 1 or encoded_system_message[0] != '[':
    pipe.print_to_stderr "Not a ubjson file"
    usage prog_name
  handle_system_message encoded_system_message snapshot_content
