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

handle-system-message encoded-system-message snapshot-content -> none
    --force-pretty/bool=false
    --force-plain/bool=false
    --filename/string?=null
    --uuid/string?=null:
  if force-pretty and force-plain: throw "Can't force both pretty and plain formats at once"
  program := null
  if snapshot-content:
    bundle := SnapshotBundle snapshot-content
    if bundle.uuid and uuid and uuid != bundle.uuid.stringify:
      pipe.print-to-stdout "***********************************************************"
      source := ?
      if filename:
        source = "file '$filename'"
      else:
        source = "snapshot bundle"
      pipe.print-to-stdout "** WARNING: the $source contains an unexpected snapshot, $bundle.uuid!"
      pipe.print-to-stdout "***********************************************************"
    program = bundle.decode
  m := mirror.decode encoded-system-message program:
    pipe.print-to-stdout it
    return
  if (pipe.stdout.is-a-terminal or force-pretty) and not force-plain:
    pipe.print-to-stdout m.terminal-stringify
  else:
    pipe.print-to-stdout m.stringify

main args:
  command := null
  command = cli.Command "root"
      --short-help="Decodes system messages from devices"
      --long-help="""
        Decodes system messages like stack traces, profile runs, etc.
          from the devices.  This utility is automatically called
          by `jag decode` to provide nice output from the encoded
          messages a device prints on the serial port.
        """
      --options=[
        cli.OptionString "snapshot" --short-name="s"
            --short-help="The snapshot file of the program that produced the message",
        cli.OptionString "message" --short-name="m" --required
            --short-help="The base64-encoded message from the device",
        cli.OptionString "uuid" --short-name="u"
            --short-help="UUID of the snapshot that produced the message",
        cli.Flag "force-pretty"
            --short-help="Force the report to use terminal graphics",
        cli.Flag "force-plain"
            --short-help="Force the report to be pure ASCII even on a terminal",
      ]
      --run=:: decode-system-message it command
  command.run args

decode-system-message parsed command -> none:
  if not parsed: exit 1
  encoded-system-message := base64.decode parsed["message"]
  snapshot-content := null
  if parsed["snapshot"]:
    snapshot-content = file.read-content parsed["snapshot"]

  if encoded-system-message.size < 1 or encoded-system-message[0] != '[':
    pipe.print-to-stderr "\nNot a ubjson message: '$parsed["message"]'\n"
    command.run ["--help"]
    exit 1
  handle-system-message encoded-system-message snapshot-content
      --filename=parsed["snapshot"]
      --uuid=parsed["uuid"]
      --force-pretty=parsed["force-pretty"]
      --force-plain=parsed["force-plain"]
