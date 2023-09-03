// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import expect show *

class SymbolBitLen:
  symbol/int
  bit-len/int
  encoding/int? := null

  constructor .symbol .bit-len:

  stringify:
    return "SymbolBitLen($symbol, len=$bit-len) encoding=$(%b encoding)"

FIXED-SYMBOL-AND-LENGTH_ ::= create-fixed-symbol-and-length_
FIXED_DISTANCE_ ::= create-fixed-distance_

/**
A decompressor for the DEFLATE algorithm.
This implementation holds on to copies of the buffers it delivers with the read
  method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements.
*/
class CopyingInflator extends BufferingInflator:
  /**
  Construct a copying inflator.
  The $maximum number of bytes it will buffer can be provided to limit memory
    use. Unless the compressor had special parameters, this must be 32k.
  */
  constructor maximum/int:
    super maximum

  read -> ByteArray?:
    result := super
    if result == null or result.size == 0:
      return result
    return result.copy

/**
A decompressor for the DEFLATE algorithm, as used by zlib.
This implementation holds on to the buffers it delivers with the read
  method, for up to 32k of data.  This is a simple way to handle the
  buffer requirements, but it means the user may not overwrite the buffers,
  and it can use some memory.  May return the same byte arrays several times,
  or slices of the same byte arrays.
*/
class BufferingInflator extends Inflator:
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
A decompressor for the DEFLATE algorithm.
This abstract class does not know how to look back in the output stream.
  To use it you have to be able to deliver up to 32k of previously decompressed
  data in the look-back method (or whatever size the compressor was set to).
*/
abstract class Inflator:
  buffer_/ByteArray := #[]
  buffer-pos_/int := 0
  buffer-2_/ByteArray := #[]
  valid-bits_/int := 0
  data_/int := 0
  in-final-block_ := false
  to_go_/int := 0
  // List of SymbolBitLen objects we are building up.
  lengths_/List? := null
  // Bits of repeat we are waiting for.
  repeat-bits_/int := 0
  hlit_/int := 0
  hdist_/int := 0
  hclen_/int := 0
  state_/int := INITIAL_
  meta_table_/HuffmanTables? := null
  symbol-and-length_table_/HuffmanTables? := null
  distance-table_/HuffmanTables? := null
  output-buffer_/ByteArray := ByteArray 256
  output-buffer-position_/int := 0  // Always less than the size.
  copy-length_ := 0  // Number of bytes to copy.
  copy-length-bits_ := 0  // Number of extra length bits we are waiting for.
  copy-distance_ := -1  // Distance to copy from.  -1 means waiting for this info.
  copy-distance-bits_ := 0  // Number of extra distance bits we are waiting for.

  // Should call the block with a byte array and an offset.
  abstract look-back distance/int [block] -> none

  static INITIAL_             ::= 0  // Reading initial 3 bits of block.
  static NO-COMPRESSION_      ::= 2  // Reading 4 bytes of LEN and NLEN.
  static NO-COMPRESSION-BODY_ ::= 3  // Reading to-go_ bytes of data.
  static GET-TABLE-SIZES_     ::= 4  // Reading HLIT, HDIST and HCLEN.
  static GET-HCLEN_           ::= 5  // Reading n x 3 bits of HLIT.
  static GET-HLIT_            ::= 6  // Reading bit lengths for HLIT table.
  static GET-HDIST_           ::= 7  // Reading bit lengths for HDIST table.
  static DECOMRESSING_        ::= 8  // Decompressing data.

  // Returns the next data.
  // Returns an empty byte array if we need more input.
  // Returns null if there is no more data.
  read -> ByteArray?:
    while true:
      if state_ == INITIAL_:
        if in-final-block_:
          return null
        raw := n-bits_ 3
        if raw < 0: return #[]
        in-final-block_ = (raw & 1) == 1
        type := raw >> 1
        if type == 0:
          // No compression.
          n-bits_ (valid-bits_ & 7)  // Discard rest of byte.
          state_ = NO-COMPRESSION_
        else if type == 1:
          // Fixed Huffman tables.
          symbol-and-length_table_ = FIXED-SYMBOL-AND-LENGTH_
          distance-table_ = FIXED_DISTANCE_
          state_ = DECOMRESSING_
        else if type == 2:
          // Dynamic Huffman tables.
          state_ = GET-TABLE-SIZES_
        else:
          throw "Corrupt data"

      else if state_ == NO-COMPRESSION_:
        if output-buffer-position_ != 0:
          return flush-output-buffer_
        len-nlen := n-bits_ 32
        if len-nlen < 0: return #[]
        to_go_ = len-nlen & 0xffff
        complement := len-nlen >> 16
        if to-go_ ^ 0xffff != complement:
          throw "Corrupt data"
        state_ = NO-COMPRESSION-BODY_

      else if state_ == NO-COMPRESSION-BODY_:
        if to_go_ == 0:
          state_ = INITIAL_
        else:
          if valid_bits_ >= 8:
            to-go_--
            return #[n-bits_ 8]
          if buffer-pos_ < buffer_.size:
            result := buffer_[buffer-pos_..]
            to-go_ -= result.size
            buffer-pos_ = buffer_.size
            return result
          return #[]

      else if state_ == GET-TABLE-SIZES_:
        raw := n-bits_ 14
        if raw < 0: return #[]
        hlit_ = (raw & 0x1f) + 257
        raw >>= 5
        hdist_ = (raw & 0x1f) + 1
        raw >>= 5
        hclen_ = raw + 4
        lengths_ = List hclen_
        to-go_ = 0
        state_ = GET-HCLEN_

      else if state_ == GET-HCLEN_:
        while to-go_ < lengths_.size:
          length-code := n-bits_ 3
          if length-code < 0: return #[]
          lengths_[to_go_] = SymbolBitLen HCLEN-ORDER_[to-go_] length_code
          to-go_++
        meta_table_ = HuffmanTables lengths_
        to-go_ = 0
        lengths_ = List hlit_
        state_ = GET-HLIT_

      else if state_ == GET-HLIT_ or state_ == GET-HDIST_:
        if repeat-bits_ > 0:
          repeats := n-bits_ repeat-bits_
          if repeats < 0: return #[]
          last := lengths_[to-go_ - 1].bit-len
          repeats.repeat:
            lengths_[to-go_] = SymbolBitLen to-go_ last
            to-go_++
          repeat-bits_ = 0
        length-code := next_ meta_table_
        if length-code < 0: return #[]
        if length-code < 16:
          lengths_[to-go_] = SymbolBitLen to-go_ length-code
          to-go_++
        else:
          last := 0
          repeats := 3
          if length-code == 16:
            last = lengths_[to-go_ - 1].bit-len
            repeat-bits_ = 2
          else if length-code == 17:
            repeat-bits_ = 3
          else:
            assert: length-code == 18
            repeat-bits_ = 7
            repeats = 11
          repeats.repeat:
            lengths_[to-go_] = SymbolBitLen to-go_ last
            to-go_++
        if to-go_ == lengths_.size:
          if state_ == GET-HLIT_:
            symbol-and-length_table_ = HuffmanTables lengths_
            state_ = GET-HDIST_
            lengths_ = List hdist_
            to-go_ = 0
          else:
            distance-table_ = HuffmanTables lengths_
            state_ = DECOMRESSING_

      else if state_ == DECOMRESSING_:
        if copy-length_ == 0:
          symbol := next_ symbol-and-length_table_
          if symbol < 0: return #[]
          if symbol == 256:
            state_ = INITIAL_
          else if symbol < 255:
            output-buffer_[output-buffer-position_++] = symbol
            if output-buffer-position_ == output-buffer_.size:
              return flush-output-buffer_
          else:
            copy-distance_ = -1
            if symbol < 265:
              copy-length_ = symbol - 254
            else if symbol < 285:
              copy-length-bits_ = (symbol - 261) >> 2
              copy-length_ = (3 + (symbol - 265) & 3) << copy-length-bits_
            else:
              assert: symbol == 285
              copy-length_ = 258
        if copy-length_ != 0:
          if copy-length-bits_ > 0:
            bits := n-bits_ copy-length-bits_
            if bits < 0: return #[]
            copy-length_ += bits
            copy-length-bits_ = 0
          if copy-distance_ < 0:
            symbol := next_ distance-table_
            if symbol < 0: return #[]
            copy-distance-bits_ = "\x00\x00\x00\x00\x01\x01\x02\x02\x03\x03\x04\x04\x05\x05\x06\x06\x07\x07\x08\x08\x09\x09\x0a\x0a\x0b\x0b\x0c\x0c\x0d\x0d"[symbol]
            copy-distance_ = DISTANCES_[symbol]
          if copy-distance-bits_ != 0:
            bits := n-bits_ copy-distance-bits_
            if bits < 0: return #[]
            copy-distance_ += bits
            copy-distance-bits_ = 0
          // We have a copy length and distance.
          // If some of the copy length is before the current output buffer,
          // we have to use the look-back method.
          while copy_distance_ > output-buffer-position_:
            look-back copy_distance_ - output-buffer-position_: | byte-array/ByteArray position/int |
              available := min
                  copy-length_
                  byte-array.size - position
              copyable := min
                  available
                  output-buffer_.size - output-buffer-position_
              if output-buffer-position_ == 0 and available > 32:
                copy-length_ -= available
                return byte-array[position..position + copyable]
              output-buffer_.replace output-buffer-position_ byte-array position copyable
              output-buffer-position_ += copyable
              copy-length_ -= copyable
              if output-buffer-position_ == output-buffer_.size:
                return flush-output-buffer_
          // Copy from the current output buffer.
          // Replace uses memmove semantics, which means it can't be used to do
          // the DEFLATE semantics of making repeated patterns.
          while copy-length_ > 0:
            space := output-buffer_.size - output-buffer-position_
            want := min
                space
                copy-length_
            copyable := min
                want
                copy-distance_  // Limit because of memmove semantics.
            if copyable < 8 and want > (copyable << 3):
              // More efficient to use a byte loop than repeated calls to replace.
              from := output-buffer-position_ - copy-distance_
              to := output-buffer-position_
              want.repeat:
                output-buffer_[to + it] = output-buffer_[from + it]
              output-buffer-position_ += want
              copy-length_ -= want
            else:
              // More efficient to use replace.
              output-buffer_.replace output-buffer-position_ output-buffer_ output-buffer-position_ - copy-distance_ copyable
              output-buffer-position_ += copyable
              copy-length_ -= copyable
            if output-buffer-position_ == output-buffer_.size:
              return flush-output-buffer_

  flush-output-buffer_ -> ByteArray:
    if output-buffer-position_ == output-buffer_.size:
      result := output-buffer_[..output-buffer-position_]
      output-buffer_ = ByteArray 256
      output-buffer-position_ = 0
      return result
    result := output-buffer_.copy 0 output-buffer-position_
    output-buffer-position_ = 0
    return result

  static DISTANCES_ ::= [
      1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
      257, 385, 513, 769, 1025, 1537, 2049, 3073,
      4097, 6145, 8193, 12289, 16385, 24577
      ]

  static HCLEN-ORDER_ ::= #[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

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
    if valid_bits_ == 8:
      return #[data_] + buffer_[buffer-pos_..]
    return buffer_[buffer-pos_..]


  // Gets next symbol or -1 if we need more data.
  next_ tables/HuffmanTables -> int:
    ensure-bits :=:
      if valid-bits_ < it:
        if buffer-pos_ == buffer_.size:
          return -1
        data_ = (data_ << 8) | buffer_[buffer-pos_++]
        valid-bits_ += 8
    // Ensure we have at least 8 bits of data so we can look in the first level
    // table.
    ensure-bits.call 8
    value1 := tables.first-level[data_ & 0xff]
    bits := value1 & 0xf
    if bits <= 8:
      valid-bits_ -= bits
      data_ >>= bits
      return value1 >> 4
    // Failed to hit in the first level table - look in the somewhat slower
    // second level.
    while true:
      // We need at least bits bits of data to get a match in the second level.
      ensure-bits.call bits
      key := ((data_ & ((1 << bits) - 1)) << 4) | bits
      value2 := tables.second-level.get key
      if value2:
        data_ >>= bits
        valid-bits_ -= bits
        return value2 >> 4
      bits++
      if bits > 15:
        throw "Corrupt data"

  // Slower version of next_ that does not ask for more data.  Should only be
  // used when there is no more input data.  Throws if no more symbols can be
  // produced.
  next-near-end_ tables/HuffmanTables -> int:
    valid-bits_ += 15
    result := next_ tables
    valid-bits_ -= 15
    if valid-bits_ < 0:
      throw "Not enough data"
    return result

  // Gets next n bits of data or -1 if we need more data.
  n-bits_ bits/int -> int:
    while valid-bits_ < bits:
      if buffer-pos_ == buffer_.size:
        return -1
      data_ = (data_ << 8) | buffer_[buffer-pos_++]
      valid-bits_ += 8
      return -1
    result := data_ & ((1 << bits) - 1)
    data_ >>= bits
    valid-bits_ -= bits
    return result

class HuffmanTables:
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

  // Takes a list of SymbolBitLen objects, and creates the tables.
  constructor bitlens/List:
    bitlens = bitlens.sort: | a b |
      a.bit-len.compare-to b.bit-len --if-equal=:
        a.symbol - b.symbol
    first-level = List 256: 0
    second-level = Map
    counter := 0
    bit-len := 0
    bitlens.do: | sbl/SymbolBitLen |
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

main:
  expect-equals 0 (reverse_ 0 1)
  expect-equals 1 (reverse_ 1 1)
  expect-equals 0b00 (reverse_ 0b00 2)
  expect-equals 0b10 (reverse_ 0b01 2)
  expect-equals 0b01 (reverse_ 0b10 2)
  expect-equals 0b11 (reverse_ 0b11 2)
  expect-equals 0b110100 (reverse_ 0b001011 6)
  expect-equals 0b0110100 (reverse_ 0b0010110 7)
  expect-equals 0b10100110 (reverse_ 0b01100101 8)
  expect-equals 0b110100110 (reverse_ 0b011001011 9)
  expect-equals 0b1110100110 (reverse_ 0b0110010111 10)
  expect-equals 0b11101001101 (reverse_ 0b10110010111 11)

  // From the RFC section 3.2.2
  ex := [
      SymbolBitLen 'A' 2,
      SymbolBitLen 'B' 1,
      SymbolBitLen 'C' 3,
      SymbolBitLen 'D' 3,
  ]

  lookup := HuffmanTables ex

  for i := 0; i < 256; i++:
    value := lookup.first-level[i]
    if i & 1 == 0:
      expect-equals (('B' << 4) + 1) value
    else if i & 0b11 == 0b01:
      expect-equals (('A' << 4) + 2) value
    else if i & 0b111 == 0b011:
      expect-equals (('C' << 4) + 3) value
    else if i & 0b111 == 0b111:
      expect-equals (('D' << 4) + 3) value
    else:
      expect-equals 0 value

  // Reconstruct the static Huffman table from the RFC.
  create-fixed-symbol-and-length_
  create-fixed-distance_

create-fixed-symbol-and-length_ -> HuffmanTables:
  bit-lens := List 288:
    if it <= 143:
      SymbolBitLen it 8
    else if it <= 255:
      SymbolBitLen it 9
    else if it <= 279:
      SymbolBitLen it 7
    else:
      SymbolBitLen it 8

  return HuffmanTables bit-lens

create-fixed-distance_ -> HuffmanTables:
  bit-lens := List 32: SymbolBitLen it 5
  return HuffmanTables bit-lens
