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

import encoding.base64
import encoding.ubjson
import cli
import fs
import fs.xdg
import host.file
import host.file
import host.pipe
import uuid
import .snapshot
import .system-message_
import .mirror as mirror

handle-system-message system-message/SystemMessage snapshot-content -> none
    --force-pretty/bool=false
    --force-plain/bool=false
    --filename/string?=null
    --uuid/uuid.Uuid?=null:
  if force-pretty and force-plain: throw "Can't force both pretty and plain formats at once"
  program := null
  if snapshot-content:
    bundle := SnapshotBundle snapshot-content
    if bundle.uuid and uuid and uuid != bundle.uuid:
      pipe.print-to-stdout "***********************************************************"
      source := ?
      if filename:
        source = "file '$filename'"
      else:
        source = "snapshot bundle"
      pipe.print-to-stdout "** WARNING: the $source contains an unexpected snapshot, $bundle.uuid!"
      pipe.print-to-stdout "***********************************************************"
    program = bundle.decode
  m := mirror.decode system-message.payload program --on-error=:
    pipe.print-to-stdout it
    return
  if (pipe.stdout.is-a-terminal or force-pretty) and not force-plain:
    pipe.print-to-stdout m.terminal-stringify
  else:
    pipe.print-to-stdout m.stringify

build-command --use-old-api/bool=false -> cli.Command:
  search-dirs := compute-snapshot-dirs

  message-option := cli.Option "message" --short-name="m" --required
        --help="The base64-encoded message from the device."
  options := [
    cli.Option "snapshot" --short-name="s"
        --help="The snapshot file of the program that produced the message.",
    cli.Option "uuid" --short-name="u"
        --help="UUID of the snapshot that produced the message. Deprecated."
        --hidden=(not use-old-api),
    cli.Flag "force-pretty"
        --help="Force the report to use terminal graphics.",
    cli.Flag "force-plain"
        --help="Force the report to be pure ASCII even on a terminal.",
  ]
  rest/List? := null
  examples/List? := null
  if use-old-api:
    options = [message-option] + options
  else:
    rest = [message-option]
    examples = [
        cli.Example "Decode a message, searching for the snapshot file in the default directories:"
            --arguments="WyNVBVVYU...VQhJBc0=",
        cli.Example "Decode a message, using the supplied snapshot:"
            --arguments="--snapshot foo.snapshot WyNVBVVQ...VQhJBc0=",
      ]
  return cli.Command "decode"
      --help="""
        Decodes system messages.

        System messages encode stack traces, profile runs, and other information.
        This utility is automatically called  by `jag monitor` to provide nice
        output from the encoded messages a device prints on the serial port.

        Searches for a snapshot file based on the UUID of the program that produced
        the message. If the snapshot file is not found, the message is still decoded
        but the output will be less informative.

        Searches in the following directories for snapshot files:
        $((search-dirs.map: "- $it").join "\n")
        """
      --options=options
      --rest=rest
      --examples=examples
      --run=:: decode it

// TODO(florian): when removing this entry-point, rename the file and make the
// "system-message_.toit" file the new "system-message.toit".
// Also remove the "use-old-api" flag from the "build-command" function.
main args:
  command := build-command --use-old-api
  command.run args

compute-snapshot-dirs -> List:
  return [
    fs.join xdg.state-home "toit" "snapshots",
    fs.join xdg.cache-home "jaguar" "snapshots",
  ]

find-snapshot id/uuid.Uuid -> string?:
  compute-snapshot-dirs.do: | dir/string |
    path := fs.join dir "$(id).snapshot"
    if file.is-file path:
      return path
  return null

decode invocation/cli.Invocation -> none:
  if invocation["uuid"]:
    pipe.print-to-stdout "The --uuid flag is deprecated and will be removed in a future release."

  // The encoded-system-message is ubjson-encoded.
  encoded-system-message := base64.decode invocation["message"]
  // The decoded message still has its payload encoded in JSON.
  decoded-system-message := decode-system-message encoded-system-message --on-error=:
    pipe.print-to-stderr it
    exit 1

  snapshot-path := invocation["snapshot"]
  if not snapshot-path:
    // Try to find the snapshot based on the UUID.
    snapshot-path = find-snapshot decoded-system-message.program-uuid

  snapshot-content := null
  if snapshot-path:
    snapshot-content = file.read-content invocation["snapshot"]

  if encoded-system-message.size < 1 or encoded-system-message[0] != '[':
    pipe.print-to-stderr "\nNot a ubjson message: '$invocation["message"]'\n"
    exit 1

  handle-system-message decoded-system-message snapshot-content
      --filename=snapshot-path
      --uuid=decoded-system-message.program-uuid
      --force-pretty=invocation["force-pretty"]
      --force-plain=invocation["force-plain"]
