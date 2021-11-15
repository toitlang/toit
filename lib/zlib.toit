// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import reader
import crypto
import crypto.adler32 as crypto
import crypto.crc32 as crypto

class ZlibEncoder_ implements reader.Reader:
  channel_ := monitor.Channel 1

  static SMALL_BUFFER_DEFLATE_HEADER_ ::= [8, 0x1d]
  static MINIMAL_GZIP_HEADER_ ::= [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]

  constructor --gzip_header/bool:
    header := gzip_header ? MINIMAL_GZIP_HEADER_ : SMALL_BUFFER_DEFLATE_HEADER_
    channel_.send (ByteArray header.size: header[it])

  read:
    return channel_.receive

class UncompressedDeflateEncoder_ extends ZlibEncoder_:
  summer_/crypto.Checksum := ?

  constructor this.summer_ --gzip_header/bool:
    super --gzip_header=gzip_header
    buffer_fullness_ = BLOCK_HEADER_SIZE_

  buffer_ := ByteArray 256
  buffer_fullness_ := 0
  last_buffer_ := ByteArray 256

  static BLOCK_HEADER_SIZE_ ::= 5

  write collection from=0 to=collection.size -> int:
    return List.chunk_up from to (buffer_.size - buffer_fullness_) buffer_.size: | from to bytes |
      buffer_.replace buffer_fullness_ collection from to
      buffer_fullness_ += bytes
      if buffer_fullness_ == buffer_.size:
        send_ --last=false

  send_ --last:
    outgoing := buffer_
    length := buffer_fullness_ - BLOCK_HEADER_SIZE_
    outgoing[0] = last ? 1 : 0
    outgoing[1] = length & 0xff
    outgoing[2] = length >> 8
    outgoing[3] = outgoing[1] ^ 0xff
    outgoing[4] = outgoing[2] ^ 0xff
    channel_.send
      // Make a copy even if the buffer is full, since the reading end expects
      // to get a fresh byte array every time it calls read.
      outgoing.copy 0 buffer_fullness_
    summer_.add outgoing BLOCK_HEADER_SIZE_ length + BLOCK_HEADER_SIZE_
    buffer_ = last_buffer_
    last_buffer_ = outgoing
    buffer_fullness_ = 0

  close:
    send_ --last=true
    checksum_bytes := summer_.get
    channel_.send checksum_bytes
    channel_.send null

/**
Creates an uncompressed data stream that is compatible with zlib decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class UncompressedZlibEncoder extends UncompressedDeflateEncoder_:
  constructor:
    super crypto.Adler32 --gzip_header=false

/**
An 8 byte checksum that consists of the 4 byte CRC32 checksum followed by
  4 bytes representing the length mod 2**32 in little-endian order.  This is
  the checksum that gzip uses.
*/
class CrcAndLengthChecksum_ extends crypto.Checksum:
  crc_ := crypto.Crc32
  length_ := 0

  add collection from/int to/int -> none:
    crc_.add collection from to
    length_ += to - from

  get:
    crc := crc_.get
    result := ByteArray 8:
      it < 4 ?
        crc[it] :
        (length_ >> (8 * (it - 4))) & 0xff
    return result

/**
Creates an uncompressed data stream that is compatible with gzip decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class UncompressedGzipEncoder extends UncompressedDeflateEncoder_:
  constructor:
    super CrcAndLengthChecksum_ --gzip_header=true

class RunLengthDeflateEncoder_ extends ZlibEncoder_:
  buffer_ := ByteArray 256
  buffer_fullness_ := 0
  rle_ := rle_start_ resource_freeing_module_
  summer_/crypto.Checksum := ?

  constructor this.summer_ --gzip_header/bool:
    super --gzip_header=gzip_header

  write collection from=0 to=collection.size:
    summer_.add collection from to
    while to != from:
      // The buffer is 256 large, and we don't let it get too full because then the compressor
      // may not be able to make progress, so we flush it when we hit three quarters full.
      assert: buffer_.size == 256
      if buffer_fullness_ > 192:
        channel_.send (buffer_.copy 0 buffer_fullness_)
        buffer_fullness_ = 0
      result := rle_add_ rle_ buffer_ buffer_fullness_ collection from to
      written := result >> 15
      read := result & 0x7fff
      from += read
      buffer_fullness_ += written

  close:
    channel_.send (buffer_.copy 0 buffer_fullness_)
    written := rle_finish_ rle_ buffer_ 0
    channel_.send (buffer_.copy 0 written)
    channel_.send summer_.get
    channel_.send null

/**
Creates a run length encoded data stream that is compatible with zlib decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class RunLengthZlibEncoder extends RunLengthDeflateEncoder_:
  constructor:
    super crypto.Adler32 --gzip_header=false

/**
Creates a run length encoded data stream that is compatible with gzip decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class RunLengthGzipEncoder extends RunLengthDeflateEncoder_:
  constructor:
    super CrcAndLengthChecksum_ --gzip_header=true

rle_start_ group:
  #primitive.zlib.rle_start

/**
Compresses the bytes in source in the given range, and writes them into the
  destination starting at the index.  The return value, v, is an integer.
  The number of bytes read is v & 0x7fff, and the number of bytes written is
  v >> 15.
*/
rle_add_ rle destination index source from to:
  #primitive.zlib.rle_add

/// Returns the number of bytes written to terminate the zlib stream.
rle_finish_ rle destination index:
  #primitive.zlib.rle_finish
