import .encoder

JSON_ESCAPEES_ ::= {
  'b': '\b',
  'f': '\f',
  'n': '\n',
  'r': '\r',
  't': '\t'
}

YAML_ESCAPEES_ ::= {
  'b': '\b',
  'f': '\f',
  'n': '\n',
  'r': '\r',
  't': '\t',
  '0': '\0',
  'a': '\a',
  'v': '\v',
  'e': '\x20'
}

class DecoderBase_:
  bytes_ := null
  offset_ := 0
  tmp-buffer_ ::= Buffer_
  utf-8-buffer_/ByteArray? := null

  read-four-hex-digits_ -> int:
    hex-value := 0
    4.repeat:
      hex-value <<= 4
      hex-value += hex-char-to-value bytes_[offset_++] --on-error=(: throw "BAD \\u ESCAPE IN STRING")
    return hex-value

  decode-quoted-string_ escapees/Map unterminated-exception/string --quote-char/int='"' --allow-x-escape/bool=false:
    buffer := tmp-buffer_
    buffer.clear_
    bytes-size := bytes_.size
    while true:
      if offset_ >= bytes-size: throw unterminated-exception

      c := bytes_[offset_]

      if c == quote-char:
        break
      else if c == '\\':
        offset_++
        c = bytes_[offset_]
        if escapees.contains c: c = escapees[c]
        else if c == 'u':
          offset_++
          // Read 4 hex digits.
          if offset_ + 4 > bytes-size: throw unterminated-exception
          c = read-four-hex-digits_
          if 0xd800 <= c <= 0xdbff:
            // First part of a surrogate pair.
            if offset_ + 6 > bytes-size: throw unterminated-exception
            if bytes_[offset_] != '\\' or bytes_[offset_ + 1] != 'u': throw "UNPAIRED_SURROGATE"
            offset_ += 2
            part-2 := read-four-hex-digits_
            if not 0xdc00 <= part-2 <= 0xdfff: throw "INVALID_SURROGATE_PAIR"
            c = 0x10000 + ((c & 0x3ff) << 10) | (part-2 & 0x3ff)
          buf-8 := utf-8-buffer_
          if not buf-8:
            utf-8-buffer_ = ByteArray 4
            buf-8 = utf-8-buffer_
          bytes := utf-8-bytes c
          write-utf-8-to-byte-array buf-8 0 c
          bytes.repeat:
            buffer.put-byte_ buf-8[it]
          continue
        else if c == 'x' and allow-x-escape:
          offset_++
          if offset_ + 2 > bytes-size: throw unterminated-exception
          c = int.parse bytes_[offset_..offset_+2] --radix=16

      buffer.put-byte_ c
      offset_++

    offset_++
    return buffer.to-string


class StringView_:
  str_ ::= ?

  constructor .str_:

  operator [] i:
    return str_.at --raw i

  operator [..] --from=0 --to=size:
    return StringView_ str_[from..to]

  to-string from to:
    return str_.copy from to

  size:
    return str_.size


