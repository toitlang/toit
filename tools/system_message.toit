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
import cli
import host.file
import host.file
import host.pipe
import .snapshot
import .mirror as mirror

handle_system_message encoded_system_message snapshot_content:
  program := null
  if snapshot_content: program = (SnapshotBundle snapshot_content).decode
  m := mirror.decode encoded_system_message program:
    pipe.print_to_stdout it
    return
  if pipe.stdout.is_a_terminal:
    pipe.print_to_stdout m.terminal_stringify
  else:
    pipe.print_to_stdout m.stringify

usage prog_name:
  pipe.print_to_stderr """
    Usage:
      $prog_name <snapshot>
      $prog_name <snapshot> <system message or heap_dump file>
      $prog_name <snapshot> -b <base64-encoded-ubjson>
      $prog_name [--snapshot|-s <snapshot>] --message|-m <base64-encoded-ubjson>
      # Eg snapshot file can be toit.run.snapshot

    If no system-message file is given, the stack trace is read from stdin."""
  exit 1

main args:
  prog_name := "system_message"
  if args.size < 1: usage prog_name
  legacy_args := (args[0].ends_with ".snapshot") and (not args[0].starts_with "-")
  snapshot_content := null
  encoded_system_message := null
  if legacy_args:
    if not 1 <= args.size <= 3:
      usage prog_name
      unreachable
    snapshot := args[0]
    if not file.is_file snapshot:
      pipe.print_to_stderr "No such snapshot file: $snapshot"
      usage prog_name
      unreachable
    snapshot_content = file.read_content snapshot
    if not SnapshotBundle.is_bundle_content snapshot_content:
      pipe.print_to_stderr "Not a snapshot file: $snapshot"
      usage prog_name
      unreachable
    if args.size == 3:
      if args[1] != "-b" or args[2].contains ".": usage prog_name
      encoded_system_message = base64.decode args[2]
    else if args.size == 2:
      if not file.is_file args[1]:
        pipe.print_to_stderr "No such ubjson file: $args[1]"
        usage prog_name
      encoded_system_message = file.read_content args[1]
    else:
      encoded_system_message = ByteArray 0
      while byte_array := pipe.stdin.read: encoded_system_message += byte_array
  else:
    // Use arguments library.
    parsed := null
    command := cli.Command "system_message"
        --short_help="Decodes system messages from devices"
        --long_help="""
          Decodes system messages like stack traces, profile runs, etc.
            from the devices.  This utility is automatically called
            by `jag decode` to provide nice output from the encoded
            messages a device prints on the serial port.
          """
        --options=[
          cli.OptionString "snapshot" --short_name="s"
              --short_help="The snapshot file of the program that produced the message",
          cli.OptionString "message" --short_name="m" --required
              --short_help="The base64-encoded message from the device",
        ]
        --run=:: parsed = it
    command.run args
    if not parsed: exit 1
    encoded_system_message = base64.decode parsed["message"]
    if parsed["snapshot"]:
      snapshot_content = file.read_content parsed["snapshot"]

  if encoded_system_message.size < 1 or encoded_system_message[0] != '[':
    pipe.print_to_stderr "Not a ubjson file"
    usage prog_name
  handle_system_message encoded_system_message snapshot_content
