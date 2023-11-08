class Parser_:
  bytes_/any
  offset_/int := 0
  constructor .bytes_:

  // The grammar and hence the parser is greedy. That means that it is nescessary to be able to rollback
  mark -> any:
    return offset_

  rollback mark:
    offset_ = mark
    return null

  at-mark mark -> bool:
    return offset_ == mark

  with-rollback [block]:
    mark := mark
    block.call
    return rollback mark

  repeat --at-least-one/bool=false [block]:
    with-rollback:
      result := []
      while true:
        mark := mark
        res := block.call
        if not res: break
        result.add res
        if at-mark mark: break // No progess, so matched empty. This should terminate the loop
      if not at-least-one or not result.is-empty: return result

  can-read num/int:
    return offset_ + num <= bytes_.size

  match buf/ByteArray:
    if not can-read buf.size: return false
    return bytes_[ offset_ :: offset_ + buf.size ] == buf

  match str/string:
    match str.to-byte-array

  l-yaml-stream:
    repeat: l-document-prefix

    documents := []
    if res := l-any-document: documents.add res

    while true:
      if l-eof: return documents
      with-rollback:
        if (repeat --at-least-one: l-document-suffix):
          repeat: l-document-prefix
          if res := l-any-document: documents.add res
          break.do

        if c-byte-order-mark: break.do
        if l-comment: break.do
        if res := l-explicit-document:
          documents.add res
          break.do

        return null // Parse error

  l-eof: return offset_ == bytes_.size

  l-document-prefix:
    c-byte-order-mark
    repeat: l-comment

  l-document-suffix -> bool:
    if not c-document-end: return false
    if not s-l-comments: return false
    return true

  c-byte-order-mark:
    if can-read 2:
      b1 := bytes_[offset_]
      b2 := bytes_[offset_ + 1]
      if b1 == 0xFE and b2 == 0xFF or
          b1 == 0xFF and b2 == 0xFE or
          b1 == 0 or b2 == 0: throw "UNSUPPORTED_BYTE_ORDER"
    if can-read 3:
      b1 := bytes_[offset_]
      b2 := bytes_[offset_ + 1]
      b3 := bytes_[offset_ + 2]
      if b1 ==
      if bytes_[offset_] == 0xFE and  bytes_[offset_+1] == 0xFF
  l-any-document:
    with-rollback:
      if res := l-directive-document: return res
      if res := l-explicit-document: return res
      if res := l-bare-document: return res

  l-directive-document:
    return null

  l-explicit-document:
    return null

  l-bare-document:
    return null
