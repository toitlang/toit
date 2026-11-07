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

import crypto.sha256 show Sha256
import io show Buffer LITTLE-ENDIAN

/** Flash operations used by the canonical firmware writer. */
interface SlotWriterBackend:
  slot-size -> int
  begin table/ByteArray --resume/bool -> none
  read offset/int bytes/ByteArray -> none
  erase offset/int -> none
  write offset/int bytes/ByteArray -> none
  end -> none
  stage -> none

/**
Writes the canonical `[size][SRL3 table][body][data]` stream.

Only complete body sectors and the complete relocation table are durable before
  $commit. $flush returns the number of buffered canonical bytes; checkpoints
  must subtract that count from their stream position before closing the writer.
  A resumed writer requires a checkpoint at the end of the table or a complete
  body sector, and rehashes the durable prefix before writing further bytes.
  It never erases a sector containing that prefix, even if power fails during
  the next write. The caller is responsible for passing
  a checkpoint from the same update; the final checksum also covers that prefix.
*/
class SlotFirmwareWriter:
  static SECTOR ::= 4096
  static SEGMENT ::= 16

  backend_/SlotWriterBackend
  limit_/int
  position_/int := 0
  header_/Buffer? := Buffer
  header-length_/int := 0
  table-length_/int := -1
  armed_/bool := false
  body_/ByteArray := ByteArray SECTOR
  fullness_/int := 0
  slot-offset_/int := 0
  erased-until_/int := 0
  sha_/Sha256 := Sha256
  finished_/bool := false
  failed_/bool := false
  closed_/bool := false

  constructor .backend_ from/int .limit_:
    if from < 0 or limit_ <= 0 or from > limit_ or limit_ > backend_.slot-size:
      throw "INVALID_ARGUMENT"
    if from != 0:
      succeeded := false
      try:
        resume_ from
        succeeded = true
      finally:
        if not succeeded: backend_.end

  check-open_ -> none:
    if closed_ or finished_ or failed_: throw "INVALID_STATE"

  check-size_ size/int -> none:
    check-open_
    if size < 0 or size > limit_ - position_: throw "OUT_OF_BOUNDS"

  write bytes/ByteArray -> int:
    check-size_ bytes.size
    succeeded := false
    try:
      consume_ bytes 0 bytes.size
      sha_.add bytes
      position_ += bytes.size
      succeeded = true
      return bytes.size
    finally:
      if not succeeded: failed_ = true

  pad size/int value/int -> int:
    check-size_ size
    if not (0 <= value <= 255): throw "INVALID_ARGUMENT"
    chunk := ByteArray (min size SECTOR) --initial=value
    remaining := size
    while remaining > 0:
      n := min remaining chunk.size
      write chunk[..n]
      remaining -= n
    return size

  table-size_ bytes/ByteArray -> int:
    size := LITTLE-ENDIAN.uint32 bytes 0
    if size < 52 or size % 4 != 0 or size > limit_ - 4:
      throw "firmware: invalid relocation table size"
    return size

  arm_ table/ByteArray --resume/bool -> none:
    // Native parsing checks the full SRL3 table, base identity and slot bounds
    // before touching flash. Check the requested canonical extent first.
    body-size := LITTLE-ENDIAN.uint32 table 12
    data-size := LITTLE-ENDIAN.uint32 table 24
    if header-length_ + body-size + data-size != limit_:
      throw "firmware: image size differs from relocation table"
    backend_.begin table --resume=resume
    armed_ = true
    header_ = null

  resume_ from/int -> none:
    size := ByteArray 4
    backend_.read 0 size
    table-length_ = table-size_ size
    header-length_ = 4 + table-length_
    // A partially received table has never been persisted. Its checkpoint is 0.
    if from < header-length_ or (from - header-length_) % SECTOR != 0:
      throw "INVALID_ARGUMENT"
    table := ByteArray table-length_
    backend_.read 4 table
    arm_ table --resume
    sha_.add size
    sha_.add table
    body-length := from - header-length_
    List.chunk-up 0 body-length SECTOR: | start end count |
      bytes := ByteArray count
      backend_.read (header-length_ + start) bytes
      sha_.add bytes
    slot-offset_ = body-length
    // Erase only sectors after the durable checkpoint. A further interruption
    // cannot destroy the prefix on which that checkpoint depends.
    erased-until_ = slot-offset_
    position_ = from

  consume_ bytes/ByteArray from/int to/int -> none:
    while from < to and not armed_:
      header_.write-byte bytes[from]
      from++
      header-length_++
      if header-length_ == 4:
        table-length_ = table-size_ header_.bytes
      else if table-length_ >= 0 and header-length_ == 4 + table-length_:
        arm_ header_.bytes[4..] --no-resume
    while from < to:
      n := min (SECTOR - fullness_) (to - from)
      body_.replace fullness_ bytes from (from + n)
      fullness_ += n
      from += n
      if fullness_ == SECTOR:
        write-sector_ SECTOR
        slot-offset_ += SECTOR
        fullness_ = 0

  write-sector_ size/int -> none:
    if erased-until_ == slot-offset_:
      backend_.erase slot-offset_
      erased-until_ += SECTOR
    backend_.write slot-offset_ body_[..size]

  flush -> int:
    check-open_
    // Header bytes become durable only once the complete table is written.
    return armed_ ? fullness_ : header-length_

  commit checksum/ByteArray? -> none:
    check-open_
    if not armed_ or position_ != limit_:
      throw "firmware: incomplete image"
    succeeded := false
    try:
      digest := sha_.get
      if checksum and checksum != digest: throw "firmware: checksum mismatch"
      if fullness_ > 0:
        padded := round-up fullness_ SEGMENT
        body_.fill --from=fullness_ --to=padded 0
        write-sector_ padded
        fullness_ = 0
      backend_.end
      backend_.stage
      finished_ = true
      succeeded = true
    finally:
      if not succeeded: failed_ = true

  close -> none:
    if closed_: return
    closed_ = true
    backend_.end
