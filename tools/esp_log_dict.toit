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
Dictionary logging of ESP-IDF messages.

With the dictionary-logging patch of ESP-IDF (components/log/include/esp_log_dict.h
  there; Kconfig LOG_CHECK_MESSAGES_DICT and LOG_DICT_ESP_LOG), a failed
  ESP_RETURN_ON_* or ESP_GOTO_ON_* check, and optionally every ESP_LOGE and
  ESP_LOGW, prints a line like
```
E (1234) gpio: {D1 3fa2c1b0 004a8 "GPIO_NUM_99" 00000063 9c2e}
```
  instead of the formatted message. The format string, file and line of the
  message stay in the ELF file, in a record of the non-allocated section
  `.esp_log_dict`. The `index` command collects the records into an index
  (the firmware envelope carries it as "log-dict.index"), and the `decode`
  command turns such lines back into the message:
```
E (1234) gpio: gpio.c:91: GPIO number error: GPIO_NUM_99 (99)
```

The line after the marker `{D1 `: the first 8 hex digits of the ELF file's
  SHA-256 (the build id), the record's offset in `.esp_log_dict` (5 hex
  digits), the arguments, and a CRC-16/CCITT-FALSE over everything from `{`
  to the end of the last argument (4 hex digits), then `}`. An argument is
  8 hex digits (32 bits), 16 hex digits (64 bits: long long, double), a
  quoted string with `\xNN` escapes (a `+` after the closing quote means
  the device cut it), `-` (a NULL string), or `+` (the remaining arguments
  did not fit into the line).
*/

import cli
import crypto.sha256 as crypto
import encoding.hex
import encoding.ubjson
import host.file
import host.pipe
import io
import io show LITTLE-ENDIAN
import math

import .firmware show Envelope AR-ENTRY-ESP32-LOG-DICT AR-ENTRY-ESP32-FIRMWARE-ELF

SECTION-NAME ::= ".esp_log_dict"
RECORD-MAGIC ::= 0x474f4c44  // "DLOG" in memory order.
RECORD-HEADER-SIZE ::= 12
/** The id is the offset in the section, 20 bits on the device. */
MAX-SECTION-SIZE ::= 1 << 20

KIND-W32 ::= 1
KIND-W64 ::= 2
KIND-STR ::= 3

FLAG-CHECK ::= 1

INDEX-FORMAT ::= "esp-log-dict"
INDEX-VERSION ::= 1

MARKER ::= "{D1 "
BUILD-ID-SIZE ::= 8
ID-SIZE ::= 5

LEVEL-LETTERS ::= "NEWIDV"

main args/List:
  cmd := build-command
  cmd.run args

build-command -> cli.Command:
  cmd := cli.Command "log-dict"
      --help="""
        Dictionary logging of ESP-IDF messages.

        Firmware built with the dictionary-logging patch of ESP-IDF prints
        lines like 'E (1234) gpio: {D1 3fa2c1b0 004a8 00000063 9c2e}' instead
        of formatted messages. The format strings stay in the ELF file; the
        'index' command extracts them, and the 'decode' command turns the
        lines back into messages.
        """
  cmd.add build-index-command
  cmd.add build-decode-command
  return cmd

build-index-command -> cli.Command:
  return cli.Command "index"
      --help="""
        Build the message index of a firmware from its ELF file.

        The index maps the message ids of the section '.esp_log_dict' to
        their level, file, line and format, and records the ELF file's
        SHA-256, which the device prints as build id.
        """
      --options=[
        cli.OptionPath "output" --short-name="o"
            --help="Set the output file."
            --required,
        cli.OptionEnum "format" ["ubjson", "text"]
            --help="Set the output format ('text' is for reading, 'decode' takes 'ubjson')."
            --default="ubjson",
        cli.Flag "allow-empty"
            --help="Write an empty index if the ELF file has no messages.",
        cli.Flag "live-only"
            --help="""
              Keep only the messages that the linked code refers to.

              The ELF file keeps the records of functions the linker dropped.
              This finds the references in the literal words of the loaded
              sections, which is how Xtensa code loads them (RISC-V code builds
              them from instructions, so this keeps nothing there).""",
      ]
      --rest=[
        cli.OptionPath "elf" --required --help="The firmware's ELF file.",
      ]
      --run=:: run-index it

build-decode-command -> cli.Command:
  return cli.Command "decode"
      --help="""
        Decode dictionary log lines.

        Without lines, reads the standard input and prints every line,
        decoded if it contains a dictionary message.

        The messages come from an index ('--index'), from the index of a
        firmware envelope ('--envelope'), or from an ELF file ('--elf').
        """
      --options=[
        cli.OptionPath "envelope" --short-name="e"
            --help="Take the index from this firmware envelope (or its ELF file).",
        cli.OptionPath "index"
            --help="Take the index from this file (from the 'index' command).",
        cli.OptionPath "elf"
            --help="Build the index from this ELF file.",
        cli.Flag "location"
            --help="Show file and line of every message (checks always show them).",
        cli.Flag "force"
            --help="Decode lines whose build id does not match the index.",
      ]
      --rest=[
        cli.Option "line" --multi --help="A console line.",
      ]
      --run=:: run-decode it
      --examples=[
        cli.Example "Decode a line with the index of an envelope:"
            --arguments="--envelope=firmware.envelope 'E (1234) gpio: {D1 3fa2c1b0 004a8 00000063 9c2e}'",
        cli.Example "Decode the console output of a device:"
            --arguments="--envelope=firmware.envelope < console.log",
      ]

run-index invocation/cli.Invocation -> none:
  ui := invocation.cli.ui
  elf := file.read-contents invocation["elf"]
  index := Index.from-elf elf --allow-empty=invocation["allow-empty"]
  if invocation["live-only"]:
    all := index.records.size
    index.keep-live elf
    ui.emit --info "$index.records.size of $all messages are referenced by the linked code."
  index.mismatches.do: | record/Record |
    ui.emit --warning "$record.location: the arguments do not match the format '$record.format'."
  output/ByteArray := invocation["format"] == "text"
      ? index.to-text.to-byte-array
      : index.encode
  file.write-contents output --path=invocation["output"]
  ui.emit --info "$index.records.size messages, $(output.size) bytes, build $index.build-id."

run-decode invocation/cli.Invocation -> none:
  ui := invocation.cli.ui
  index/Index? := null
  if invocation["index"]:
    index = Index.decode (file.read-contents invocation["index"])
  else if invocation["elf"]:
    index = Index.from-elf (file.read-contents invocation["elf"])
  else if invocation["envelope"]:
    index = Index.from-envelope invocation["envelope"] --ui=ui
  else:
    ui.abort "One of '--index', '--elf' or '--envelope' is required."
  decoder := Decoder index --location=invocation["location"] --force=invocation["force"]
  lines/List := invocation["line"]
  if not lines.is-empty:
    lines.do: print (decoder.decode-line it)
    return
  reader := io.Reader.adapt pipe.stdin
  while line := reader.read-line:
    print (decoder.decode-line line)

/** A message of the index. */
class Record:
  id/int
  level/int
  flags/int
  arg-count/int
  kinds/int
  file/string
  line/int
  format/string

  constructor --.id --.level --.flags --.arg-count --.kinds --.file --.line --.format:

  is-check -> bool: return flags & FLAG-CHECK != 0

  /** The argument kinds, first argument first. */
  kind-list -> List:
    return List arg-count: (kinds >> (2 * it)) & 3

  location -> string:
    return "$file:$line"

  /** The file name without its directory. */
  short-location -> string:
    slash := file.index-of --last "/"
    return "$file[slash + 1..]:$line"

/**
The messages of one firmware: the records of its ELF file's
  `.esp_log_dict` section by id.
*/
class Index:
  /** The SHA-256 of the ELF file, in hex. */
  elf-sha256/string
  records/Map  // From id to $Record.

  constructor .elf-sha256 .records:

  /**
  Builds the index from the bytes of an ELF file.

  Throws if the file has no `.esp_log_dict` section, unless $allow-empty.
  */
  constructor.from-elf elf/ByteArray --allow-empty/bool=false:
    elf-sha256 = hex.encode (crypto.sha256 elf)
    records = {:}
    section := find-elf-section_ elf SECTION-NAME
    if not section:
      if not allow-empty: throw "The ELF file has no $SECTION-NAME section."
    else:
      parse-records_ elf[section[0]..section[0] + section[1]]

  /** Decodes an index encoded with $encode. */
  constructor.decode bytes/ByteArray:
    map := ubjson.decode bytes
    if map["format"] != INDEX-FORMAT: throw "Not a log-dict index."
    if map["version"] != INDEX-VERSION: throw "Unsupported log-dict index version: $map["version"]."
    elf-sha256 = map["elf-sha256"]
    files/List := map["files"]
    records = {:}
    map["records"].do: | entry/List |
      record := Record
          --id=entry[0]
          --level=entry[1]
          --flags=entry[2]
          --arg-count=entry[3]
          --kinds=entry[4]
          --file=files[entry[5]]
          --line=entry[6]
          --format=entry[7]
      records[record.id] = record

  /**
  The index of a firmware envelope: its "log-dict.index" entry, or built
    from its ELF file if it has no index.
  */
  constructor.from-envelope path/string --ui/cli.Ui:
    envelope := Envelope.load path --ui=ui
    entry := envelope.entries.get AR-ENTRY-ESP32-LOG-DICT
    if entry: return Index.decode entry
    elf := envelope.entries.get AR-ENTRY-ESP32-FIRMWARE-ELF
    if not elf: ui.abort "The envelope has neither a message index nor an ELF file."
    return Index.from-elf elf

  /**
  Removes the records that no literal word of the loaded sections of $elf
    refers to (Xtensa: the word passed to esp_log_dict_write is a literal
    with the record id, the level and the argument kinds).
  */
  keep-live elf/ByteArray -> none:
    live := {}
    elf-alloc-sections_ elf: | offset/int size/int |
      for i := offset; i + 4 <= offset + size; i += 4:
        word := LITTLE-ENDIAN.uint32 elf i
        record/Record? := records.get (word & (MAX-SECTION-SIZE - 1))
        if record and (word >> 20) & 7 == record.level:
          kinds := (word >> 23) & 0xff
          if (word >> 31) == 1 or kinds == record.kinds: live.add record.id
    records.filter --in-place: | id /int _ | live.contains id

  /** The build id the device prints: the start of the ELF file's SHA-256. */
  build-id -> string:
    return elf-sha256[..BUILD-ID-SIZE]

  /** The records whose argument kinds do not match their format. */
  mismatches -> List:
    result := []
    records.do --values: | record/Record |
      expected := format-kinds record.format
      if expected != record.kind-list: result.add record
    return result

  encode -> ByteArray:
    files := {:}
    entries := []
    ids := records.keys.sort
    ids.do: | id/int |
      record/Record := records[id]
      file-index := files.get record.file --init=: files.size
      entries.add [
        record.id, record.level, record.flags, record.arg-count, record.kinds,
        file-index, record.line, record.format,
      ]
    return ubjson.encode {
      "format": INDEX-FORMAT,
      "version": INDEX-VERSION,
      "elf-sha256": elf-sha256,
      "files": files.keys,
      "records": entries,
    }

  to-text -> string:
    buffer := io.Buffer
    buffer.write "# $INDEX-FORMAT $INDEX-VERSION elf-sha256 $elf-sha256\n"
    ids := records.keys.sort
    ids.do: | id/int |
      record/Record := records[id]
      kinds := (record.kind-list.map: "-wls"[it..it + 1]).join ""
      check := record.is-check ? " check" : ""
      buffer.write "$(%05x id) $(LEVEL-LETTERS[record.level..record.level + 1])$check $(kinds.is-empty ? "-" : kinds) $record.location $(quote_ record.format)\n"
    return buffer.bytes.to-string-non-throwing

  parse-records_ section/ByteArray -> none:
    if section.size > MAX-SECTION-SIZE:
      throw "The $SECTION-NAME section is too large for 20-bit ids ($section.size bytes)."
    offset := 0
    while offset + RECORD-HEADER-SIZE <= section.size:
      if (LITTLE-ENDIAN.uint32 section offset) != RECORD-MAGIC:
        // Padding between records.
        offset += 4
        continue
      info := LITTLE-ENDIAN.uint32 section offset + 4
      kinds := LITTLE-ENDIAN.uint32 section offset + 8
      position := offset + RECORD-HEADER-SIZE
      strings := []
      3.repeat:
        end := section.index-of 0 --from=position
        if end < 0: throw "Truncated record at offset $offset of $SECTION-NAME."
        strings.add section[position..end].to-string-non-throwing
        position = end + 1
      record := Record
          --id=offset
          --level=info & 0xff
          --flags=(info >> 8) & 0xff
          --arg-count=(info >> 16) & 0xff
          --kinds=kinds
          --file=strings[0]
          --line=int.parse strings[1]
          --format=strings[2]
      records[offset] = record
      offset = (position + 3) & ~3

/**
Returns the file offset and size of the section $name of the 32-bit
  little-endian ELF file $elf, or null.
*/
find-elf-section_ elf/ByteArray name/string -> List?:
  if elf.size < 52 or elf[0..4] != #[0x7f, 'E', 'L', 'F']:
    throw "Not an ELF file."
  if elf[4] != 1 or elf[5] != 1:
    throw "Not a 32-bit little-endian ELF file."
  section-offset := LITTLE-ENDIAN.uint32 elf 0x20
  entry-size := LITTLE-ENDIAN.uint16 elf 0x2e
  count := LITTLE-ENDIAN.uint16 elf 0x30
  names-index := LITTLE-ENDIAN.uint16 elf 0x32
  header := : | i/int | section-offset + i * entry-size
  names := LITTLE-ENDIAN.uint32 elf (header.call names-index) + 16
  count.repeat: | i/int |
    h := header.call i
    name-offset := names + (LITTLE-ENDIAN.uint32 elf h)
    name-end := elf.index-of 0 --from=name-offset
    if elf[name-offset..name-end].to-string-non-throwing == name:
      return [LITTLE-ENDIAN.uint32 elf h + 16, LITTLE-ENDIAN.uint32 elf h + 20]
  return null

/**
Calls $block with the file offset and size of every allocated section
  with contents (SHT_PROGBITS) of the 32-bit little-endian ELF file $elf.
*/
elf-alloc-sections_ elf/ByteArray [block] -> none:
  section-offset := LITTLE-ENDIAN.uint32 elf 0x20
  entry-size := LITTLE-ENDIAN.uint16 elf 0x2e
  count := LITTLE-ENDIAN.uint16 elf 0x30
  count.repeat: | i/int |
    h := section-offset + i * entry-size
    type := LITTLE-ENDIAN.uint32 elf h + 4
    flags := LITTLE-ENDIAN.uint32 elf h + 8
    if type == 1 and flags & 2 != 0:  // SHT_PROGBITS, SHF_ALLOC.
      block.call (LITTLE-ENDIAN.uint32 elf h + 16) (LITTLE-ENDIAN.uint32 elf h + 20)

/**
The argument kinds ($KIND-W32, $KIND-W64, $KIND-STR) that the printf
  format $format takes, in order.
*/
format-kinds format/string -> List:
  result := []
  parse-format_ format
      --literal=: null
      --conversion=: | spec/Spec |
        if spec.width-from-arg: result.add KIND-W32
        if spec.precision-from-arg: result.add KIND-W32
        result.add spec.kind
  return result

/** A parsed printf conversion specification. */
class Spec:
  flags/string := ""
  width/int? := null
  width-from-arg/bool := false
  precision/int? := null
  precision-from-arg/bool := false
  length/string := ""
  conversion/int := 0

  /** The argument kind of the value of this conversion. */
  kind -> int:
    if conversion == 's': return KIND-STR
    if "fFeEgGaA".contains (string.from-rune conversion): return KIND-W64
    if conversion != 'p' and (length == "ll" or length == "j" or length == "q"): return KIND-W64
    return KIND-W32

/**
Calls $literal with the literal parts of $format and $conversion with a
  $Spec for each conversion (but not for `%%`, which is a literal `%`).
*/
parse-format_ format/string [--literal] [--conversion] -> none:
  i := 0
  start := 0
  while i < format.size:
    if format[i] != '%':
      i++
      continue
    if i > start: literal.call format[start..i]
    if i + 1 < format.size and format[i + 1] == '%':
      literal.call "%"
      i += 2
      start = i
      continue
    spec := Spec
    j := i + 1
    while j < format.size and "-+ #0'".contains format[j..j + 1]:
      spec.flags += format[j..j + 1]
      j++
    if j < format.size and format[j] == '*':
      spec.width-from-arg = true
      j++
    else:
      digits := j
      while j < format.size and '0' <= format[j] <= '9': j++
      if j > digits: spec.width = int.parse format[digits..j]
    if j < format.size and format[j] == '.':
      j++
      if j < format.size and format[j] == '*':
        spec.precision-from-arg = true
        j++
      else:
        digits := j
        while j < format.size and '0' <= format[j] <= '9': j++
        spec.precision = j > digits ? int.parse format[digits..j] : 0
    length := j
    while j < format.size and "hlLqjzt".contains format[j..j + 1]: j++
    spec.length = format[length..j]
    if j >= format.size:
      // An incomplete conversion at the end: printf prints nothing for it.
      start = format.size
      i = format.size
      break
    spec.conversion = format[j]
    conversion.call spec
    i = j + 1
    start = i
  if start < format.size: literal.call format[start..]

/**
Formats $format with the $args as C's printf would.

The $args are the values of a dictionary line: an integer with the raw
  bits for a 32-bit or 64-bit argument, a string or null for a string
  argument. Arguments that are missing format as `?`.
*/
format-printf format/string args/List -> string:
  buffer := io.Buffer
  next := 0
  next-arg := :
    next < args.size ? args[next++] : MISSING_
  parse-format_ format
      --literal=: | text/string | buffer.write text
      --conversion=: | spec/Spec |
        width := spec.width
        flags := spec.flags
        if spec.width-from-arg:
          w := next-arg.call
          width = w is int ? (sign-extend_ w 32) : 0
          if width < 0:
            flags += "-"
            width = -width
        precision := spec.precision
        if spec.precision-from-arg:
          p := next-arg.call
          precision = p is int ? (sign-extend_ p 32) : null
          if precision and precision < 0: precision = null
        value := next-arg.call
        buffer.write (format-conversion_ spec flags width precision value)
  return buffer.bytes.to-string-non-throwing

class Missing_:
MISSING_ ::= Missing_

format-conversion_ spec/Spec flags/string width/int? precision/int? value -> string:
  c := spec.conversion
  if value == MISSING_: return "?"
  left := flags.contains "-"
  zero := flags.contains "0" and not left
  if c == 's':
    text/string := ?
    if value is string:
      text = value
    else if value == null:
      text = "(null)"
    else:
      // A pointer that the device did not print as string (not a char*).
      return "<string at 0x$(%x value)>"
    if precision and precision < text.size: text = text[..precision]
    return pad_ text width --left=left --zero=false
  if value is not int:
    return "<$(spec.conversion == 'p' ? "pointer" : "number"): $value>"
  if c == 'c':
    return pad_ (string.from-rune value & 0xff) width --left=left --zero=false
  if c == 'p':
    return pad_ "0x$(%x value & 0xffff_ffff)" width --left=left --zero=false
  if "fFeEgGaA".contains (string.from-rune c):
    return format-float_ (float.from-bits value) c flags width precision
  bits := spec.length == "ll" or spec.length == "j" or spec.length == "q" ? 64 : 32
  if spec.length == "hh": bits = 8
  else if spec.length == "h": bits = 16
  if c == 'd' or c == 'i':
    v := sign-extend_ value bits
    sign := v < 0 ? "-" : (flags.contains "+" ? "+" : (flags.contains " " ? " " : ""))
    digits := unsigned-digits_ (v < 0 ? -v : v) 10
    return format-integer_ sign "" digits width precision --left=left --zero=zero
  v := bits == 64 ? value : value & ((1 << bits) - 1)
  radix := c == 'o' ? 8 : (c == 'u' ? 10 : 16)
  digits := unsigned-digits_ v radix
  if c == 'X': digits = digits.to-ascii-upper
  prefix := ""
  if flags.contains "#" and v != 0:
    if c == 'x': prefix = "0x"
    else if c == 'X': prefix = "0X"
  if flags.contains "#" and c == 'o' and not digits.starts-with "0":
    if not precision or precision <= digits.size: digits = "0$digits"
  return format-integer_ "" prefix digits width precision --left=left --zero=zero

format-integer_ sign/string prefix/string digits/string width/int? precision/int? --left/bool --zero/bool -> string:
  if precision:
    if precision == 0 and digits == "0": digits = ""
    if digits.size < precision: digits = "0" * (precision - digits.size) + digits
    zero = false  // A precision overrides the 0 flag.
  body := digits
  if zero and width and sign.size + prefix.size + digits.size < width:
    body = "0" * (width - sign.size - prefix.size - digits.size) + digits
  return pad_ "$sign$prefix$body" width --left=left --zero=false

format-float_ v/float c/int flags/string width/int? precision/int? -> string:
  left := flags.contains "-"
  zero := flags.contains "0" and not left
  upper := 'A' <= c <= 'Z'
  sign := v.sign == -1 or (v == 0.0 and (1.0 / v) < 0) ? "-" : (flags.contains "+" ? "+" : (flags.contains " " ? " " : ""))
  a := v.abs
  if a.is-nan or a == float.INFINITY:
    text := a.is-nan ? "nan" : "inf"
    return pad_ "$sign$(upper ? text.to-ascii-upper : text)" width --left=left --zero=false
  lower := c | 0x20
  p := precision or 6
  body/string := ?
  if lower == 'f':
    body = a.to-string --precision=(min p 64)
    if flags.contains "#" and p == 0: body += "."
  else if lower == 'e' or lower == 'a':
    // %a is rare in ESP-IDF; it is shown in the %e form.
    body = format-exponent_ a p --alternate=(flags.contains "#")
  else:
    // %g.
    if p == 0: p = 1
    exponent := decimal-exponent_ a (p - 1)
    if p > exponent and exponent >= -4:
      body = a.to-string --precision=(min (p - 1 - exponent) 64)
    else:
      body = format-exponent_ a (p - 1) --alternate=(flags.contains "#")
    if not flags.contains "#": body = strip-zeros_ body
  if upper: body = body.to-ascii-upper
  if zero and width and sign.size + body.size < width:
    body = "0" * (width - sign.size - body.size) + body
  return pad_ "$sign$body" width --left=left --zero=false

/** The decimal exponent of $a when printed in %e with $precision digits. */
decimal-exponent_ a/float precision/int -> int:
  if a == 0.0: return 0
  e := ((math.log a) / (math.log 10.0)).floor.to-int
  // Correct the estimate and account for rounding up to the next power of ten.
  if (math.pow 10.0 e.to-float) > a: e--
  if (math.pow 10.0 (e + 1).to-float) <= a: e++
  mantissa := (a / (math.pow 10.0 e.to-float)).to-string --precision=(min precision 64)
  if mantissa.starts-with "10": e++
  return e

format-exponent_ a/float precision/int --alternate/bool -> string:
  e := decimal-exponent_ a precision
  mantissa := a == 0.0 ? 0.0 : a / (math.pow 10.0 e.to-float)
  m := mantissa.to-string --precision=(min precision 64)
  if alternate and precision == 0: m += "."
  exponent-digits := e.abs < 10 ? "0$(e.abs)" : "$(e.abs)"
  return "$(m)e$(e < 0 ? "-" : "+")$exponent-digits"

/** Removes trailing zeros of the fraction (and a trailing point), as %g does. */
strip-zeros_ text/string -> string:
  e := text.index-of "e"
  mantissa := e < 0 ? text : text[..e]
  rest := e < 0 ? "" : text[e..]
  if not mantissa.contains ".": return text
  end := mantissa.size
  while end > 0 and mantissa[end - 1] == '0': end--
  if end > 0 and mantissa[end - 1] == '.': end--
  return mantissa[..end] + rest

pad_ text/string width/int? --left/bool --zero/bool -> string:
  if not width or text.size >= width: return text
  padding := (zero ? "0" : " ") * (width - text.size)
  return left ? text + padding : padding + text

sign-extend_ value/int bits/int -> int:
  if bits >= 64: return value
  value &= (1 << bits) - 1
  if value & (1 << (bits - 1)) != 0: value -= 1 << bits
  return value

/** The digits of $value as unsigned 64-bit number in $radix. */
unsigned-digits_ value/int radix/int -> string:
  if radix == 10: return value.to-string --uint64
  if value >= 0: return value.to-string --radix=radix
  shift := radix == 16 ? 4 : 3
  mask := radix - 1
  digits := ""
  while value != 0:
    digits = "0123456789abcdef"[value & mask..(value & mask) + 1] + digits
    value >>>= shift
  return digits

/** CRC-16/CCITT-FALSE (polynomial 0x1021, initial value 0xffff). */
crc16 bytes/ByteArray from/int=0 to/int=bytes.size -> int:
  crc := 0xffff
  for i := from; i < to; i++:
    crc ^= bytes[i] << 8
    8.repeat:
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff
  return crc

/**
A dictionary message of a console line, as parsed by $DictLine.parse.
*/
class DictLine:
  /** The text before the marker (normally "E (time) tag: "). */
  prefix/string
  /** The text after the closing brace. */
  suffix/string
  build-id/string
  id/int
  /**
  The arguments: an int for a 32-bit or 64-bit value (raw bits), a string
    or null for a string argument.
  */
  args/List
  /** The kinds of the $args (KIND-W32, KIND-W64, KIND-STR). */
  kinds/List
  /** Whether the device dropped arguments that did not fit. */
  truncated-args/bool
  /** Whether the device cut a string argument. */
  truncated-string/bool

  constructor --.prefix --.suffix --.build-id --.id --.args --.kinds --.truncated-args --.truncated-string:

  /**
  Parses the dictionary message in $line.

  Returns null if the line has none, or if its checksum is wrong.
  */
  static parse line/string -> DictLine?:
    bytes := line.to-byte-array
    start := line.index-of MARKER
    while start >= 0:
      result := parse_ line bytes start
      if result: return result
      start = line.index-of MARKER (start + 1)
    return null

  static parse_ line/string bytes/ByteArray start/int -> DictLine?:
    pos := start + MARKER.size
    if not is-hex_ bytes pos BUILD-ID-SIZE: return null
    build := line[pos..pos + BUILD-ID-SIZE]
    pos += BUILD-ID-SIZE
    if pos >= bytes.size or bytes[pos] != ' ': return null
    pos++
    if not is-hex_ bytes pos ID-SIZE: return null
    id := int.parse line[pos..pos + ID-SIZE] --radix=16
    pos += ID-SIZE
    args := []
    kinds := []
    truncated-args := false
    truncated-string := false
    while true:
      if pos >= bytes.size or bytes[pos] != ' ': return null
      token-start := pos
      pos++
      if pos >= bytes.size: return null
      c := bytes[pos]
      if c == '"':
        text := io.Buffer
        pos++
        while true:
          if pos >= bytes.size: return null
          b := bytes[pos]
          if b == '"': break
          if b == '\\':
            if not (pos + 3 < bytes.size and bytes[pos + 1] == 'x' and (is-hex_ bytes pos + 2 2)): return null
            text.write-byte (int.parse line[pos + 2..pos + 4] --radix=16)
            pos += 4
          else:
            text.write-byte b
            pos++
        pos++
        if pos < bytes.size and bytes[pos] == '+':
          truncated-string = true
          pos++
        args.add text.bytes.to-string-non-throwing
        kinds.add KIND-STR
      else if c == '-':
        args.add null
        kinds.add KIND-STR
        pos++
      else if c == '+':
        truncated-args = true
        pos++
      else:
        n := 0
        while pos + n < bytes.size and is-hex-digit_ bytes[pos + n]: n++
        if n == 4 and pos + 4 < bytes.size and bytes[pos + 4] == '}':
          crc := int.parse line[pos..pos + 4] --radix=16
          if crc != (crc16 bytes start token-start): return null
          return DictLine
              --prefix=line[..start]
              --suffix=line[pos + 5..]
              --build-id=build
              --id=id
              --args=args
              --kinds=kinds
              --truncated-args=truncated-args
              --truncated-string=truncated-string
        if n == 8:
          args.add (int.parse line[pos..pos + 8] --radix=16)
          kinds.add KIND-W32
        else if n == 16:
          // Two halves, so that values above 2^63 don't overflow the parser.
          high := int.parse line[pos..pos + 8] --radix=16
          low := int.parse line[pos + 8..pos + 16] --radix=16
          args.add (high << 32) | low
          kinds.add KIND-W64
        else:
          return null
        pos += n

  static is-hex-digit_ b/int -> bool:
    return '0' <= b <= '9' or 'a' <= b <= 'f'

  static is-hex_ bytes/ByteArray from/int count/int -> bool:
    if from + count > bytes.size: return false
    count.repeat: if not is-hex-digit_ bytes[from + it]: return false
    return true

/** Decodes console lines with an $Index. */
class Decoder:
  index/Index
  location/bool
  force/bool

  constructor .index --.location=false --.force=false:

  /**
  Returns $line with its dictionary message decoded, or $line unchanged if
    it has none.

  A line that can't be decoded keeps its text and gets a note in brackets.
  */
  decode-line line/string -> string:
    parsed := DictLine.parse line
    if not parsed: return line
    if parsed.build-id != index.build-id and not force:
      return "$line [log-dict: build $parsed.build-id, the index is for $index.build-id]"
    record/Record? := index.records.get parsed.id
    if not record:
      return "$line [log-dict: no message $(%05x parsed.id)]"
    notes := []
    if parsed.build-id != index.build-id:
      notes.add "build $parsed.build-id, the index is for $index.build-id"
    if not parsed.truncated-args and parsed.kinds != record.kind-list:
      notes.add "the arguments do not match the message"
    if parsed.truncated-args: notes.add "arguments cut"
    if parsed.truncated-string: notes.add "string cut"
    message := format-printf record.format parsed.args
    // ESP-IDF's messages end in a newline only through the log macros.
    if message.ends-with "\n": message = message[..message.size - 1]
    if record.is-check or location:
      message = "$record.short-location: $message"
    note := notes.is-empty ? "" : " [log-dict: $(notes.join ", ")]"
    return "$parsed.prefix$message$note$parsed.suffix"

quote_ text/string -> string:
  buffer := io.Buffer
  buffer.write "\""
  text.to-byte-array.do: | b/int |
    if b == '"' or b == '\\':
      buffer.write "\\"
      buffer.write-byte b
    else if b == '\n':
      buffer.write "\\n"
    else if b < 0x20 or b > 0x7e:
      buffer.write "\\x$(%02x b)"
    else:
      buffer.write-byte b
  buffer.write "\""
  return buffer.bytes.to-string-non-throwing
