// Copyright (C) 2026 Toit contributors.

// Stamp the base-id record into the base AP image (frozen-base phase 4,
// docs/frozen-base-phase4.md).
//
// The record identifies the exact base build a slot must be linked against:
//
//   [ 'T' 'B' 'I' '1' ][ version : u32 LE ][ fingerprint : 16 bytes ]
//
// It lives in the `base-id` partition directly after the base image (the
// anchor — the partition descriptor is the source of truth for its
// address, which the linker template's TOIT_BASE_ID_ORIGIN must mirror
// until the base adopts the generated header). The fingerprint is the first
// 16 bytes of the SHA-256 over the base image EXCLUDING this page (the
// record cannot cover itself). The device reads the record over XIP and
// compares it against the id carried in every OTA payload's SRL3 table —
// a mismatched slot is rejected with a readable error instead of faulting.
//
// The version is a human-facing monotonic release number (base-vN, from
// toolchains/ec618/base-version); the fingerprint is the machine truth.

import cli
import crypto.sha256 show sha256
import encoding.json
import host.file
import host.pipe
import io show LITTLE-ENDIAN

import .partitions

MAGIC ::= #['T', 'B', 'I', '1']

main args:
  cmd := cli.Command "gen-base-id"
      --help="""
        Stamps the { magic, version, fingerprint } base-id record into the
        base AP image (in place) and prints the resulting id.
        """
      --options=[
        cli.Option "base"
            --help="The base AP image (build/ec618-base/base.bin), patched in place."
            --required,
        cli.Option "version-file"
            --help="File holding the base version number (base-vN)."
            --required,
        cli.Option "elf"
            --help="The base.elf, for the geometry section of the manifest.",
        cli.Option "manifest"
            --help="Write a JSON manifest (version, fingerprint, geometry) here.",
        cli.Option "nm"
            --help="The arm nm binary (for --manifest geometry)."
            --default="arm-none-eabi-nm",
        partitions-option,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  parts := Partitions.load invocation["partitions"]
  base := file.read-contents invocation["base"]
  version-text := (file.read-contents invocation["version-file"]).to-string.trim
  version := int.parse version-text

  offset := (parts.xip "base-id") - (parts.xip "base")
  page-size := parts["base-id"].size
  if offset + page-size > base.size:
    pipe.print-to-stderr "base image ($base.size bytes) does not reach the base-id page (file 0x$(%x offset))"
    exit 1

  // Fingerprint everything except the record's own page.
  pageless := (base.copy 0 offset) + (base.copy (offset + page-size))
  fingerprint := (sha256 pageless)[..16]

  record := ByteArray 24
  record.replace 0 MAGIC
  LITTLE-ENDIAN.put-uint32 record 4 version
  record.replace 8 fingerprint
  patched := base.copy
  patched.replace offset record
  file.write-contents --path=invocation["base"] patched

  hex := ""
  fingerprint.do: hex += "$(%02x it)"
  print "base-id: v$version fp=$hex -> $invocation["base"]"

  manifest-path := invocation["manifest"]
  if manifest-path:
    elf := invocation["elf"]
    if not elf:
      pipe.print-to-stderr "--manifest requires --elf for the geometry"
      exit 1
    geometry := read-geometry invocation["nm"] elf
    manifest := {
      "base-version": version,
      "fingerprint": hex,
      "geometry": geometry,
    }
    file.write-contents --path=manifest-path (json.encode manifest)
    print "manifest -> $manifest-path"

/**
Reads the base geometry symbols the slot link derives its script from
  (see tools/ec618/gen-slot-ld.toit) plus the dram-reserve end.
*/
GEOMETRY-SYMBOLS ::= {
  "__vm_link_base", "__vm_a_start", "__vm_b_start",
  "__vm_data_start", "end_ap_data", "__toit_rtc_slot",
}

read-geometry nm/string elf/string -> Map:
  result := {:}
  out := pipe.backticks [nm, elf]
  out.split "\n": | line/string |
    parts := line.split " "
    if parts.size >= 3 and GEOMETRY-SYMBOLS.contains parts.last:
      result[parts.last] = "0x$(%x (int.parse parts[0] --radix=16))"
  return result
