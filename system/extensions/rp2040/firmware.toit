// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import system.services show ServiceResource
import system.base.firmware show FirmwareWriter
import crypto.sha256 show Sha256
import monitor
import rp2040

import ..shared.firmware show EmbeddedFirmwareServiceProviderBase

SECTOR-SIZE_ ::= 4096
CAPACITY_ ::= 0xf0000

class FirmwareServiceProvider extends EmbeddedFirmwareServiceProviderBase:
  writer_/FirmwareWriter_? := null
  committed_/bool := false
  mutex_ ::= monitor.Mutex

  constructor:
    super "system/firmware/rp2040"

  // Serialize calls across clients, including waits for the native worker.
  handle index/int arguments/any --gid/int --client/int -> any:
    return mutex_.do: super index arguments --gid=gid --client=client

  is-validation-pending -> bool: return false
  is-rollback-possible -> bool: return false
  validate -> bool: return false
  rollback -> none: throw "UNSUPPORTED"
  uri -> string?: return null

  upgrade -> none:
    if not committed_: throw "INVALID_STATE"
    rp2040.reset

  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    if writer_: throw "ALREADY_IN_USE"
    if from != 0 or not (264 <= to <= CAPACITY_): throw "INVALID_ARGUMENT"
    committed_ = false
    perform_ 0 0
    writer := FirmwareWriter_ this client to
    writer_ = writer
    return writer

  on-writer-closed_ writer/FirmwareWriter_ -> none:
    mutex_.do:
      // A disconnected client's handler can have been cancelled while the
      // worker still owns its copied sector. Finish before admitting a writer.
      while status_ == 1: sleep --ms=1
      if writer_ == writer: writer_ = null

  on-committed_ -> none:
    committed_ = true

/** Stages a complete application image without modifying the running image. */
class FirmwareWriter_ extends ServiceResource implements FirmwareWriter:
  service_/FirmwareServiceProvider
  size_/int
  buffer_/ByteArray ::= ByteArray SECTOR-SIZE_ --initial=0xff
  received_/int := 0
  fullness_/int := 0
  sha_/Sha256 ::= Sha256
  failed_/bool := false
  committed_/bool := false

  constructor .service_ client/int .size_:
    super service_ client

  check-open_ -> none:
    if is-closed or failed_ or committed_: throw "ALREADY_CLOSED"

  write bytes/ByteArray -> int:
    check-open_
    if bytes.size > size_ - received_: throw "OUT_OF_BOUNDS"
    failed_ = true
    sha_.add bytes
    from := 0
    while from < bytes.size:
      count := min (SECTOR-SIZE_ - fullness_) (bytes.size - from)
      buffer_.replace fullness_ bytes from (from + count)
      fullness_ += count
      received_ += count
      from += count
      if fullness_ == SECTOR-SIZE_: flush-sector_
    failed_ = false
    return bytes.size

  pad size/int value/int -> int:
    check-open_
    if size < 0 or not (0 <= value <= 255): throw "INVALID_ARGUMENT"
    if size > size_ - received_: throw "OUT_OF_BOUNDS"
    chunk := ByteArray (min size SECTOR-SIZE_) --initial=value
    remaining := size
    while remaining > 0:
      count := min remaining chunk.size
      write chunk[..count]
      remaining -= count
    return size

  flush-sector_ -> none:
    buffer_.fill --from=fullness_ 0xff
    perform_ 1 (received_ - fullness_) buffer_
    fullness_ = 0

  flush -> int:
    check-open_
    // Retain a partial sector until it can be written once in full.
    return fullness_

  commit checksum/ByteArray? -> none:
    check-open_
    if received_ != size_: throw "firmware: incomplete image"
    failed_ = true
    if checksum and checksum != sha_.get: throw "firmware: checksum mismatch"
    if fullness_ != 0: flush-sector_
    // The worker validates the vectors and read-back CRC before publishing
    // the pending descriptor. Any reboot after this point installs the image.
    perform_ 2 size_
    committed_ = true
    failed_ = false
    service_.on-committed_

  on-closed -> none:
    service_.on-writer-closed_ this

perform_ operation/int argument/int bytes/ByteArray=#[] -> none:
  submit_ operation argument bytes
  // Only the Toit task waits. Native primitives never wait for flash work,
  // and the worker retains a bounded native copy rather than a heap pointer.
  while status_ == 1: sleep --ms=1
  if status_ != 2: throw "firmware: flash operation failed"

submit_ operation/int argument/int bytes/ByteArray -> none:
  #primitive.rp2040.firmware-submit

status_ -> int:
  #primitive.rp2040.firmware-status
