// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import crypto
import crypto.adler32
import crypto.crc as crc-algorithms
import expect show *
import .io as io
import .io show LITTLE-ENDIAN

SMALL-BUFFER-DEFLATE-HEADER_ ::= #[8, 0x1d]
MINIMAL-GZIP-HEADER_ ::= #[0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]

/**
An extension of the $io.Writer interface that improves the
  $io.Writer.wait-for-more-room_ method.
*/
class CompressionWriter_ extends io.CloseableWriter:
  coder_/Coder_

  constructor.private_ .coder_:

  wait-for-more-room_:
    coder_.wait-for-more-room_

  try-write_ data/io.Data from/int to/int -> int:
    return coder_.try-write_ data from to

  close_:
    coder_.close-writer_

/**
An $io.CloseableReader that supports '--no-wait' for the $read method.

In that case the result might be an empty byte-array, indicating that more
  data needs to be fed into the encoder.
*/
class CompressionReader extends io.CloseableReader:
  coder_/Coder_

  constructor.private_ .coder_:

  read --max-size/int?=null --wait/bool=true -> ByteArray?:
    // It's important that all non-empty byte arrays go through the
    // normal read method, as this affects the $io.Reader.processed count.
    if wait or buffered-size != 0 or not coder_.backend-needs-input_:
      return super --max-size=max-size

    if is-closed_: return null
    return #[]

  read_ -> ByteArray?:
    return coder_.read_

  close_ -> none:
    coder_.close-reader_

/**
Typically creates blocks of 256 bytes (5 bytes of block header, 251 bytes of
  uncompressed data) for a 2% size increase.  Adds a header and a checksum.
*/
class UncompressedDeflateBackend_ implements Backend_:
  summer_/crypto.Checksum? := ?  // When this is null, we are closed for write.
  buffer_/ByteArray? := ?        // When this is null, everything has been read.
  buffer-fullness_/int := ?
  position-of-block-header_/int := ?
  split-writes/bool

  constructor .summer_ --gzip-header/bool --.split-writes:
    header := gzip-header ? MINIMAL-GZIP-HEADER_ : SMALL-BUFFER-DEFLATE-HEADER_
    buffer-fullness_ = header.size + BLOCK-HEADER-SIZE_
    buffer_ = ByteArray (split-writes ? 256 : 64)
    buffer_.replace 0 header
    position-of-block-header_ = header.size

  static BLOCK-HEADER-SIZE_ ::= 5

  write data/io.Data from=0 to=data.byte-size -> int:
    if not summer_: throw "ALREADY_CLOSED"
    if buffer-fullness_ == buffer_.size:
      return 0  // Read more.
    if split-writes or to - from <= buffer_.size - buffer-fullness_:
      length := min
          buffer_.size - buffer-fullness_
          to - from
      buffer_.replace buffer-fullness_ data from (from + length)
      summer_.add data from (from + length)
      buffer-fullness_ += length
      return length
    else:
      // Construct a new buffer that can hold the whole write.
      new-buffer := ByteArray buffer-fullness_ + (to - from)
      new-buffer.replace 0 buffer_ 0 buffer-fullness_
      data.write-to-byte-array new-buffer --at=buffer-fullness_ from to
      buffer_ = new-buffer
      summer_.add data from to
      buffer-fullness_ = buffer_.size
      return to - from

  read -> ByteArray?:
    if not summer_:
      result := buffer_
      buffer_ = null
      return result
    if buffer-fullness_ != buffer_.size: return #[]  // Write more.
    result := buffer_
    length := buffer_.size - BLOCK-HEADER-SIZE_ - position-of-block-header_

    fill-block-header_ result position-of-block-header_ length --last=false
    buffer_ = ByteArray (split-writes ? 256 : 64)
    buffer-fullness_ = BLOCK-HEADER-SIZE_
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
  /**
  Normally the literal blocks in the output will bear no relation
    to the write operations on this encoder.  This reduces peak
    memory use.  However, if $split-writes is true then a single
    write operation will never span two blocks.
  */
  constructor --split-writes/bool=true:
    super
        UncompressedDeflateBackend_ adler32.Adler32 --gzip-header=false --split-writes=split-writes

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

  add data/io.Data from/int to/int -> none:
    crc_.add data from to
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
        UncompressedDeflateBackend_ CrcAndLengthChecksum_ --gzip-header --split-writes

class RunLengthDeflateBackend_ implements Backend_:
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

  write data/io.Data from/int=0 to/int=data.byte-size:
    if not rle_: throw "ALREADY_CLOSED"
    // The buffer is 256 large, and we don't let it get too full because then the compressor
    // may not be able to make progress, so we flush it when we hit three quarters full.
    assert: buffer_.size == 256
    if buffer-fullness_ > 192:
      return 0  // Read more.

    result := rle-add_ rle_ buffer_ buffer-fullness_ data from to
    written := result >> 15
    read := result & 0x7fff
    assert: read != 0  // Not enough slack in the buffer.
    buffer-fullness_ += written
    summer_.add data from from + read
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
        RunLengthDeflateBackend_ adler32.Adler32 --gzip-header=false

/**
Creates a run length encoded data stream that is compatible with gzip decoders
  expecting compressed data.  This has a write and a read method, which should
  be used from different tasks to prevent deadlocks.
*/
class RunLengthGzipEncoder extends Coder_:
  constructor:
    super
        RunLengthDeflateBackend_ CrcAndLengthChecksum_ --gzip-header

/**
A compression/decompression implementation.
*/
interface Backend_:
  /// Returns null on end of file.
  /// Returns a zero length ByteArray if it needs a write operation.
  read -> ByteArray?

  /// Returns zero if it needs a read operation.
  write data from/int to/int -> int
  close -> none

class ZlibBackend_ implements Backend_:
  zlib_ ::= ?

  constructor .zlib_:

  read -> ByteArray?:
    return zlib-read_ zlib_

  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    return zlib-write_ zlib_ (data.byte-slice from to)

  close -> none:
    zlib-close_ zlib_

// An Encoder or Decoder.
abstract class Coder_:
  backend_/Backend_
  signal_ /monitor.Signal := monitor.Signal
  state_/int := STATE-READY-TO-READ_ | STATE-READY-TO-WRITE_
  in_/CompressionReader? := null
  out_/CompressionWriter_? := null
  /**
  A temporarily buffered byte-array.
  */
  buffered_/ByteArray? := null

  static STATE-READY-TO-READ_  ::= 1 << 0
  static STATE-READY-TO-WRITE_ ::= 1 << 1

  constructor .backend_:
    add-finalizer this::
      this.uninit_

  /**
  A reader that can be used to read the compressed or decompressed data output
    by the Encoder or Decoder.

  By default the $CompressionReader blocks until there is data available.
  Use $CompressionReader.read with the '--wait' flag set to false to get an empty
    ByteArray when the buffers are empty, and a call to the write method is
    needed.
  */
  in -> CompressionReader:
    if not in_: in_ = CompressionReader.private_ this
    return in_

  /**
  Deprecated. Use $in instead.
  */
  reader -> CompressionReader:
    return in

  /**
  A writer that can be used to write data to the Encoder or Decoder.

  If the writers $io.Writer.try-write returns 0, then that means that the
    read method must be called because the buffers are full.
  */
  out -> io.CloseableWriter:
    if not out_: out_ = CompressionWriter_.private_ this
    return out_

  read_ -> ByteArray?:
    if buffered_:
      result := buffered_
      buffered_ = null
      return result
    result := backend_.read
    while result and result.size == 0:
      wait-for-more-data_
      result = backend_.read
    return result

  /**
  Whether the backend needs more input.

  This is done by asking the backend and then, potentially, storing the
    returned data in this instance.
  */
  backend-needs-input_ -> bool:
    assert: not buffered_
    data := backend_.read
    if not data:
      // The backend is closed.
      return false
    if data.size != 0:
      buffered_ = data
      // Data is available.
      return false
    // No data. The backend needs input.
    return true

  close-reader_ -> none:
    if out.is-closed:
      uninit_
    state_ |= STATE-READY-TO-WRITE_
    signal_.raise

  /**
  Writes data to the compressor or decompressor.
  If $wait is false, it may return before all data has been written.
    If it returns zero, then that means the read method must be called
    because the buffers are full.

  Deprecated. Use out.try-write or out.write instead.
  */
  write --wait/bool=true data/io.Data from/int=0 to/int=data.byte-size -> int:
    if not wait: return try-write_ data from to
    pos := from
    while pos < to:
      bytes-written := try-write_ data pos to
      if bytes-written == 0: wait-for-more-room_
      pos += bytes-written
    return to - from

  try-write_ data/io.Data from/int to/int -> int:
    if in.is-closed: throw "READER_CLOSED"
    return backend_.write data from to

  wait-for-more-room_:
    state_ &= ~STATE-READY-TO-WRITE_
    state_ |= STATE-READY-TO-READ_
    signal_.raise
    signal_.wait: state_ & STATE-READY-TO-WRITE_ != 0

  wait-for-more-data_:
    state_ &= ~STATE-READY-TO-READ_
    state_ |= STATE-READY-TO-WRITE_
    signal_.raise
    signal_.wait: state_ & STATE-READY-TO-READ_ != 0

  /**
  Closes the writer.

  Deprecated. Use out.close instead.
  */
  // TODO(florian): this should close in and out and uninit.
  close -> none:
    close-writer_

  close-writer_:
    backend_.close
    state_ |= STATE-READY-TO-READ_
    signal_.raise

  /**
  Releases memory associated with this compressor.  This is called
    automatically when this object and the reader have both been closed.
  */
  uninit_ -> none:
    remove-finalizer this
    backend_.close

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
        ZlibBackend_ (zlib-init-deflate_ resource-freeing-module_ level)

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
        ZlibBackend_ (zlib-init-inflate_ resource-freeing-module_)

/**
A utility class for the pure Toit DEFLATE Inflater (zlib decompresser).
This implementation holds on to copies of the buffers that are delivered with
  the read method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements, but it may use some memory.
*/
class CopyingHistory_ extends BufferingHistory_:
  record result/ByteArray:
    super result.copy

/**
A utility class for the pure Toit DEFLATE Inflater (zlib decompresser).
This implementation holds on to the buffers that are delivered with the read
  method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements, but it means the user may not overwrite the buffers,
  and it can use some memory.  May return the same byte arrays several times,
  or slices of the same byte arrays.
*/
class BufferingHistory_ implements InflateHistory:
  // Previous byte arrays that have been returned.
  previous_/List? := []
  // Number of bytes we have buffered.
  buffered_ := 0
  window-size/int := 32768

  record result/ByteArray -> none:
    result-size := result.size
    if result-size == 0:
      return
    previous-size := previous_.size
    if previous-size > 0 and result-size < 32 and previous_[previous-size - 1].size < 32:
      previous_[previous-size - 1] += result
    else:
      previous_.add result
    buffered_ += result-size
    while buffered_ > window-size and buffered_ - previous_[0].size > window-size:
      buffered_ -= previous_[0].size
      previous_ = previous_.copy 1

  look-back distance/int [block]:
    if distance > buffered_:
      throw "Corrupt data"
    start := previous_.size - 1
    while distance > previous_[start].size:
      distance -= previous_[start].size
      start--
    ba := previous_[start]
    block.call ba (ba.size - distance)

interface InflateHistory:
  /**
  Records a byte array that has been decompressed, and is about to be returned
    from the read method.
  */
  record ByteArray -> none
  /**
  The block should be called with a ByteArray and an offset where the required
    data starts.  The distance is measured in bytes, backwards from the last
    data returned by the read method.
  */
  look-back distance/int [block] -> none
  /**
  The maximum size of the look-back window.  Can be implemented with a public
    field instead of a getter and a setter.
  */
  window-size= bytes/int
  window-size -> int

/**
A pure Toit DEFLATE Inflater (zlib decompresser).
This implementation holds on to the byte arrays that are delivered with the read
  method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements, but it means the user may not overwrite the byte arrays,
  and it can use some memory.  May return the same byte arrays several times,
  or slices of the same byte arrays.
*/
class BufferingInflater extends Coder_:
  /**
  If a reduced window size (look-behind distance) is set here, then that is the
    maximum size that will be buffered.  The zlib header may specify an even
    smaller window size, but will be ignored if it specifies a larger window
    size.
  */
  constructor --window-size/int=32768 --zlib-header/bool=true:
    history := BufferingHistory_
    history.window-size = window-size
    super
        InflaterBackend history --zlib-header-footer=zlib-header

/**
A pure Toit DEFLATE Inflater (zlib decompresser).
This implementation holds on to copies of the byte arrays that are delivered with
  the read method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements, but it may use some memory.
*/
class CopyingInflater extends Coder_:
  /**
  If a reduced window size (look-behind distance) is set here, then that is the
    maximum size that will be buffered.  The zlib header may specify an even
    smaller window size, but will be ignored if it specifies a larger window
    size.
  */
  constructor --window-size/int=32768 --zlib-header/bool=true:
    history := CopyingHistory_
    history.window-size = window-size
    super
        InflaterBackend history --zlib-header-footer=zlib-header

/**
A pure Toit DEFLATE Inflater (zlib decompresser).
To use this implementation, you must supply an $InflateHistory object to help
  decompress, by remembering previously decompressed data.  For example, if
  the decompressed data is being written into flash, that $InflateHistory object
  could find the data in flash.
*/
class Inflater extends Coder_:
  /**
  If a reduced window size (look-behind distance) is set here, then that is the
    maximum size that will be buffered.  The zlib header may specify an even
    smaller window size, but will be ignored if it specifies a larger window
    size.
  */
  constructor history/InflateHistory --window-size/int=32768 --zlib-header/bool=true:
    history.window-size = window-size
    super
        InflaterBackend history --zlib-header-footer=zlib-header

/**
A pure Toit decompressing backend for the DEFLATE format.
You would normally use $BufferingInflater, $CopyingInflater or $Inflater
  which wrap this class in a more convenient API.
This class needs an $InflateHistory object to help it look back in up to
  32k of previously decompressed data (or whatever size the compressor was
  set to).
Does not currently support streams with a gzip header (as opposed to the
  zlib header).
*/
class InflaterBackend implements Backend_:
  history_/InflateHistory
  adler_/adler32.Adler32? := null
  buffer_/ByteArray := #[]
  buffer-pos_/int := 0
  valid-bits_/int := 0
  data_/int := 0
  in-final-block_ := false
  counter_/int := 0
  // List of SymbolBitLen_ objects we are building up.
  lengths_/List? := null
  // Bits we are waiting for.
  pending-bits_/int := 0
  hlit_/int := 0
  hdist_/int := 0
  state_/int := INITIAL_
  meta-table_/HuffmanTables_? := null
  symbol-and-length-table_/HuffmanTables_? := null
  distance-table_/HuffmanTables_? := null
  output-buffer_/ByteArray := ByteArray 256
  output-buffer-position_/int := 0  // Always less than the size.
  copy-length_ := 0  // Number of bytes to copy.
  copy-distance_ := 0  // Distance to copy from.

  static FIXED-SYMBOL-AND-LENGTH_ ::= create-fixed-symbol-and-length_
  static FIXED-DISTANCE_ ::= create-fixed-distance_

  static ZLIB-HEADER_         ::= -2 // Reading zlib header.
  static ZLIB-FOOTER_         ::= -1 // Reading Adler checksum.
  static INITIAL_             ::= 0  // Reading initial 3 bits of block.
  static NO-COMPRESSION_      ::= 2  // Reading 4 bytes of LEN and NLEN.
  static NO-COMPRESSION-BODY_ ::= 3  // Reading counter_ bytes of data.
  static GET-TABLE-SIZES_     ::= 4  // Reading HLIT, HDIST and HCLEN.
  static GET-HCLEN_           ::= 5  // Reading n x 3 bits of HLIT.
  static GET-HLIT-AND-HDIST_  ::= 6  // Reading bit lengths for HLIT and HDIST tables.
  static DECOMPRESSING_       ::= 7  // Decompressing data.

  constructor .history_ --zlib-header-footer/bool=true:
    if zlib-header-footer:
      state_ = ZLIB-HEADER_
      adler_ = adler32.Adler32
    else:
      state_ = INITIAL_

  // Returns the next data.
  // Returns an empty byte array if we need more input.
  // Returns null if there is no more data.
  read -> ByteArray?:
    get-pending-bits :=:
      if pending-bits_ > 0:
        bits := n-bits_ pending-bits_
        if bits < 0: return NEED-MORE-DATA_
        pending-bits_ = 0
        bits  // Result of block.
      else:
        0

    while true:
      if state_ == ZLIB-HEADER_:
        header := n-bits_ 16
        if header < 0: return NEED-MORE-DATA_
        if header & 0xf != 8: throw "header=$(%04x header) Not a deflate stream"
        window-size := 1 << (8 + ((header & 0xf0) >> 4))
        if window-size < history_.window-size:
          history_.window-size = window-size
        if header & 0x2000 != 0: throw "Preset dictionary not supported"
        big-endian := header >> 8 + ((header & 0xff) << 8)
        if big-endian % 31 != 0: throw "Corrupt data"
        state_ = INITIAL_

      else if state_ == ZLIB-FOOTER_:
        n-bits_ (valid-bits_ & 7)  // Discard rest of byte.
        adler32 := n-bits_ 32
        if adler32 < 0: return NEED-MORE-DATA_
        calculated := LITTLE-ENDIAN.uint32 adler_.get 0
        adler_ = null  // Only read the checksum once.
        if calculated != adler32: throw "Checksum mismatch"
        state_ = INITIAL_
        return null

      else if state_ == INITIAL_:
        if in-final-block_:
          // We are after the final block.
          if output-buffer-position_ != 0:
            return flush-output-buffer_ output-buffer-position_
          if adler_:
            state_ = ZLIB-FOOTER_
          else:
            return null
        else:
          raw := n-bits_ 3
          if raw < 0: return NEED-MORE-DATA_
          in-final-block_ = (raw & 1) == 1
          type := raw >> 1
          if type == 0:
            // No compression.
            n-bits_ (valid-bits_ & 7)  // Discard rest of byte.
            state_ = NO-COMPRESSION_
          else if type == 1:
            // Fixed Huffman tables.
            symbol-and-length-table_ = FIXED-SYMBOL-AND-LENGTH_
            distance-table_ = FIXED-DISTANCE_
            state_ = DECOMPRESSING_
          else if type == 2:
            // Dynamic Huffman tables.
            state_ = GET-TABLE-SIZES_
          else:
            throw "Corrupt data"

      else if state_ == NO-COMPRESSION_:
        if output-buffer-position_ != 0:
          return flush-output-buffer_ output-buffer-position_
        len-nlen := n-bits_ 32
        if len-nlen < 0: return NEED-MORE-DATA_
        counter_ = len-nlen & 0xffff
        complement := len-nlen >> 16
        if counter_ ^ 0xffff != complement:
          throw "Corrupt data"
        state_ = NO-COMPRESSION-BODY_

      else if state_ == NO-COMPRESSION-BODY_:
        if counter_ == 0:
          state_ = INITIAL_
        else:
          if valid-bits_ >= 8:
            counter_--
            result := #[n-bits_ 8]
            return record_ result
          if buffer-pos_ < buffer_.size:
            length := min
                counter_
                buffer_.size - buffer-pos_
            result := buffer_[buffer-pos_..buffer-pos_ + length]
            counter_ -= length
            buffer-pos_ += length
            return record_ result
          return NEED-MORE-DATA_

      else if state_ == GET-TABLE-SIZES_:
        raw := n-bits_ 14
        if raw < 0: return NEED-MORE-DATA_
        hlit_ = (raw & 0x1f) + 257
        hdist_ = ((raw >> 5) & 0x1f) + 1
        hclen := (raw >> 10) + 4
        lengths_ = List hclen
        counter_ = 0
        state_ = GET-HCLEN_

      else if state_ == GET-HCLEN_:
        while counter_ < lengths_.size:
          length-code := n-bits_ 3
          if length-code < 0: return NEED-MORE-DATA_
          lengths_[counter_] = SymbolBitLen_ HCLEN-ORDER_[counter_] length-code
          counter_++
        meta-table_ = HuffmanTables_ lengths_
        counter_ = 0
        lengths_ = List (hlit_ + hdist_)
        state_ = GET-HLIT-AND-HDIST_

      else if state_ == GET-HLIT-AND-HDIST_:
        add-symbol := :: | last |
          symbol := counter_ < hlit_ ? counter_ : counter_ - hlit_
          lengths_[counter_] = SymbolBitLen_ symbol last
          counter_++

        extra-repeats := get-pending-bits.call
        if extra-repeats != 0:
          last := lengths_[counter_ - 1].bit-len
          extra-repeats.repeat: add-symbol.call last
        if counter_ != lengths_.size:
          length-code := next_ meta-table_
          if length-code < 0: return NEED-MORE-DATA_
          if length-code < 16:
            add-symbol.call length-code
          else:
            last := 0
            repeats := 3
            if length-code == 16:
              last = lengths_[counter_ - 1].bit-len
              pending-bits_ = 2
            else if length-code == 17:
              pending-bits_ = 3
            else:
              assert: length-code == 18
              pending-bits_ = 7
              repeats = 11
            (min repeats (lengths_.size - counter_)).repeat:
              add-symbol.call last
        if counter_ == lengths_.size:
          get-pending-bits.call  // Discard any pending bits.
          symbol-and-length-table_ = HuffmanTables_ lengths_[..hlit_]
          distance-table_ = HuffmanTables_ lengths_[hlit_..]
          meta-table_ = null  // Don't need this any more.
          lengths_ = null  // Or this.
          counter_ = 0
          state_ = DECOMPRESSING_

      else if state_ == DECOMPRESSING_:
        if copy-length_ == 0:
          symbol := next_ symbol-and-length-table_
          if symbol < 0: return NEED-MORE-DATA_
          if symbol == 256:
            state_ = INITIAL_
          else if symbol <= 255:
            output-buffer_[output-buffer-position_++] = symbol
            if output-buffer-position_ == output-buffer_.size:
              return flush-output-buffer_ output-buffer-position_
          else:
            copy-distance_ = 0
            if symbol < 265:
              copy-length_ = symbol - 254
            else if symbol < 285:
              copy-length_ = LENGTHS_[symbol - 257]
              pending-bits_ = "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x01\x01\x01\x02\x02\x02\x02\x03\x03\x03\x03\x04\x04\x04\x04\x05\x05\x05\x05"[symbol - 257]

            else:
              assert: symbol == 285
              copy-length_ = 258
        if copy-length_ != 0:
          if copy-distance_ == 0:
            copy-length_ += get-pending-bits.call
            symbol := next_ distance-table_
            if symbol < 0: return NEED-MORE-DATA_
            pending-bits_ = "\x00\x00\x00\x00\x01\x01\x02\x02\x03\x03\x04\x04\x05\x05\x06\x06\x07\x07\x08\x08\x09\x09\x0a\x0a\x0b\x0b\x0c\x0c\x0d\x0d"[symbol]
            copy-distance_ = DISTANCES_[symbol]
          copy-distance_ += get-pending-bits.call
          // We have a copy length and distance.
          // If some of the copy length is before the current output buffer,
          // we have to use the look-back method.
          pos := output-buffer-position_
          while copy-length_ > 0 and copy-distance_ > pos:
            history_.look-back copy-distance_ - pos: | byte-array/ByteArray offset/int |
              available := min
                  copy-length_
                  byte-array.size - offset
              copyable := min
                  available
                  output-buffer_.size - pos
              if pos == 0 and copyable > 32:
                copy-length_ -= available
                result := byte-array[offset..offset + copyable]
                output-buffer-position_ = pos
                return record_ result
              output-buffer_.replace pos byte-array offset (offset + copyable)
              pos += copyable
              copy-length_ -= copyable
              if pos == output-buffer_.size:
                return flush-output-buffer_ pos
          // Copy from the current output buffer.
          // Replace uses memmove semantics, which means it can't be used to do
          // the DEFLATE semantics of making repeated patterns.
          while copy-length_ > 0:
            space := output-buffer_.size - pos
            want := min
                space
                copy-length_
            copyable := min
                want
                copy-distance_  // Limit because of memmove semantics.
            if copyable < 8 and want > 32:
              // More efficient to use a byte loop than repeated calls to replace.
              from := pos - copy-distance_
              to := pos
              want.repeat:
                output-buffer_[to + it] = output-buffer_[from + it]
              pos += want
              copy-length_ -= want
            else:
              // More efficient to use replace.
              offset := pos - copy-distance_
              output-buffer_.replace pos output-buffer_ offset (offset + copyable)
              pos += copyable
              copy-length_ -= copyable
            if pos == output-buffer_.size:
              return flush-output-buffer_ pos
          output-buffer-position_ = pos

  // Records a byte array that has been decompressed.
  // Returns the byte array.
  record_ result/ByteArray -> ByteArray:
    if adler_: adler_.add result
    history_.record result
    return result

  flush-output-buffer_ pos/int -> ByteArray:
    if pos == output-buffer_.size:
      result := output-buffer_
      output-buffer_ = ByteArray 256
      output-buffer-position_ = 0
      return record_ result
    result := output-buffer_.copy 0 pos
    output-buffer-position_ = 0
    return record_ result

  static DISTANCES_ ::= [
      1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
      257, 385, 513, 769, 1025, 1537, 2049, 3073,
      4097, 6145, 8193, 12289, 16385, 24577
  ]

  static LENGTHS_ ::= #[
      3, 4, 5, 6, 7, 8, 9, 10, 11, 13,
      15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
      67, 83, 99, 115, 131, 163, 195, 227,
  ]

  static HCLEN-ORDER_ ::= #[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

  static NEED-MORE-DATA_ ::= #[]

  /**
  Writes a new byte array to the decompressor.
  */
  write buffer/ByteArray from/int=0 to/int=buffer.size -> int:
    if buffer-pos_ != buffer_.size:
      return 0
    buffer_ = buffer[..to]
    buffer-pos_ = from
    return to - from

  /**
  Returns the input data that was not used, only whole bytes.
  */
  rest -> ByteArray:
    assert: valid-bits_ == 0 or valid-bits_ == 8
    if valid-bits_ == 8:
      return #[data_] + buffer_[buffer-pos_..]
    return buffer_[buffer-pos_..]

  close:

  // Gets next symbol or -1 if we need more data.
  next_ tables/HuffmanTables_ -> int:
    while true:
      value := tables.first-level[data_ & 0xff]
      if value < 0:
        // Look in L2.
        value = tables.second-level[(value >> 8) & 0xff][(data_ >> (value & 0xf)) & 0xff]
      bits := value & 0xf
      if bits <= valid-bits_:
        valid-bits_ -= bits
        data_ >>= bits
        return value >> 4

      if buffer-pos_ == buffer_.size:
        return -1
      data_ |= buffer_[buffer-pos_++] << valid-bits_
      valid-bits_ += 8

  // Gets next n bits of data or -1 if we need more data.
  n-bits_ bits/int -> int:
    while valid-bits_ < bits:
      if buffer-pos_ == buffer_.size:
        return -1
      data_ |= buffer_[buffer-pos_++] << valid-bits_
      valid-bits_ += 8
    result := data_ & ((1 << bits) - 1)
    data_ >>= bits
    valid-bits_ -= bits
    return result

// Used for pure Toit inflater.
class SymbolBitLen_:
  symbol/int
  bit-len/int
  encoding/int? := null

  constructor .symbol .bit-len:

  stringify:
    enc-string := "null"
    if encoding:
      enc-string = string.format "0$(bit-len)b" encoding
    return "SymbolBitLen_($symbol, len=$bit-len) encoding=$enc-string"

// Used for the second level lookup in the pure Toit inflater.
class L2_:
  symbols/List := []
  max-bit-len/int := ?

  constructor sbl/SymbolBitLen_:
    symbols.add sbl
    max-bit-len = sbl.bit-len

  add sbl/SymbolBitLen_:
    symbols.add sbl
    // Symbols are added in increasing bit length order.
    assert: max-bit-len <= sbl.bit-len
    max-bit-len = sbl.bit-len

class HuffmanTables_:
  // A regular entry of in the first level or one of the second level
  // lookup tables consists of a symbol shifted left by 4 bits.  The
  // low 4 bits contain the bit length of the code that fits that
  // symbol.

  // A list of 256 ints as described above.
  // If an entry is negative, it is a reference to a second level table.
  // Index is a byte of raw input, ie with the Huffman codes reversed.
  first-level/List

  // A list of lists of 256 ints as described above.  Entries in the first
  // level may refer to an entry in one of these lists.
  second-level/List

  // Takes a list of SymbolBitLen_ objects, and creates the tables.
  constructor bitlens/List:
    bitlens = bitlens.sort: | a b |
      a.bit-len.compare-to b.bit-len --if-equal=:
        a.symbol - b.symbol
    list := List 256
    counter := 0
    bit-len := 0
    bitlens.do: | sbl/SymbolBitLen_ |
      if sbl.bit-len > 0:
        if sbl.bit-len > bit-len:
          counter = counter << (sbl.bit-len - bit-len)
          bit-len = sbl.bit-len
        sbl.encoding = counter
        if bit-len <= 8:
          copies := 1 << (8 - bit-len)
          idx := counter << (8 - bit-len)
          value := sbl.bit-len | (sbl.symbol << 4)
          copies.repeat:
            list[idx++] = value
        else:
          idx := counter >> (bit-len - 8)
          if list[idx] == null:
            list[idx] = L2_ sbl
          else:
            list[idx].add sbl
        counter++

    // All the codes that are less than 8 bits long are in the list.  Some of
    // the shorter ones are there more than once, eg. the 7 bit codes are
    // there twice so they match regardless of whether they are followed by a
    // 0 or a 1.

    // The codes that are 9 bits or longer have been put in L2_
    // objects, indexed by the first 8 bits of the code.

    // We can merge the L2_ objects so that we don't need so many tables to
    // represent them.  Two L2_ tables can be merged if the encoding has the
    // same prefix, and if throwing away the prefix leaves less than 8 bits
    // (the level two tables will also be 256 long).  We do that from the end
    // because the long codes are guaranteed to be at the end with this
    // construction method.  They are indexed by the first 8 bits of the
    // encoding.
    current/L2_? := null
    surviving-l2s := []
    for i := 255; i >= 0; i--:
      if list[i] is int or list[i] == null:
        continue
      l2 := list[i] as L2_
      if current == null:
        current = l2
        surviving-l2s.add current
        continue
      d := current.max-bit-len - 8  // How many of the first 8 bits to discard.
      // We can merge if the discarded index bits are the same.  We will be
      // discarding the high bits of the encoding (low bits after reversal).
      if i >> (8 - d) == (i + 1 >> (8 - d)):
        current.symbols.add-all l2.symbols
        list[i] = current
        continue
      // Can't merge, start a new one.
      current = l2
      surviving-l2s.add current

    // Set up the first 256 entries that are for codes <= 8 bits and contain
    // references to the other entries.
    first-level =  List 256
    second-level = List surviving-l2s.size: List 256
    256.repeat: | i |
      entry := list[i]
      if entry is int:
        first-level[REVERSED_[i]] = entry
      else if entry:
        l2 := entry as L2_
        l2-index := surviving-l2s.index-of entry
        // Negative value in the first level table: Discard some bits and look
        // in a second level table.  Low byte indicates which level two table
        // to look in.  Next byte indicates how many bits to discard before doing
        // the level 2 lookup.
        value := (l2.max-bit-len - 8) | (l2-index << 8)
        first-level[REVERSED_[i]] = 0xffff_ffff_ffff_0000 | value
    // Set up the level two tables later in the list.
    for l2-index := 0; l2-index < surviving-l2s.size; l2-index++:
      l2/L2_ := surviving-l2s[l2-index]
      discard := l2.max-bit-len - 8
      l2.symbols.do: | sbl/SymbolBitLen_ |
        value := sbl.bit-len | (sbl.symbol << 4)
        step := 1 << (sbl.bit-len - discard)
        for i := (reverse_ sbl.encoding sbl.bit-len) >> discard; i < 256; i += step:
          second-level[l2-index][i] = value

reverse_ n/int bits/int:
  if bits <= 8:
    return REVERSED_[n << (8 - bits)]
  assert: bits <= 15
  return ((reverse_ (n & 0xff) 8) << (bits - 8)) | (reverse_ (n >> 8) (bits - 8))

REVERSED_ ::= ByteArray 0x100: 0
  | (it & 0x01) << 7
  | (it & 0x02) << 5
  | (it & 0x04) << 3
  | (it & 0x08) << 1
  | (it & 0x10) >> 1
  | (it & 0x20) >> 3
  | (it & 0x40) >> 5
  | (it & 0x80) >> 7

create-fixed-symbol-and-length_ -> HuffmanTables_:
  bit-lens := List 288:
    if it <= 143:
      SymbolBitLen_ it 8
    else if it <= 255:
      SymbolBitLen_ it 9
    else if it <= 279:
      SymbolBitLen_ it 7
    else:
      SymbolBitLen_ it 8

  return HuffmanTables_ bit-lens

create-fixed-distance_ -> HuffmanTables_:
  bit-lens := List 32: SymbolBitLen_ it 5
  return HuffmanTables_ bit-lens
rle-start_ group:
  #primitive.zlib.rle-start

/**
Compresses the bytes in source in the given range, and writes them into the
  destination starting at the index.  The return value, v, is an integer.
  The number of bytes read is v & 0x7fff, and the number of bytes written is
  v >> 15.
*/
rle-add_ rle destination index source/io.Data from/int to/int -> int:
  #primitive.zlib.rle-add:
    return io.primitive-redo-io-data_ it source from to: | bytes/ByteArray |
      rle-add_ rle destination index bytes 0 bytes.size

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
  #primitive.zlib.zlib-write:
    return io.primitive-redo-io-data_ it data: | bytes/ByteArray |
      zlib-write_ zlib bytes

zlib-close_ zlib -> none:
  #primitive.zlib.zlib-close

zlib-uninit_ zlib -> none:
  #primitive.zlib.zlib-uninit
