// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import reader
import crypto
import crypto.adler32 as crypto
import crypto.crc as crc_algorithms

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
  crc_ := crc_algorithms.Crc32
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
    add_finalizer this::
      this.close

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

  /**
  Closes the encoder for writing.
  */
  close:
    channel_.send (buffer_.copy 0 buffer_fullness_)
    try:
      written := rle_finish_ rle_ buffer_ 0
      channel_.send (buffer_.copy 0 written)
      channel_.send summer_.get
      channel_.send null
    finally:
      remove_finalizer this

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

/**
Object that can be read to get output from an $Encoder or a $Decoder.
*/
class ZlibReader implements reader.Reader:
  owner_/Coder_? := null

  constructor.private_:

  /**
  Reads output data.
  In the default $wait mode this method may block in order to let a
    writing task write more data to the compressor or decompressor.
  In the non-blocking mode, if the compressor or decompressor has run out of
    input data, this method returns a zero length byte array.
  If the compressor or decompressor has been closed, and there is no more output
    data, this method returns null.
  */
  read --wait/bool=true -> ByteArray?:
    result := owner_.read_
    while result and wait and result.size == 0:
      yield
      result = owner_.read_
    return result

  close -> none:
    owner_.close_read_

// An Encoder or Decoder.
abstract class Coder_:
  zlib_ ::= ?
  closed_write_ := false
  closed_read_ := false

  constructor .zlib_:
    reader = ZlibReader.private_
    reader.owner_ = this
    add_finalizer this::
      this.uninit_

  /**
  Returns a reader that can be used to read the compressed or decompressed data
    output by the Encoder or Decoder.
  */
  reader/ZlibReader

  read_ -> ByteArray?:
    if closed_read_: return null
    return zlib_read_ zlib_

  close_read_ -> none:
    if not closed_read_:
      closed_read_ = true
      if closed_write_:
        uninit_

  /**
  Releases memory associated with this compressor.  This is called
    automatically when this object and the reader have both been closed.
  */
  uninit_ -> none:
    remove_finalizer this
    zlib_close_ zlib_

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
    super (zlib_init_deflate_ resource_freeing_module_ level)

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
    if not wait:
      return zlib_write_ zlib_ data
    pos := 0
    while pos < data.size:
      bytes_written := zlib_write_ zlib_ data[pos..]
      if bytes_written == 0:
        yield
      pos += bytes_written
    return pos

  /**
  Closes the encoder.  This will tell the encoder that no more input
    is coming.  Subsequent calls to the reader will return the buffered
    compressed data and then return null.
  */
  close -> none:
    if not closed_write_:
      zlib_close_ zlib_
      closed_write_ = true

/**
A Zlib decompressor/inflater.
Not usually supported on embedded platforms due to high memory use.
*/
class Decoder extends Coder_:
  /**
  Creates a new decompressor.
  */
  constructor:
    super (zlib_init_inflate_ resource_freeing_module_)

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
    if not wait:
      return zlib_write_ zlib_ data
    pos := 0
    while pos < data.size:
      bytes_written := zlib_write_ zlib_ data[pos..]
      if bytes_written == 0:
        yield
      pos += bytes_written
    return pos

  /**
  Closes the decoder.  This will tell the decoder that no more input
    is coming.  Subsequent calls to the reader will return the buffered
    decompressed data and then return null.
  */
  close -> none:
    if not closed_write_:
      zlib_close_ zlib_
      closed_write_ = true

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

zlib_init_deflate_ group level/int:
  #primitive.zlib.zlib_init_deflate

zlib_init_inflate_ group:
  #primitive.zlib.zlib_init_inflate

zlib_read_ zlib -> ByteArray?:
  #primitive.zlib.zlib_read

zlib_write_ zlib data -> int:
  #primitive.zlib.zlib_write

zlib_close_ zlib -> none:
  #primitive.zlib.zlib_close

zlib_uninit_ zlib -> none:
  #primitive.zlib.zlib_uninit
