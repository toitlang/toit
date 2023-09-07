// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import reader
import crypto
import crypto.adler32 as crypto
import crypto.crc as crc-algorithms

class CompressionReader implements reader.Reader:
  wrapped_ := null

  constructor.private_:

  read --wait/bool=true -> ByteArray?:
    return wrapped_.read_ --wait=wait

  close:
    wrapped_.close-read_

SMALL-BUFFER-DEFLATE-HEADER_ ::= [8, 0x1d]
MINIMAL-GZIP-HEADER_ ::= [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]

/**
Typically creates blocks of 256 bytes (5 bytes of block header, 251 bytes of
  uncompressed data) for a 2% size increase.  Adds a header and a checksum.
*/
class UncompressedDeflateBackEnd_ implements BackEnd_:
  summer_/crypto.Checksum? := ?  // When this is null, we are closed for write.
  buffer_/ByteArray? := ?        // When this is null, everything has been read.
  buffer-fullness_/int := ?
  position-of-block-header_/int := ?

  constructor .summer_ --gzip-header/bool:
    header := gzip-header ? MINIMAL-GZIP-HEADER_ : SMALL-BUFFER-DEFLATE-HEADER_
    buffer_ = ByteArray 256
    buffer_.replace 0 header
    buffer-fullness_ = header.size + BLOCK-HEADER-SIZE_
    position-of-block-header_ = header.size

  static BLOCK-HEADER-SIZE_ ::= 5

  write collection from=0 to=collection.size -> int:
    if not summer_: throw "ALREADY_CLOSED"
    length := min
        buffer_.size - buffer-fullness_
        to - from
    buffer_.replace buffer-fullness_ collection from (from + length)
    summer_.add collection from (from + length)
    buffer-fullness_ += length
    return length

  read -> ByteArray?:
    if not summer_:
      result := buffer_
      buffer_ = null
      return result
    if buffer-fullness_ != buffer_.size: return #[]  // Write more.
    result := buffer_
    buffer_ = ByteArray 256
    buffer-fullness_ = BLOCK-HEADER-SIZE_
    length := buffer_.size - BLOCK-HEADER-SIZE_ - position-of-block-header_
    fill-block-header_ result position-of-block-header_ length --last=false
    position-of-block-header_ = 0
    return result

  static fill-block-header_ byte-array/ByteArray position/int length/int --last/bool -> none:
    length-lo := length & 0xff
    length-hi := length >> 8
    byte-array[position] = last ? 1 : 0
    byte-array[position + 1] = length-lo
    byte-array[position + 2] = length-hi
    byte-array[position + 3] = length-lo ^ 0xff
    byte-array[position + 4] = length-hi ^ 0xff

  close:
    if summer_:
      checksum-bytes := summer_.get
      summer_ = null
      fill-block-header_ buffer_ position-of-block-header_
          buffer-fullness_ - BLOCK-HEADER-SIZE_ - position-of-block-header_
          --last
      buffer_ = buffer_[..buffer-fullness_] + checksum-bytes

/**
Creates an uncompressed data stream that is compatible with zlib decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class UncompressedZlibEncoder extends Coder_:
  constructor:
    super
        UncompressedDeflateBackEnd_ crypto.Adler32 --gzip-header=false

/**
An 8 byte checksum that consists of the 4 byte CRC32 checksum followed by
  4 bytes representing the length mod 2**32 in little-endian order.  This is
  the checksum that gzip uses.
*/
class CrcAndLengthChecksum_ extends crypto.Checksum:
  crc_ := crc-algorithms.Crc32
  length_ := 0

  constructor:

  constructor.private_ .length_ .crc_:

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

  clone -> CrcAndLengthChecksum_:
    return CrcAndLengthChecksum_.private_ length_ crc_.clone

/**
Creates an uncompressed data stream that is compatible with gzip decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class UncompressedGzipEncoder extends Coder_:
  constructor:
    super
        UncompressedDeflateBackEnd_ CrcAndLengthChecksum_ --gzip-header=true

class RunLengthDeflateBackEnd_ implements BackEnd_:
  summer_/crypto.Checksum := ?
  rle_ := rle-start_ resource-freeing-module_  // When this is null, we are closed for write.
  buffer_ := ByteArray 256                     // When this is null, everything has been read.
  buffer-fullness_ := 0

  constructor .summer_ --gzip-header/bool:
    buffer_ = ByteArray 256
    header := gzip-header ? MINIMAL-GZIP-HEADER_ : SMALL-BUFFER-DEFLATE-HEADER_
    buffer_.replace 0 header
    buffer-fullness_ = header.size
    add-finalizer this::
      this.close

  read -> ByteArray?:
    if not rle_:
      result := buffer_
      buffer_ = null
      return result

    if buffer-fullness_ < (buffer_.size >> 1):
      return #[]  // Not even half full, write more.

    result := buffer_.copy 0 buffer-fullness_
    buffer-fullness_ = 0
    return result

  write collection from=0 to=collection.size:
    if not rle_: throw "ALREADY_CLOSED"
    // The buffer is 256 large, and we don't let it get too full because then the compressor
    // may not be able to make progress, so we flush it when we hit three quarters full.
    assert: buffer_.size == 256
    if buffer-fullness_ > 192:
      return 0  // Read more.

    result := rle-add_ rle_ buffer_ buffer-fullness_ collection from to
    written := result >> 15
    read := result & 0x7fff
    assert: read != 0  // Not enough slack in the buffer.
    buffer-fullness_ += written
    summer_.add collection from from + read
    return read

  /**
  Closes the encoder for writing.
  */
  close:
    if rle_:
      buffer-fullness_ += rle-finish_ rle_ buffer_ buffer-fullness_
      rle_ = null
      checksum-bytes := summer_.get
      buffer_.replace buffer-fullness_ checksum-bytes
      buffer_ = buffer_[..buffer-fullness_ + checksum-bytes.size]

/**
Creates a run length encoded data stream that is compatible with zlib decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class RunLengthZlibEncoder extends Coder_:
  constructor:
    super
        RunLengthDeflateBackEnd_ crypto.Adler32 --gzip-header=false

/**
Creates a run length encoded data stream that is compatible with gzip decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class RunLengthGzipEncoder extends Coder_:
  constructor:
    super
        RunLengthDeflateBackEnd_ CrcAndLengthChecksum_ --gzip-header=true

/**
A compression/decompression implementation.
*/
interface BackEnd_:
  /// Returns null on end of file.
  /// Returns a zero length ByteArray if it needs a write operation.
  read -> ByteArray?
  /// Returns zero if it needs a read operation.
  write data from/int to/int -> int
  close -> none

class ZlibBackEnd_ implements BackEnd_:
  zlib_ ::= ?

  constructor .zlib_:

  read -> ByteArray?:
    return zlib-read_ zlib_

  write data from/int=0 to/int=data.size -> int:
    return zlib-write_ zlib_ data[from..to]

  close -> none:
    zlib-close_ zlib_

// An Encoder or Decoder.
abstract class Coder_:
  back_end_/BackEnd_
  closed-write_ := false
  closed-read_ := false
  signal_ /monitor.Signal := monitor.Signal
  state_/int := STATE-READY-TO-READ_ | STATE-READY-TO-WRITE_

  static STATE-READY-TO-READ_  ::= 1 << 0
  static STATE-READY-TO-WRITE_ ::= 1 << 1

  constructor .back_end_:
    reader = CompressionReader.private_
    reader.wrapped_ = this
    add-finalizer this::
      this.uninit_

  /**
  A reader that can be used to read the compressed or decompressed data output
    by the Encoder or Decoder.
  */
  reader/CompressionReader

  read_ --wait/bool -> ByteArray?:
    if closed-read_: return null
    result := back_end_.read
    while result and wait and result.size == 0:
      state_ &= ~STATE-READY-TO-READ_
      signal_.wait: state_ & STATE-READY-TO-READ_ != 0
      result = back_end_.read
    state_ |= STATE-READY-TO-WRITE_
    signal_.raise
    return result

  close-read_ -> none:
    if not closed-read_:
      closed-read_ = true
      if closed-write_:
        uninit_
      state_ |= STATE-READY-TO-WRITE_
      signal_.raise

  /**
  Writes data to the compressor or decompressor.
  If $wait is false, it may return before all data has been written.
    If it returns zero, then that means the read method must be called
    because the buffers are full.
  */
  write --wait/bool=true data from/int=0 to/int=data.size -> int:
    if closed-read_: throw "READER_CLOSED"
    pos := from
    while pos < to:
      bytes-written := back_end_.write data pos to
      if bytes-written == 0:
        if wait:
          state_ &= ~STATE-READY-TO-WRITE_
          signal_.wait: state_ & STATE-READY-TO-WRITE_ != 0
      else:
        state_ |= STATE-READY-TO-READ_
        signal_.raise
      if not wait: return bytes-written
      pos += bytes-written
    return pos - from

  close -> none:
    if not closed-write_:
      back_end_.close
      closed-write_ = true
      state_ |= Coder_.STATE-READY-TO-READ_
      signal_.raise

  /**
  Releases memory associated with this compressor.  This is called
    automatically when this object and the reader have both been closed.
  */
  uninit_ -> none:
    remove-finalizer this
    back_end_.close

/**
A Zlib compressor/deflater.
Not usually supported on embedded platforms due to high memory use.
*/
class Encoder extends Coder_:
  /**
  Creates a new compressor.
  The compression level can be -1 for default, 0 for no compression, or 1-9 for
    compression levels 1-9.
  */
  constructor --level/int=-1:
    if not -1 <= level <= 9: throw "ILLEGAL_ARGUMENT"
    super
        ZlibBackEnd_ (zlib-init-deflate_ resource-freeing-module_ level)

  /**
  Writes uncompressed data into the compressor.
  In the default $wait mode this method may block and will not return
    until all bytes have been written to the compressor.
  Returns the number of bytes that were compressed.  If zero bytes were
    compressed that means that data needs to be read using the reader before
    more data can be accepted.
  Any bytes that were not compressed need to be resubmitted to this method
    later.
  */
  write --wait/bool=true data -> int:
    return super --wait=wait data

  /**
  Closes the encoder.
  This tells the encoder that no more uncompressed input is coming.  Subsequent
    calls to the reader will return the buffered compressed data and then
    return null.
  */
  close -> none:
    super

/**
A Zlib decompressor/inflater.
Not usually supported on embedded platforms due to high memory use.
*/
class Decoder extends Coder_:
  /**
  Creates a new decompressor.
  */
  constructor:
    super
        ZlibBackEnd_ (zlib-init-inflate_ resource-freeing-module_)

  /**
  Writes compressed data into the decompressor.
  In the default $wait mode this method may block and will not return
    until all bytes have been written to the decompressor.
  Returns the number of bytes that were decompressed.  If zero bytes were
    decompressed that means that data needs to be read using the reader before
    more data can be accepted.
  Any bytes that were not decompressed need to be resubmitted to this method
    later.
  */
  write --wait/bool=true data -> int:
    return super --wait=wait data

  /**
  Closes the decoder.
  This will tell the decoder that no more compressed input is coming.
    Subsequent calls to the reader will return the buffered decompressed data
    and then return null.
  */
  close -> none:
    super

rle-start_ group:
  #primitive.zlib.rle-start

/**
Compresses the bytes in source in the given range, and writes them into the
  destination starting at the index.  The return value, v, is an integer.
  The number of bytes read is v & 0x7fff, and the number of bytes written is
  v >> 15.
*/
rle-add_ rle destination index source from to:
  #primitive.zlib.rle-add

/// Returns the number of bytes written to terminate the zlib stream.
rle-finish_ rle destination index:
  #primitive.zlib.rle-finish

zlib-init-deflate_ group level/int:
  #primitive.zlib.zlib-init-deflate

zlib-init-inflate_ group:
  #primitive.zlib.zlib-init-inflate

zlib-read_ zlib -> ByteArray?:
  #primitive.zlib.zlib-read

zlib-write_ zlib data -> int:
  #primitive.zlib.zlib-write

zlib-close_ zlib -> none:
  #primitive.zlib.zlib-close

zlib-uninit_ zlib -> none:
  #primitive.zlib.zlib-uninit
