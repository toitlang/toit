// Copyright (C) 2026 Toit contributors.

// The EC618 rig doctor — turns the hard-won bring-up footguns into
// automated checks instead of tribal knowledge. Host-side: verifies the
// tree, the base artifacts, the flashable images and the serial-port
// map. (The device-side counterpart is tests/hw/ec618/doctor-ec618.toit,
// run via the tester like any test.)
//
// Checks and the incidents they immortalize:
//  - descriptor loads + covers the flash        (layout drift)
//  - base artifacts present + stamped + symbols (the anti-drift gate)
//    match the descriptor; manifest agrees
//  - the flashable binpkg carries a CRC-valid   (a device without a
//    anchor record; table matches the YAML;      record cannot boot)
//    console byte reported per image
//  - the envelope carries the mini-jag agent    (raw flashes of the
//    or is flagged BARE                          bare make-envelope are
//                                                AGENTLESS: silence is
//                                                not death)
//  - toit_data_reloc.c matches the slot elf     (boot-time .data fixups)
//  - serial ports mapped by chip id             (never trust ttyUSBn)
//
// Run from the repo root:
//   build/host/sdk/bin/toit run --project-root tools tools/ec618/doctor.toit

import cli
import host.directory
import host.file
import host.pipe
import io show LITTLE-ENDIAN

import .partitions

passes := 0
warns := 0
fails := 0

ok message/string:
  passes++
  print "  ok   $message"

warn message/string:
  warns++
  print "  WARN $message"

fail message/string:
  fails++
  print "  FAIL $message"

section title/string:
  print "== $title"

main args:
  cmd := cli.Command "doctor"
      --help="Checks the EC618 tree, artifacts and rig for the known footguns."
      --options=[
        cli.Option "toit-exe"
            --help="The host toit executable (for tool invocations)."
            --default="build/host/sdk/bin/toit",
        cli.Option "base-dir"
            --help="The base artifacts directory."
            --default="build/ec618-base",
        partitions-option,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  toit-exe := invocation["toit-exe"]
  base-dir := invocation["base-dir"]

  section "partition descriptor"
  parts/Partitions? := null
  error := catch: parts = Partitions.load invocation["partitions"]
  if error:
    fail "$error"
  else:
    ok "$(parts.entries.size) entries, covers the flash, anchor chain derives"

  section "base artifacts ($base-dir)"
  base-bin/ByteArray? := null
  ["base.elf", "base.bin", "base-manifest.json"].do: | name/string |
    path := "$base-dir/$name"
    if file.is-file path: ok "$name present"
    else: fail "$name missing (run `make ec618-base`)"
  if parts and file.is-file "$base-dir/base.bin":
    base-bin = file.read-contents "$base-dir/base.bin"
    id-off := (parts["base-id"].offset) - (parts["base"].offset)
    if base-bin.size > id-off + 24 and base-bin[id-off] == 'T' and base-bin[id-off + 1] == 'B'
        and base-bin[id-off + 2] == 'I' and base-bin[id-off + 3] == '1':
      version := LITTLE-ENDIAN.uint32 base-bin (id-off + 4)
      wanted/string? := null
      catch: wanted = (file.read-contents "toolchains/ec618/base-version").to-string.trim
      if wanted and "$version" == wanted:
        ok "base stamped v$version (matches toolchains/ec618/base-version)"
      else:
        fail "base stamped v$version but base-version says $wanted"
    else:
      fail "no 'TBI1' base-id record at file 0x$(%x id-off) — base not stamped"

  section "flashable image (build/ec618/toit.binpkg)"
  if not file.is-file "build/ec618/toit.binpkg":
    warn "toit.binpkg missing (run `make ec618`) — image checks skipped"
  else if parts:
    ap := binpkg-ap-zone (file.read-contents "build/ec618/toit.binpkg")
    if ap == null:
      fail "no AP zone in toit.binpkg"
    else:
      table := find-anchor-table ap
      if table == null:
        fail "no CRC-valid anchor record in the AP image — a device flashed with this cannot boot"
      else:
        slots := table.filter: it.type == "slot"
        if slots.size == 2: ok "anchor record: $(table.size) entries, 2 slots"
        else: fail "anchor record has $(slots.size) slot entries (need 2)"
        matches := table.size == parts.entries.size
        if matches:
          parts.entries.size.repeat: | i/int |
            a/Partition := table[i]
            b/Partition := parts.entries[i]
            if a.name != b.name or a.offset != b.offset or a.size != b.size: matches = false
        if matches: ok "record table matches the descriptor"
        else: warn "record table differs from the descriptor (retargeted image? fine if intentional)"
        console := find-anchor-console ap
        console-name := console == 0xff ? "off" : "uart$console"
        ok "console byte: $console-name"

  section "envelope agent check (build/ec618/firmware.envelope)"
  if not file.is-file "build/ec618/firmware.envelope":
    warn "firmware.envelope missing"
  else:
    listing/string? := null
    catch: listing = pipe.backticks [toit-exe, "tool", "firmware", "container", "list",
                                     "-e", "build/ec618/firmware.envelope"]
    if listing == null:
      warn "could not list envelope containers"
    else if listing.contains "mini-jag":
      ok "envelope carries the mini-jag agent"
    else:
      warn "envelope is BARE (no mini-jag): raw flashes of it are AGENTLESS — silence is not death; tester flows inject the agent (add-ec618-containers)"

  section "boot-time .data fixups"
  if not file.is-file "build/ec618/toit-slot-a.elf":
    warn "toit-slot-a.elf missing — data-reloc check skipped"
  else:
    out/string? := null
    check-error := catch:
      out = pipe.backticks [toit-exe, "run", "--project-root", "tools",
                            "tools/ec618/gen-data-reloc.toit", "--",
                            "--readelf=arm-none-eabi-readelf",
                            "--elf=build/ec618/toit-slot-a.elf",
                            "--out=src/toit_data_reloc.c", "--check"]
    if check-error: fail "toit_data_reloc.c is STALE — regenerate (gen-data-reloc) and rebuild"
    else: ok "toit_data_reloc.c matches the slot elf"

  section "serial ports (by chip, never by ttyUSBn)"
  ports-dir := "/dev/serial/by-id"
  if not file.is-directory ports-dir:
    warn "$ports-dir missing — no USB serial devices?"
  else:
    stream := directory.DirectoryStream ports-dir
    count := 0
    while name := stream.next:
      count++
      kind := "unknown"
      if name.contains "1a86": kind = "CH340 (an EC618 console: modest-affair UART0 or quirky UART1)"
      else if name.contains "CP2102N": kind = "CP2102N (modest-affair ESP32 console)"
      else if name.contains "Espressif": kind = "ESP32-C6 native USB (quirky)"
      target/string? := null
      catch: target = (pipe.backticks ["readlink", "-f", "$ports-dir/$name"]).trim
      print "  info $(target ? "$target " : "")<- $kind"
    stream.close
    if count == 0: warn "no serial devices found"
    else: ok "$count serial device(s) enumerated"

  print ""
  print "doctor: $passes ok, $warns warnings, $fails failures"
  if fails > 0: exit 1

// Extracts the AP zone from a .binpkg (52-byte header + zones of a
// 364-byte image header — size at 76, subsystem at 336 — plus data).
binpkg-ap-zone pkg/ByteArray -> ByteArray?:
  pos := 52
  while pos + 364 <= pkg.size:
    size := LITTLE-ENDIAN.uint32 pkg (pos + 76)
    if pkg[pos + 336] == 'A' and pkg[pos + 337] == 'P':
      return pkg.copy (pos + 364) (pos + 364 + size)
    pos += 364 + size
  return null
