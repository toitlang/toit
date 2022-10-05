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

handle_system_message encoded_system_message snapshot_content --force_pretty/bool=false --force_plain/bool=false --filename/string?=null:
  if force_pretty and force_plain: throw "Can't force both pretty and plain formats at once"
  program := null
  if snapshot_content:
    bundle := SnapshotBundle snapshot_content
    if bundle.uuid and filename and not filename.contains bundle.uuid.stringify:
      pipe.print_to_stdout "***********************************************************"
      pipe.print_to_stdout "** WARNING: the file '$filename' contains a different snapshot, $bundle.uuid!"
      pipe.print_to_stdout "***********************************************************"
    program = bundle.decode
  m := mirror.decode encoded_system_message program:
    pipe.print_to_stdout it
    return
  if (pipe.stdout.is_a_terminal or force_pretty) and not force_plain:
    pipe.print_to_stdout m.terminal_stringify
  else:
    pipe.print_to_stdout m.stringify

main args:
  command := null
  command = cli.Command "root"
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
        cli.Flag "force-pretty"
            --short_help="Force the report to use terminal graphics",
        cli.Flag "force-plain"
            --short_help="Force the report to be pure ASCII even on a terminal",
      ]
      --run=:: decode_system_message it command
  command.run args

decode_system_message parsed command -> none:
  if not parsed: exit 1
  encoded_system_message := base64.decode parsed["message"]
  snapshot_content := null
  if parsed["snapshot"]:
    snapshot_content = file.read_content parsed["snapshot"]

  if encoded_system_message.size < 1 or encoded_system_message[0] != '[':
    pipe.print_to_stderr "\nNot a ubjson message: '$parsed["message"]'\n"
    command.run ["--help"]
    exit 1
  handle_system_message encoded_system_message snapshot_content --filename=parsed["snapshot"]
      --force_pretty=parsed["force-pretty"]
      --force_plain=parsed["force-plain"]
