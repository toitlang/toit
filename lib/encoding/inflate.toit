// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Pure Toit implementation of decompression of the DEFLATE
  format, as used by PNG, zlib and gzip.
*/

import binary show LITTLE_ENDIAN
import crypto.adler32
import expect show *
import zlib

class SymbolBitLen_:
  symbol/int
  bit-len/int
  encoding/int? := null

  constructor .symbol .bit-len:

  stringify:
    return "SymbolBitLen_($symbol, len=$bit-len) encoding=$(%b encoding)"

FIXED-SYMBOL-AND-LENGTH_ ::= create-fixed-symbol-and-length_
FIXED-DISTANCE_ ::= create-fixed-distance_

/**
A pure Toit decompressor for the DEFLATE format.
This implementation holds on to copies of the buffers it delivers with the read
  method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements.
*/
class CopyingInflater extends BufferingInflater:
  /**
  Construct a copying inflater.
  The $maximum number of bytes it will buffer can be provided to limit memory
    use. Unless the compressor had special parameters, this must be 32k.
  */
  constructor maximum/int=32768:
    super maximum

  read -> ByteArray?:
    result := super
    if result == null or result.size == 0:
      return result
    return result.copy

/**
A pure Toit decompressor for the DEFLATE format, as used by zlib.
This implementation holds on to the buffers it delivers with the read
  method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements, but it means the user may not overwrite the buffers,
  and it can use some memory.  May return the same byte arrays several times,
  or slices of the same byte arrays.
*/
class BufferingInflater extends Inflater:
  maximum/int

  /**
  Construct a buffering inflator.
  The $maximum number of bytes it will buffer can be provided to limit memory
    use. Unless the compressor had special parameters, this must be 32k.
  */
  constructor .maximum=32768:

  // Previous byte arrays we have returned.
  previous_/List? := []
  // Number of bytes we have buffered.
  buffered_ := 0

  read -> ByteArray?:
    result := super
    if result == null or result.size == 0:
      return result
    if previous_.size > 0 and result.size < 32 and previous_[previous_.size - 1].size < 32:
      previous_[previous_.size - 1] += result
    else:
      previous_.add result
    buffered_ += result.size
    while buffered_ > maximum and buffered_ - previous_[0].size > maximum:
      buffered_ -= previous_[0].size
      previous_ = previous_.copy 1
    return result

  look-back distance/int [block]:
    if distance > buffered_:
      throw "Corrupt data"
    start := previous_.size - 1
    while distance > previous_[start].size:
      distance -= previous_[start].size
      start--
    ba := previous_[start]
    block.call ba (ba.size - distance)

/**
A pure Toit decompressor for the DEFLATE format.
This abstract class does not know how to look back in the output stream.
  To use it you have to be able to deliver up to 32k of previously decompressed
  data in the $look-back method (or whatever size the compressor was set to).
*/
abstract class Inflater:
  window-size := 32768
  zlib-header-footer/bool
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
  hclen_/int := 0
  state_/int := INITIAL_
  meta-table_/HuffmanTables_? := null
  symbol-and-length-table_/HuffmanTables_? := null
  distance-table_/HuffmanTables_? := null
  output-buffer_/ByteArray := ByteArray 256
  output-buffer-position_/int := 0  // Always less than the size.
  copy-length_ := 0  // Number of bytes to copy.
  copy-distance_ := 0  // Distance to copy from.

  // Should call the block with a byte array and an offset.
  abstract look-back distance/int [block] -> none

  static ZLIB-HEADER_         ::= -2 // Reading zlib header.
  static ZLIB-FOOTER_         ::= -1 // Reading Adler checksum.
  static INITIAL_             ::= 0  // Reading initial 3 bits of block.
  static NO-COMPRESSION_      ::= 2  // Reading 4 bytes of LEN and NLEN.
  static NO-COMPRESSION-BODY_ ::= 3  // Reading counter_ bytes of data.
  static GET-TABLE-SIZES_     ::= 4  // Reading HLIT, HDIST and HCLEN.
  static GET-HCLEN_           ::= 5  // Reading n x 3 bits of HLIT.
  static GET-HLIT_            ::= 6  // Reading bit lengths for HLIT table.
  static GET-HDIST_           ::= 7  // Reading bit lengths for HDIST table.
  static DECOMRESSING_        ::= 8  // Decompressing data.

  constructor --.zlib-header-footer/bool=true:
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
        window-size = 1 << (8 + ((header & 0xf0) >> 4))
        if window-size > 32768: throw "Corrupt data"
        if header & 0x2000 != 0: throw "Preset dictionary not supported"
        big-endian := header >> 8 + ((header & 0xff) << 8)
        if big-endian % 31 != 0: throw "Corrupt data"
        state_ = INITIAL_

      else if state_ == ZLIB-FOOTER_:
        n-bits_ (valid-bits_ & 7)  // Discard rest of byte.
        adler32 := n-bits_ 32
        if adler32 < 0: return NEED-MORE-DATA_
        calculated := LITTLE_ENDIAN.uint32 adler_.get 0
        adler_ = null // Only read the checksum once.
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
            state_ = DECOMRESSING_
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
            if adler_: adler_.add result
            return result
          if buffer-pos_ < buffer_.size:
            length := min
                counter_
                buffer_.size - buffer-pos_
            result := buffer_[buffer-pos_..buffer-pos_ + length]
            counter_ -= length
            buffer-pos_ += length
            if adler_: adler_.add result
            return result
          return NEED-MORE-DATA_

      else if state_ == GET-TABLE-SIZES_:
        raw := n-bits_ 14
        if raw < 0: return NEED-MORE-DATA_
        hlit_ = (raw & 0x1f) + 257
        hdist_ = ((raw >> 5) & 0x1f) + 1
        hclen_ = (raw >> 10) + 4
        lengths_ = List hclen_
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
        lengths_ = List hlit_
        state_ = GET-HLIT_

      else if state_ == GET-HLIT_ or state_ == GET-HDIST_:
        extra-repeats := get-pending-bits.call
        if extra-repeats != 0:
          last := lengths_[counter_ - 1].bit-len
          extra-repeats.repeat:
            lengths_[counter_] = SymbolBitLen_ counter_ last
            counter_++
        length-code := next_ meta-table_
        if length-code < 0: return NEED-MORE-DATA_
        if length-code < 16:
          lengths_[counter_] = SymbolBitLen_ counter_ length-code
          counter_++
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
          repeats.repeat:
            lengths_[counter_] = SymbolBitLen_ counter_ last
            counter_++
        if counter_ == lengths_.size:
          if state_ == GET-HLIT_:
            symbol-and-length-table_ = HuffmanTables_ lengths_
            state_ = GET-HDIST_
            lengths_ = List hdist_
            counter_ = 0
          else:
            distance-table_ = HuffmanTables_ lengths_
            state_ = DECOMRESSING_
            meta-table_ = null  // Don't need this any more.

      else if state_ == DECOMRESSING_:
        if copy-length_ == 0:
          symbol := next_ symbol-and-length-table_
          if symbol < 0: return NEED-MORE-DATA_
          if symbol == 256:
            state_ = INITIAL_
          else if symbol < 255:
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
          copy-length_ += get-pending-bits.call
          if copy-distance_ == 0:
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
            look-back copy-distance_ - pos: | byte-array/ByteArray offset/int |
              available := min
                  copy-length_
                  byte-array.size - offset
              copyable := min
                  available
                  output-buffer_.size - pos
              if pos == 0 and copyable > 32:
                copy-length_ -= available
                result := byte-array[offset..offset + copyable]
                if adler_: adler_.add result
                output-buffer-position_ = pos
                return result
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

  flush-output-buffer_ pos/int -> ByteArray:
    if pos == output-buffer_.size:
      result := output-buffer_[..pos]
      output-buffer_ = ByteArray 256
      output-buffer-position_ = 0
      if adler_: adler_.add result
      return result
    result := output-buffer_.copy 0 pos
    output-buffer-position_ = 0
    if adler_: adler_.add result
    return result

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
  Writes a new byte array to the decompressor. Cannot be called until
    the reader has returned null.
  */
  write buffer/ByteArray:
    if buffer-pos_ != buffer_.size:
      throw "Too early to add data"
    buffer_ = buffer
    buffer-pos_ = 0

  /**
  Returns the input data that was not used, only whole bytes.
  */
  rest -> ByteArray:
    assert: valid-bits_ == 0 or valid-bits_ == 8
    if valid-bits_ == 8:
      return #[data_] + buffer_[buffer-pos_..]
    return buffer_[buffer-pos_..]

  // Gets next symbol or -1 if we need more data.
  next_ tables/HuffmanTables_ -> int:
    value1 := tables.first-level[data_ & 0xff]
    bits := value1 & 0xf
    if bits <= valid_bits_ and bits <= 8:
      valid-bits_ -= bits
      data_ >>= bits
      return value1 >> 4

    ensure-bits :=:
      if valid-bits_ < it:
        if buffer-pos_ == buffer_.size:
          return -1
        data_ |= buffer_[buffer-pos_++] << valid-bits_
        valid-bits_ += 8

    if bits > valid-bits_ and valid_bits_ < 8:
      // We did a lookup with too few bits - get the next byte and retry.
      ensure-bits.call 8  // Enough for first level table.
      value1 = tables.first-level[data_ & 0xff]
      bits = value1 & 0xf
      if bits <= 8:
        assert: bits <= valid-bits_
        valid-bits_ -= bits
        data_ >>= bits
        return value1 >> 4

    // Failed to hit in the first level table - look in the somewhat slower
    // second level.
    while true:
      // First level table told us we need at least bits bits of data to get a
      // match in the second level.
      ensure-bits.call bits
      key := ((data_ & ((1 << bits) - 1)) << 4) | bits
      value2 := tables.second-level.get key
      if value2:
        data_ >>= bits
        valid-bits_ -= bits
        return value2 >> 4
      // Still don't have enough bits - look for a hit with one more bit.
      bits++
      if bits > 15:
        throw "Corrupt data"

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

class HuffmanTables_:
  // A list of 256 ints.
  // The first 4 bits are the bit length of the symbol. If it is <= 8 then
  // we don't need a second level lookup.  If it is >8 then that is the
  // minimum bit length for symbols that hit this entry.
  // For bit lengths <= 8, the rest of int is the symbol.
  // Index is a byte of raw input, ie with the Huffman codes reversed.
  first-level/List

  // A map from int to int.
  // The value is as above (4 bits of bit length, rest is symbol).
  // The key is made up as follows:
  // 1-(n bits of reversed Huffman input).
  // The bits must be added one at a time from the input until
  // we get a hit.
  second-level/Map

  // Takes a list of SymbolBitLen_ objects, and creates the tables.
  constructor bitlens/List:
    bitlens = bitlens.sort: | a b |
      a.bit-len.compare-to b.bit-len --if-equal=:
        a.symbol - b.symbol
    first-level = List 256: 0
    second-level = Map
    counter := 0
    bit-len := 0
    bitlens.do: | sbl/SymbolBitLen_ |
      if sbl.bit-len > 0:
        if sbl.bit-len > bit-len:
          counter = counter << (sbl.bit-len - bit-len)
          bit-len = sbl.bit-len
        sbl.encoding = counter
        value := sbl.bit-len | (sbl.symbol << 4)
        if bit-len <= 8:
          step := 1 << bit-len
          for i := reverse_ counter bit-len; i < 256; i += step:
            first-level[i] = value
        else:
          idx := REVERSED_[(counter >> (bit-len - 8)) & 0xff]
          // Set the entry to be "overflow" ie a bit length of more than 8,
          // but the minimum bit length for symbols that hit this entry.
          if first-level[idx] == 0: first-level[idx] = sbl.bit-len
          // Add to second-level map.  We combine with the bit length to
          // avoid clashes caused by the reversed order.
          map-index := ((reverse_ counter bit-len) << 4) | bit-len
          second-level[map-index] = value
        counter++

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
