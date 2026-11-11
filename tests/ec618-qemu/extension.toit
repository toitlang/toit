// Copyright (C) 2026 Toit contributors.
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

/**
Writes the images of an EC618 envelope for the QEMU harness (harness.cc):
  a header (magic 'TQH1', the extension's address, the system UUID) at
  $HEADER-ADDRESS, followed by the bundled extension, relocated for
  $EXTENSION-ADDRESS, exactly as `toit tool firmware extract` puts it into
  the VM slot (tools/firmware/ec618.toit). QEMU loads the file at
  $HEADER-ADDRESS (`-device loader,file=...,addr=0x21000000`).

Usage: toit run --project-root tools tests/ec618-qemu/extension.toit --
           --envelope ENVELOPE --out FILE
*/

import cli
import encoding.json
import encoding.tison
import host.file
import io show LITTLE-ENDIAN
import system.assets
import uuid show Uuid

import ...tools.firmware show
    Envelope extract-container get-flags is-container-name
    AR-ENTRY-PROPERTIES SYSTEM-CONTAINER-NAME
import ...tools.firmware.ec618 as ec618
import ...tools.snapshot-to-image show sdk-version-uuid

HEADER-ADDRESS ::= 0x21000000
EXTENSION-ADDRESS ::= 0x21000100
MAGIC ::= 0x31485154  // 'TQH1'.

main args:
  cmd := cli.Command "extension"
      --help="Writes the images of an EC618 envelope for the QEMU harness."
      --options=[
        cli.Option "envelope" --required,
        cli.Option "out" --required,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  envelope := Envelope.load invocation["envelope"] --ui=invocation.cli.ui
  entries := envelope.entries
  properties := entries.get AR-ENTRY-PROPERTIES
      --if-present=: json.decode it
      --if-absent=: {:}
  flags := get-flags envelope

  // As extract-binary-ec618 (tools/firmware.toit): the system image first.
  containers := []
  has-system-image := entries.contains SYSTEM-CONTAINER-NAME
  if has-system-image: containers.add null
  non-system-images := {:}
  entries.do: | name/string content/ByteArray |
    if name == SYSTEM-CONTAINER-NAME or not is-container-name name: continue.do
    entry := extract-container name flags content --assets=(entries.get "+$name") --word-size=envelope.word-size
    containers.add entry
    non-system-images[name] = entry.id.to-byte-array
  if has-system-image:
    system-assets := {:}
    if not non-system-images.is-empty: system-assets["images"] = tison.encode non-system-images
    containers[0] = extract-container SYSTEM-CONTAINER-NAME flags entries[SYSTEM-CONTAINER-NAME]
        --assets=(assets.encode system-assets)
        --word-size=envelope.word-size

  system-uuid/Uuid? := null
  if properties.contains "uuid":
    system-uuid = Uuid.parse properties["uuid"] --if-error=(: null)
  system-uuid = system-uuid or sdk-version-uuid --sdk-version=envelope.sdk-version

  extension := ec618.extension-bytes
      --containers=containers
      --system-uuid=system-uuid
      --config-encoded=(ByteArray 0)
      --address=EXTENSION-ADDRESS
  header := ByteArray EXTENSION-ADDRESS - HEADER-ADDRESS
  LITTLE-ENDIAN.put-uint32 header 0 MAGIC
  LITTLE-ENDIAN.put-uint32 header 4 EXTENSION-ADDRESS
  header.replace 8 system-uuid.to-byte-array
  file.write-contents --path=invocation["out"] (header + extension)
  print "extension: $containers.size images, $extension.size bytes at 0x$(%x EXTENSION-ADDRESS)"
