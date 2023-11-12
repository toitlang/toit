// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// This parser follows the grammar of the YAML 1.2.2 draft.
// The grammar is almost a PEG grammar (except for one lookbehind).

NULL-VALUE_     ::= "null"
TRUE-VALUE_     ::= "true"
FALSE-VALUE_    ::= "false"
OPTIONAL-VALUE_ ::= "optional"

B-LINE-FEED_        ::= '\n'
B-CARRIAGE_RETURN_  ::= '\r'
B-LINE-TERMINATORS_ ::= { B-LINE-FEED_, B-CARRIAGE_RETURN_ }

S-SPACE_            ::= ' '
S-TAB_              ::= '\t'
S-WHITESPACE_       ::= { S-SPACE_, S-TAB_ }

C-COMMENT_          ::= '#'
C-BYTE-ORDER-MARK_  ::= 0xFEFF
C-DIRECTIVE_        ::= '%'
C-TAG_              ::= '!'
C-COLLECT-ENTRY_    ::= ','
C-SEQUENCE-START_   ::= '['
C-SEQUENCE-END_     ::= ']'
C-MAPPING-START_    ::= '{'
C-MAPPING-END_      ::= '}'
C-ANCHOR_           ::= '&'
C-LITERAL_          ::= '|'
C-FOLDED_           ::= '>'
C-SEQUENCE-ENTRY_   ::= '-'
C-MAPPING-KEY_      ::= '?'
C-MAPPING-VALUE_    ::= ':'
C-ALIAS_            ::= '*'
C-SINGLE-QUOTE_     ::= '\''
C-DOUBLE-QUOTE_     ::= '"'
C-RESERVCED-1_      ::= 'Q'
C-RESERVCED-2_      ::= '`'
C-ESCAPE_           ::= '\\'

C-FLOW-INDICATOR_  ::= { C-COLLECT-ENTRY_, C-SEQUENCE-START_, C-SEQUENCE-END_, C-MAPPING-START_, C-MAPPING-END_ }
C-INDICATOR_       ::= { C-SEQUENCE-ENTRY_, C-MAPPING-KEY_, C-MAPPING-VALUE_, C-COLLECT-ENTRY_, C-SEQUENCE-START_,
                         C-SEQUENCE-END_, C-MAPPING-START_, C-MAPPING-END_, C-COMMENT_, C-ANCHOR_, C-ALIAS_,
                         C-TAG_, C-LITERAL_, C-FOLDED_, C-SINGLE-QUOTE_, C-DOUBLE-QUOTE_, C-DIRECTIVE_,
                         C-RESERVCED-1_, C-RESERVCED-2_}
BLOCK-IN_    ::= 0
BLOCK-OUT_   ::= 1
BLOCK-KEY_   ::= 2
FLOW-IN_     ::= 3
FLOW-OUT_    ::= 4
FLOW-KEY_    ::= 5

STRIP_ ::= 0
CLIP_  ::= 1
KEEP_  ::= 2

flatten-list_ list/List -> List:
  result := List
  list.do:
    if it is List: result.add-all it
    else: result.add it
  return result

class Parser_:
  bytes_/ByteArray
  offset_/int := 0
  named-nodes := {:}

  constructor .bytes_:
    print "Parsing: $bytes_.to-string"
  // The grammar and hence the parser is greedy. That means that it is nescessary to be able to rollback
  mark -> any:
    return offset_

  rollback mark:
    offset_ = mark

  at-mark mark -> bool:
    return offset_ == mark

  with-rollback [block]:
    mark := mark
    block.call
    rollback mark

  lookahead [block]:
    result := false
    with-rollback: result = block.call
    return result

  slice n -> ByteArray:
    return bytes_[offset_..offset_ + n]

  repeat --at-least-one/bool=false [block] -> List?:
    with-rollback:
      result := []
      while true:
        mark := mark
        res := block.call
        if not res:
          rollback mark
          break
        if at-mark mark: break // No progess, so matched empty. This should terminate the loop
        result.add res
      if not at-least-one or not result.is-empty: return result
    return null

  optional --or-null/bool=false [block]:
    with-rollback:
      if res := block.call: return res

    return or-null?null:NULL-VALUE_

  can-read num/int:
    return offset_ + num <= bytes_.size

  match-one [block] -> int?:
    if can-read 1:
      if (block.call bytes_[offset_]):
        offset_ += 1
        return bytes_[offset_ - 1]
    return null

  match-many n [block] -> bool:
    if can-read n:
      if block.call:
        offset_ += n
        return true
    return false

  match-char byte/int:
    return match-one: it == byte

  match-chars chars/Set -> int?:
    return match-one: chars.contains it

  match-range from/int to/int:
    return match-one: from <= it and it <= to

  match-buffer buf/ByteArray -> bool:
    return match-many buf.size: (slice buf.size) == buf

  match-string str/string:
    return match-buffer str.to-byte-array

  match-hex digits/int -> int?:
    with-rollback:
      start := offset_
      failed := false
      while digits-- > 0:
        if not ns-hex-digit:
          failed = true
          break
      if not failed: return int.parse --radix=16 (string-since start)
    return null
    
  start-of-line:
    return offset_ == 0 or bytes_[offset_ - 1] == B-LINE-FEED_ or bytes_[offset_ - 1] == B-CARRIAGE-RETURN_

  string-since start -> string:
    return bytes_[start .. offset_].to_string

  to_return_value val:
    if val == NULL-VALUE_: return null
    if val == OPTIONAL-VALUE_: return null
    if val == TRUE-VALUE_: return true
    if val == FALSE-VALUE_: return false

    catch:
      if res := int.parse val: return res

    catch:
      if res := float.parse val: return res

    return val

  apply-props props res:
    if props:
      tag := props[0]
      anchor := props[1]

      if anchor: named-nodes[anchor] = res
      if tag:
        if tag == "!!str":
          res = res.to-string
          catch --trace: throw ""
    return res

  find-leading-spaces-on-first-non-empty-line:
    start := offset_
    start-of-line := offset_
    while true:
      if s-white: continue
      if b-break:
        start-of-line = offset_
        continue
      break
    result := offset_ - start-of-line
    offset_ = start

    print "leading space on non-empty: $result"
    return result

  // Overall structure
  l-yaml-stream -> List:
    k := repeat: l-document-prefix
    print "main: $offset_, k=$k"
    documents := []
    if res := l-any-document: documents.add (to_return_value res)

    repeat: l-yaml-stream-helper documents
    print "parse result: $documents"

    if not l-eof:
      print "$offset_, remaining: $bytes_[offset_..].to-string"
      throw "INVALID_YAML_DOCUMENT"

    return documents

  l-yaml-stream-helper documents/List -> bool:
    with-rollback:
      if (repeat --at-least-one: l-document-suffix):
        repeat: l-document-prefix
        if res := l-any-document: documents.add (to_return_value res)
        return true

    if c-byte-order-mark: return true
    if l-comment: print "FISK"; return true
    if res := l-explicit-document:
      documents.add res
      return true

    return false


  l-any-document:
    with-rollback:
      if res := l-directive-document: return res
      if res := l-explicit-document: return res
      if res := l-bare-document: return res
    return null

  l-directive-document:
    with-rollback:
      repeat --at-least-one: l-directive
      if res := l-explicit-document: return res

    return null

  l-explicit-document:
    with-rollback:
      if c-directives-end:
        if res := l-bare-document: return res
        if s-l-comments: return NULL-VALUE_
    return null

  l-bare-document:
    with-rollback:
      if res := s-l-plus-block-node -1 BLOCK-IN_: return res
    return null

  l-eof: return offset_ == bytes_.size

  l-document-prefix:
    print "prefix: $offset_"
    c-byte-order-mark
    repeat: l-comment
    print "prefix: $offset_"
    return true

  l-document-suffix -> bool:
    if not c-document-end: return false
    if not s-l-comments: return false
    return true

  c-document-end:
    return match-string "..."

  c-directives-end:
    return match-string "---"

  // Directives
  l-directive:
    with-rollback:
      if match-char C-DIRECTIVE_ and
         (ns-yaml-directive or
          ns-tag-directive or
          ns-reserved-directive) and
         s-l-comments:
        return true
    return false

  ns-yaml-directive:
    with-rollback:
      if match-string "YAML" and
         s-separate-in-line and
         ns-yaml-version:
        return true
    return false

  ns-yaml-version -> bool:
    start := offset_
    with-rollback:
      if (repeat --at-least-one: ns-dec-digit) and
          match-char '.' and
         (repeat --at-least-one: ns-dec-digit):
        version := string-since start
        parts := version.split "."
        major := int.parse parts[0]
        minor := int.parse parts[1]
        if major > 1 or minor > 2: throw "UNSUPPORTED_YAML_VERSION"
        return true
    return false
  ns-tag-directive:
    with-rollback:
      if match-string "TAG" and
         s-separate-in-line and
         c-tag-handle and
         s-separate-in-line and
         ns-tag-prefix:
        return true
    return false

  c-tag-handle:
    with-rollback:
      if c-named-tag-handle or
          match-string "!!"  or
          match-char C-TAG_:
        return true
    return false

  c-named-tag-handle:
    with-rollback:
      if  match-char C-TAG_ and
         (repeat --at-least-one : ns-word-char) and
          match-char C-TAG_:
        return true
    return false

  ns-tag-prefix:
    if c-ns-local-tag-prefix or
       ns-global-tag-prefix:
      return true
    return false

  c-ns-local-tag-prefix:
    with-rollback:
      if match-char C-TAG_ and
         (repeat: ns-uri-char):
        return true
    return false

  ns-global-tag-prefix -> bool:
    with-rollback:
      if ns-tag-char and
         (repeat: ns-uri-char):
        return true
    return false

  ns-reserved-directive -> bool:
    with-rollback:
      if ns-directive-name
         and (repeat: s-separate-in-line and ns-directive-parameter):
        return true
    return false

  ns-directive-name:
    return repeat --at-least-one: ns-char

  ns-directive-parameter:
    return repeat --at-least-one: ns-char

  // comments
  l-comment:
    with-rollback:
      if s-separate-in-line:
        c-nb-comment-text
        if b-comment: print offset_; return true
    return false

  s-l-comments:
    with-rollback:
      if s-b-comment or start-of-line:
        repeat: l-comment
        return true
    return false

  s-b-comment:
    with-rollback:
      optional: if s-separate-in-line: (optional: c-nb-comment-text)
      if b-comment: return true
    return false

  s-separate-in-line:
    with-rollback:
      if (repeat --at-least-one: s-white): return true
      if start-of-line: return true
    return false

  c-nb-comment-text:
    if c-comment:
      repeat: nb-char
      return true
    return false

  b-comment:
    with-rollback:
      if b-non-content: return true
    return l-eof

  b-non-content:
    return b-break

  l-trail-comments n:
    with-rollback:
      if (s-indent-less-than n and
          c-nb-comment-text and
          b-comment and
          (repeat: l-comment)): return true
    return false

  // Data part
  s-l-plus-block-node n c -> any:
    if res := s-l-plus-block-in-block n c: return res
    if res := s-l-plus-flow-in-block n: return res
    return null

  s-l-plus-block-in-block n c -> any:
    if res := s-l-plus-block-scalar n c: return res
    if res := s-l-plus-block-collection n c: return res
    return null

  s-l-plus-flow-in-block n:
    with-rollback:
      print "s-l-plus-flow-in-block: $offset_"
      if s-separate n + 1 FLOW-OUT_:
        print "s-l-plus-flow-in-block: 2 $offset_"
        if res := ns-flow-node n + 1 FLOW-OUT_:
          print "s-l-plus-flow-in-block: 3 $res"
          if s-l-comments:
            print "s-l-plus-flow-in-block: 4"
            return res
    return null

  s-l-plus-block-collection n c:
    with-rollback:
      props := optional --or-null: if s-separate n + 1 c: c-ns-properties n + 1 c
      if s-l-comments:
        // TODO: Use prpos
        if res := seq-space n c: return apply-props props res
        if res := l-plus-block-mapping n c: return apply-props props res
    return null

  s-l-plus-block-scalar n c:
    with-rollback:
      if s-separate n + 1 c:
        props := optional --or-null: if p := c-ns-properties n + 1 c and s-separate n + 1 c: p
        res := c-l-plus-literal n
        print "s-l-plus-block-scalar: $res"
        if not res: res = c-l-plus-folded n
        if res: return apply-props props res
    return null

  seq-space n c:
    if c == BLOCK-OUT_: return l-plus-block-sequence n - 1
    if c == BLOCK-IN_: return l-plus-block-sequence n
    return null

  l-plus-block-sequence n:
    with-rollback:
      if m := s-indent n + 1 --auto-detect-m:
        if first := c-l-block-seq-entry n + 1 + m:
          rest := repeat:
            res := null
            if s-indent n + 1 + m:
              if tmp :=  c-l-block-seq-entry n + 1 + m:
                res = tmp
            res
          result := [ to_return_value first]
          result.add-all (rest.map: to_return_value it)
          return result
    return null

  l-plus-block-mapping n c -> Map?:
    with-rollback:
      if m := s-indent n + 1 --auto-detect-m:
        if first := ns-l-block-map-entry n + 1 + m:
          rest := repeat:
            res := null
            if s-indent n + 1 + m:
              if tmp := ns-l-block-map-entry n + 1 + m:
                res = tmp
            res
          result := { to_return_value first[0] : to_return_value first[1] }
          rest.do: result[to_return_value it[0]] = to_return_value it[1]
          return result
    return null

  c-l-block-seq-entry n:
    with-rollback:
      if match-char C-SEQUENCE-ENTRY_:
        if (lookahead: not ns-char):
          if res := s-l-plus-block-indented n BLOCK-IN_:
            return res
    return null

  s-l-plus-block-indented n c:
    with-rollback:
      if m := s-indent 0 --auto-detect-m:
        if res := ns-l-compact-sequence n + 1 + m: return res
        if res := ns-l-compact-mapping n + 1 + m: return res

    if res := s-l-plus-block-node n c: return res

    if s-l-comments: return NULL-VALUE_

    return null

  ns-l-compact-sequence n:
    with-rollback:
      if first := c-l-block-seq-entry n:
        rest := repeat:
          res := null
          if s-indent n:
            if tmp := c-l-block-seq-entry n:
              res = tmp
          res
        result := [ to_return_value first]
        result.add-all (rest.map: to_return_value it)
        return result
    return null

  ns-l-compact-mapping n:
    with-rollback:
      if first := ns-l-block-map-entry n:
        rest := repeat:
          res := null
          if s-indent n:
            if tmp := ns-l-block-map-entry n:
              res = tmp
          res
        result := { to_return_value first[0] : to_return_value first[1] }
        rest.do: result[to_return_value it[0]] = to_return_value it[1]
        return result
    return null

  ns-l-block-map-entry n -> List?:
    if res := c-l-block-map-explicit-entry n: return res
    if res := ns-l-block-map-implicit-entry n: return res
    return null

  c-l-block-map-explicit-entry n -> List?:
    with-rollback:
      if key := c-l-block-map-explicit-key n:
        if val := l-block-map-explicit-value n:
          return [key, val]
        else:
          return [key, null]
    return null

  c-l-block-map-explicit-key n:
    with-rollback:
      if match-char C-MAPPING_KEY_:
        if res := s-l-plus-block-indented n BLOCK-OUT_: return res
    return null

  l-block-map-explicit-value n:
    with-rollback:
      if s-indent n and match-char C-MAPPING-VALUE_:
        if res := s-l-plus-block-indented n BLOCK-OUT_: return res
    return null

  ns-l-block-map-implicit-entry n:
    with-rollback:
      key := ns-s-block-map-implicit-key
      if not key: key = NULL-VALUE_
      if val := c-l-block-map-implicit-value n:
        return [key, val]
    return null

  ns-s-block-map-implicit-key:
    if res := c-s-implicit-json-key BLOCK-KEY_: return res
    if res := ns-s-implicit-yaml-key BLOCK-KEY_: return res
    return null

  c-l-block-map-implicit-value n -> any:
    with-rollback:
      if match-char C-MAPPING-VALUE_:
        if res := s-l-plus-block-node n BLOCK-OUT_: return res
        if s-l-comments: return NULL-VALUE_
    return null

  c-s-implicit-json-key c:
    with-rollback:
      if res := c-flow-json-node 0 c:
        optional: s-separate-in-line
        return res
    return null

  ns-flow-yaml-node n c:
    if res := c-ns-alias-node: return res
    if res := ns-flow-yaml-content n c: return res
    with-rollback:
      if props := c-ns-properties n c:
        with-rollback:
          if s-separate n c:
            if res := ns-flow-yaml-content n c: return apply-props props res
        return NULL-VALUE_
    return null

  c-flow-json-node n c:
    with-rollback:
      props := optional: if p := c-ns-properties n c: if s-separate n c: p
      if res := c-flow-json-content n c:
        return apply-props props res
    return null

  ns-flow-node n c:
    print "ns-flow-node $n $c"
    if res := c-ns-alias-node: return res
    if res := ns-flow-content n c: return res
    with-rollback:
      if props := c-ns-properties n c:
        with-rollback:
          if s-separate n c:
            if res := ns-flow-content n c: return apply-props props res
        return NULL-VALUE_
    return null

  c-ns-alias-node:
    with-rollback:
      if match-char C-ALIAS_:
        if anchor := ns-anchor-name:
          if not named-nodes.contains anchor: throw "UNRESOLVED_ALIAS"
          return named-nodes[anchor]
    return null

  ns-flow-content n c:
    if res := ns-flow-yaml-content n c: return res
    if res := c-flow-json-content n c: return res
    return null

  c-flow-json-content n c:
    if res := c-flow-sequence n c: return res
    if res := c-flow-mapping n c: return res
    if res := c-single-quoted n c: return res
    if res := c-double-quoted n c: return res
    return null

  ns-flow-yaml-content n c:
    return ns-plain n c

  c-flow-sequence n c -> List?:
    with-rollback:
      if match-char C-SEQUENCE-START_:
        optional: s-separate n c
        res := in-flow n c
        if match-char C-SEQUENCE-END_:
          if res: return List.from res
          else: return []
    return null

  c-flow-mapping n c -> Map?:
    with-rollback:
      if match-char C-MAPPING-START_:
        optional: s-separate n c
        print "c-flow-mapping $n $c"
        map-entries := in-flow-map n c // See https://github.com/yaml/yaml-spec/issues/299
        if match-char C-MAPPING-END_:
          map := Map
          if map-entries:
            map-entries.do: map[to_return_value it[0]] = to_return_value it[1]
          print "c-flow-mapping : $map"
          return map

    return null

  in-flow n c -> Deque?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return ns-s-flow-seq-entries n FLOW-IN_
    return ns-s-flow-seq-entries n FLOW-KEY_

  in-flow-map n c -> Deque?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return ns-s-flow-map-entries n FLOW-IN_
    return ns-s-flow-map-entries n FLOW-KEY_

  one-element-queue elm:
    q := Deque
    q.add elm
    return q

  ns-s-flow-seq-entries n c -> Deque?:
    with-rollback:
      if head := ns-flow-seq-entry n c:
        head-val := to_return_value head
        s-separate n c
        with-rollback:
          if match-char C-COLLECT-ENTRY_:
            s-separate n c
            tail := ns-s-flow-seq-entries n c
            if tail:
              tail.add-first head-val
              return tail
            return one-element-queue head-val
        return one-element-queue head-val
    return null

  ns-s-flow-map-entries n c -> Deque?:
    with-rollback:
      if head := ns-flow-map-entry n c:
        s-separate n c
        with-rollback:
          if match-char C-COLLECT-ENTRY_:
            s-separate n c
            tail := ns-s-flow-map-entries n c
            if tail:
              tail.add-first head
              return tail
            return one-element-queue head
        return one-element-queue head
    return null

  ns-flow-seq-entry n c:
    if res := ns-flow-pair n c: return res
    if res := ns-flow-node n c: print "FN: $res"; return res
    return null

  ns-flow-map-entry n c:
    with-rollback:
      if match-char C-MAPPING-KEY_  and
         s-separate n c:
        if res := ns-flow-map-explicit-entry n c: return res
    if res := ns-flow-map-implicit-entry n c: return res
    return null

  ns-flow-pair n c:
    with-rollback:
      if match-char C-MAPPING-KEY_ and s-separate n c:
        if res := ns-flow-map-explicit-entry n c:
          return { res[0]: res[1] }
    if res := ns-flow-pair-entry n c:
      return { res[0]: res[1] }
    return null

  ns-flow-map-explicit-entry n c -> List?:
    if res := ns-flow-map-implicit-entry n c: return res
    return [null, null]

  ns-flow-map-implicit-entry n c -> List?:
    if tmp := ns-flow-map-yaml-key-entry n c: return tmp
    if tmp := c-ns-flow-map-empty-key-entry n c: return tmp
    if tmp := c-ns-flow-map-json-key-entry n c: return tmp
    return null

  ns-flow-pair-entry n c -> List?:
    if res := ns-flow-pair-yaml-key-entry n c: return res
    if res := c-ns-flow-map-empty-key-entry n c: return res
    if res := c-ns-flow-pair-json-key-entry n c: return res
    return null

  ns-flow-pair-yaml-key-entry n c -> List?:
    with-rollback:
      if key := ns-s-implicit-yaml-key FLOW-KEY_:
        if val := c-ns-flow-map-separate-value n c:
          return [to_return_value key, to_return_value val]
    return null

  c-ns-flow-pair-json-key-entry n c -> List?:
    with-rollback:
      if key := c-s-implicit-json-key FLOW-KEY_:
        if val := c-ns-flow-map-adjacent-value n c:
          return [to_return_value key, to_return_value val]
    return null

  c-ns-flow-map-json-key-entry n c -> List?:
    with-rollback:
      if key := c-flow-json-node n c:
        val := optional: optional: s-separate n c; c-ns-flow-map-adjacent-value n c
        return [to_return_value key, to_return_value val]
    return null

  c-ns-flow-map-adjacent-value n c:
    with-rollback:
      if match-char C-MAPPING-VALUE_:
        val := optional: optional: s-separate n c; ns-flow-node n c
        return val or NULL-VALUE_
    return null

  ns-s-implicit-yaml-key c:
    if res := ns-flow-yaml-node 0 c:
      s-separate-in-line
      return res
    return null

  ns-flow-map-yaml-key-entry n c -> List?:
    with-rollback:
      if key := ns-flow-yaml-node n c:
        val := optional: (optional: s-separate n c); c-ns-flow-map-separate-value n c
        return [to_return_value key, to_return_value val]
    return null

  c-ns-flow-map-empty-key-entry n c -> List?:
    if val := c-ns-flow-map-separate-value n c: return [null, to_return_value val]
    return null

  c-ns-flow-map-separate-value n c:
    with-rollback:
      if match-char C-MAPPING-VALUE_ and
         (lookahead: not ns-plain-safe c):
        with-rollback:
          if s-separate n c:
            if res := ns-flow-node n c: return res
        return NULL-VALUE_
    return null

  ns-plain n c -> string?:
    print "ns-plain $n $c "
    if c == FLOW-OUT_:  return ns-plain-multi-line n c
    if c == FLOW-IN_:   return ns-plain-multi-line n c
    if c == BLOCK-KEY_: return ns-plain-one-line c
    if c == FLOW-KEY_:  return ns-plain-one-line c
    return null

  ns-plain-one-line c -> string?:
    with-rollback:
      start := offset_
      if ns-plain-first c and nb-ns-plain-in-line c:
        return string-since start
    return null

  ns-plain-multi-line n c -> string?:
    with-rollback:
      if first := ns-plain-one-line c:
        rest := repeat: s-ns-plain-next-line n c
        print "ns-plain-multi-line: first=$first, rest=$rest :: $((flatten-list_ [first, rest]).join "")"
        return (flatten-list_ [first, rest]).join ""
    return null

  s-ns-plain-next-line n c -> string?:
    with-rollback:
      if folded := s-flow-folded n:
        if first := ns-plain-char c:
           if val := nb-ns-plain-in-line c:
             print "s-ns-plain-next-line: folded=$folded.to-byte-array, first=$(string.from-rune first), val=$val"
             return "$folded$(string.from-rune first)$val"
    return null

  s-flow-folded n -> string?:
    with-rollback:
      s-separate-in-line
      if res := b-l-folded n FLOW-IN_:
        if s-flow-line-prefix n:
          return res
    return null

  nb-ns-plain-in-line c:
    start := offset_
    repeat: (repeat: match-chars S-WHITESPACE_) and ns-plain-char c
    return string-since start

  ns-plain-semi-safe ::= { C-MAPPING-KEY_, C-MAPPING-VALUE_, C-SEQUENCE-ENTRY_ }
  ns-plain-first c:
    with-rollback:
      if rune := ns-char:
        if not C-INDICATOR_.contains rune: return true
    with-rollback:
      if (match-chars ns-plain-semi-safe and
          lookahead: ns-plain-safe c): return true
    return false

  ns-plain-char c -> int?:
    with-rollback:
      if rune := ns-plain-safe c:
        if rune != C-MAPPING-VALUE_ and rune != C-COMMENT_: return rune

    with-rollback:
      if match-char C-COMMENT_:
        //  [ lookbehind = ns-char ]
        start := offset_
        offset_ -= 2
        while offset_ > 0 and not bytes_[offset_..start- 1].is-valid-string-content:
          offset_--
        is-ns-char := ns-char
        offset_ = start
        if is-ns-char: return C-COMMENT_

    with-rollback:
      if match-char C-MAPPING-VALUE_ and
         (lookahead: ns-plain-safe c):
        return C-MAPPING-VALUE_

    return null

  ns-plain-safe c:
    if c == FLOW-OUT_ or c == BLOCK-OUT_: return ns-plain-safe-out
    return ns-plain-safe-in

  ns-plain-safe-out: return ns-char

  ns-plain-safe-in:
    with-rollback:
      if rune := ns-char:
        if not C-FLOW-INDICATOR_.contains rune: return rune
    return false


  c-ns-properties n c -> List?:
    with-rollback:
      if tag := c-ns-tag-property:
        anchor := optional --or-null: if s-separate n c: c-ns-anchor-property; false
        return [tag, anchor]
    with-rollback:
      if anchor := c-ns-anchor-property:
        tag := optional --or-null: if s-separate n c: c-ns-tag-property; false
        return [tag, anchor]
    return null

  c-ns-tag-property: // TODO: Return more structural information about the tags
    if res := c-verbatim-tag: return res
    if res := c-ns-shorthand-tag: return res
    if res := c-non-specific-tag: return res
    return null

  c-verbatim-tag:
    start := offset_
    with-rollback:
      if match-string "!<" and (repeat --at-least-one: ns-uri-char) and match-char '>':
        return string-since start
    return null

  c-ns-shorthand-tag:
    start := offset_
    with-rollback:
      if c-tag-handle and (repeat --at-least-one: ns-tag-char):
        return string-since start
    return null

  c-non-specific-tag:
    if match-char C-TAG_: return "!"
    return null

  c-ns-anchor-property -> string?:
    with-rollback:
      if match-char C-ANCHOR_:
        if res := ns-anchor-name:
          return res
    return null

  ns-anchor-name -> string?:
    start := offset_
    with-rollback:
      if (repeat --at-least-one: ns-anchor-char):
        return string-since start
    return null

  c-l-plus-literal n:
    with-rollback:
      if match-char C-LITERAL_:
        if t := c-b-block-header:
          spaces := find-leading-spaces-on-first-non-empty-line
          if res := l-literal-content spaces - t[1] t[0]:
            print "c-l-plus-literal: t=$t $res"
            return res.join ""
    return null

  c-l-plus-folded n:
    with-rollback:
      if match-char C-FOLDED_:
        t := c-b-block-header
        spaces := find-leading-spaces-on-first-non-empty-line
        if res := l-folded-content spaces - t[1] t[0]:
          return res.join ""
    return null

  c-b-block-header:
    with-rollback:
      indent-char := match-range '1' '9'
      chomp-char := match-chars { '-', '+' }
      if not indent-char: indent-char = match-range '1' '9'
      if s-b-comment:
        chomp := CLIP_
        if chomp-char == '-': chomp = STRIP_
        else if chomp-char == '+': chomp = KEEP_

        indent := 0
        if indent-char: indent = indent-char - '0'
        print "c-b-block-header: chomp=$chomp, indent=$indent"
        return [ chomp, indent ]
    return null

  l-literal-content n t -> List?:
    with-rollback:
      content := optional --or-null:
        res/List? := null
        if first := l-nb-literal-text n:
          next := repeat: b-nb-literal-next n
          print "NEXT=$next"
          if chomped-last := b-chomped-last t:
            res = flatten-list_ [first, next, chomped-last]
        res
      print "l-literal-content: content=$content "
      if chomped-empty := l-chomped-empty n t:
        print "l-literal-content: t=$t chomped-empty=$chomped-empty "
        if content: return flatten-list_ [content, chomped-empty]
        else: return chomped-empty
    return null

  l-folded-content n t -> List?:
    with-rollback:
      content := optional --or-null:
        res/List? := null
        if tmp := l-nb-diff-lines n:
          if chomped-last := b-chomped-last t:
            res = flatten-list_ [tmp, chomped-last]
        res

      if res := l-chomped-empty n t:
        if content: return flatten-list_ [content, res]
        else: return res
    return null

  b-chomped-last t -> string?:
    if t == STRIP_: if b-non-content: return ""
    if b-as-line-feed: return "\n"
    return null

  l-chomped-empty n t -> List?:
    if t == KEEP_: return l-keep-empty n
    return l-strip-empty n

  l-keep-empty n -> List?:
    res := repeat: l-empty n BLOCK-IN_
    optional: l-trail-comments n
    print "l-keep-empty, $res.size"
    if res: return List res.size "\n"
    return []

  l-strip-empty n -> List?:
    repeat: s-indent-less-or-equals n and (b-non-content or l-eof)
    optional: l-trail-comments n
    return []

  l-nb-literal-text n:
    with-rollback:
      empty-lines := repeat: l-empty n BLOCK-IN_
      if s-indent n:
        start := offset_
        if (repeat --at-least-one: nb-char):
          prefix := string.from-runes (List empty-lines.size '\n')
          return "$prefix$(string-since start)"
    return null

  b-nb-literal-next n:
    with-rollback:
      if b-as-line-feed:
        if res := l-nb-literal-text n: return "\n$res"
    return null

  l-nb-diff-lines n -> List?:
    with-rollback:
      if first := l-nb-same-lines n:
        rest := repeat:
          result := null
          if b-as-line-feed:
            if tmp := l-nb-same-lines n:
              result = (flatten-list_ ["\n", tmp]).join ""
          result
        return flatten-list_ [first, rest]
    return null

  l-nb-same-lines n -> List?:
    with-rollback:
      empty-lines := repeat: l-empty n BLOCK-IN_
      res := l-nb-folded-lines n
      if not res:
        res = l-nb-spaced-lines n
        print "SPACED:::: $res"
      if res:
        lines := flatten-list_ [List empty-lines.size "\n", res]
        print "LINES:::: $lines, $empty-lines.size"
        return lines
    return null

  l-nb-folded-lines n -> List?:
    with-rollback:
      if first := s-nb-folded-text n:
        rest := repeat:
          result/string? := null
          if folded := b-l-folded n BLOCK-IN_:
            if tmp := s-nb-folded-text n:
              result = "$folded$tmp"
          result
        return flatten-list_ [first, rest]
    return null

  s-nb-folded-text n:
    with-rollback:
      if s-indent n:
        start := offset_
        if ns-char and (repeat: nb-char):
          return string-since start
    return null

  b-l-folded n c -> string?:
    print "b-l-folded, rest of input: ||$(bytes_[offset_..].to-string)||"
    if tmp := b-l-trimmed n c: print "b-l-folded, tmp=$tmp"; return string.from-runes (List tmp '\n')
    if b-as-space: return " "
    return null

  l-nb-spaced-lines n -> List?:
    with-rollback:
      if first := s-nb-spaced-text n:
        rest := repeat:
          result/string? := null
          if space := b-l-spaced n:
            if tmp := s-nb-spaced-text n:
              result = "$space$tmp"
          result
        return flatten-list_ [first, rest]
    return null

  s-nb-spaced-text n -> string?:
    with-rollback:
      if s-indent n:
        start := offset_
        if match-chars S-WHITESPACE_  and (repeat: nb-char):
          return string-since start
    return null

  b-l-spaced n -> string?:
    with-rollback:
      if b-as-line-feed:
        empty-lines := (repeat: l-empty n BLOCK-IN_)
        return string.from-runes (List empty-lines.size + 1 '\n')
    return null

  b-l-trimmed n c -> int?:
    with-rollback:
      if b-non-content:
        if res := (repeat --at-least-one: l-empty n c):
          return res.size
    return null

  // Escaped strings
  c-single-quoted n c -> string?:
    with-rollback:
      if match-char C-SINGLE-QUOTE_:
        if res := nb-single-text n c:
          if match-char C-SINGLE-QUOTE_:
            return res.replace --all "''" "'"
    return null

  c-double-quoted n c -> string?:
    with-rollback:
      if match-char C-DOUBLE-QUOTE_:
        if res := nb-double-text n c:
          print "c-double-quoted: remaining=$(bytes_[offset_..].to-string)"
          if match-char C-DOUBLE-QUOTE_:
            print "c-double-quoted: $res"
            return res.join ""
    return null

  nb-single-text n c -> string?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return nb-single-multi-line n c
    return nb-single-one-line n c

  nb-double-text n c -> List?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return nb-double-multi-line n c
    return nb-double-one-line n c

  nb-single-multi-line n c -> string?:
    with-rollback:
      if res := nb-ns-single-in-line:
        if next := s-single-next-line n:
          print "nb-single-multi-line: res=$res, next=$next"
          return "$res$(next.join "")"
        else:
          start := offset_
          repeat: match-chars S-WHITESPACE_
          return "$res$(string-since start)"
    return null

  nb-single-one-line n c -> string:
    start := offset_
    repeat: nb-single-char
    return string-since start

  nb-double-multi-line n c -> List?:
    with-rollback:
      if res := nb-ns-double-in-line:
        print "nb-double-multi-line: res=|$res|"
        if next := s-double-next-line n:
          print "nb-double-multi-line: next=|$next|"
          return flatten-list_ [res,  next]
        else:
          start := offset_
          repeat: s-white
          return [res, string-since start]
    return null

  nb-double-one-line n c -> List:
    runes := repeat: nb-double-char
    print runes
    return [ string.from-runes runes ]

  nb-ns-single-in-line -> string:
    start := offset_
    repeat: (repeat: s-white) and ns-single-char
    return string-since start

  s-single-next-line n -> List?:
    with-rollback:
      if folded := s-flow-folded n:
        with-rollback:
          start := offset_
          if first := ns-single-char:
            if line := nb-ns-single-in-line:
              print " s-single-next-line: folded=$folded.to-byte-array, line=|$line|"
              tmp := [ folded, string.from-rune first, line ]
              if rest := s-single-next-line n:
                tmp.add-all rest
              else:
                start = offset_
                repeat: s-white
                tmp.add (string-since start)
              return tmp
        return [folded]
    return null

  nb-ns-double-in-line -> string:
    runes/List := []
    repeat: 
      white := repeat: s-white
      rune := ns-double-char
      if rune:
        runes.add-all white
        runes.add rune
      rune
    return string.from-runes runes

  s-double-next-line n -> List?:
    with-rollback:
      if breaks := s-double-break n:
        with-rollback:
          if first-rune := ns-double-char:
            if line := nb-ns-double-in-line:
              print "s-double-next-line: breaks=$breaks, first-rune:$(string.from-rune first_rune), line=$line"
              tmp := ["$(string.from-runes (flatten-list_ [breaks, first-rune]))$line"]
              if rest := s-double-next-line n:
                tmp.add-all rest
              else:
                start := offset_
                repeat: s-white
                tmp.add (string-since start)
              return tmp
        return [string.from-runes breaks]
    return null

  s-double-break n -> List?:
    if res := s-double-esscaped n: return res
    if res := s-flow-folded n:
      runes := List
      res.do --runes: runes.add it
      return runes
    return null

  s-double-esscaped n -> List?:
    with-rollback:
      white-spaces := repeat: s-white
      if match-char C-ESCAPE_ and
         b-non-content and
         (repeat: l-empty n FLOW-IN_) and
         s-flow-line-prefix n:
        return white-spaces
    return null

  ns-single-char -> int?:
    with-rollback:
      if not s-white:
        if rune := nb-single-char:
          return rune
    return null

  nb-single-char -> int?:
    with-rollback:
      if rune := c-quoted-quote: return '\''
      if rune := nb-json:
        if rune != C-SINGLE-QUOTE_: return rune
    return null

  ns-double-char -> int?:
    with-rollback:
      if not s-white:
        if res := nb-double-char:
          return res
    return null

  nb-double-char -> int?:
    if res := c-ns-esc-char: return res
    with-rollback:
      if res := nb-json:
        if res != C-ESCAPE_ and res != C-DOUBLE-QUOTE_: return res
    return null

  c-ns-esc-char -> int?:
    with-rollback:
      if match-char C-ESCAPE_:
        if match-char '0': return 0
        if match-char 'a': return '\a'
        if match-char 'b': return '\b'
        if match-char 't': return '\t'
        if match-char '\t': return '\t'
        if match-char 'n': return '\n'
        if match-char 'v': return '\v'
        if match-char 'f': return '\f'
        if match-char 'r': return '\r'
        if match-char 'e': return 0x18
        if match-char ' ': return ' '
        if match-char '"': return '"'
        if match-char '/': return '/'
        if match-char '\\': return '\\'
        if match-char 'N': return 0x85
        if match-char '_': return 0xa0
        if match-char 'L': return 0x2028
        if match-char 'P': return 0x2029
        if match-char 'x': if res := match-hex 2: return res
        if match-char 'u':
          if res := match-hex 4:
            if 0xd800 <= res <= 0xdbff:
              if part-2 := c-ns-esc-char:
                 if not 0xdc00 <= part-2 <= 0xdfff: throw "INVALID_SURROGATE_PAIR"
                 return 0x10000 + ((res & 0x3ff) << 10) | (part-2 & 0x3ff)
            else:
              return res
        if match-char 'U': if res := match-hex 8: return res
    return null

  // Space
  b-as-space: return b-break

  b-as-line-feed: return b-break

  l-empty n c:
    with-rollback:
      if (s-line-prefix n c or s-indent-less-than n) and b-as-line-feed:
        return true
    return false

  s-line-prefix n c:
    if c == BLOCK-OUT_ or c == BLOCK-IN_: return s-block-line-prefix n
    else: return s-flow-line-prefix n

  s-separate n c:
    if c == BLOCK-KEY_ or c == FLOW-KEY_: return s-separate-in-line
    return s-separate-lines n

  s-separate-lines n:
    with-rollback:
      if s-l-comments and s-flow-line-prefix n: return true
    return s-separate-in-line

  s-flow-line-prefix n:
    return s-indent n and (optional: s-separate-in-line)

  s-block-line-prefix n:
    return s-indent n

  s-indent n --auto-detect-m/bool=false -> int?:
    mark := mark
    for i := 0; i < n; i++:
      if not match-char S-SPACE_:
        rollback mark
        return null

    if auto-detect-m:
      m := 0
      while match-char S-SPACE_: m++
      return m

    return 0

  s-indent-less-or-equals n:
    while n-- > 0 and match-char S-SPACE_:
    return true

  s-indent-less-than n:
    return s-indent-less-or-equals n - 1

  // Lexigraphical productions
  b-break:
    if match-buffer #[B-CARRIAGE_RETURN_, B-LINE-FEED_]: return true
    if match-char B-CARRIAGE_RETURN_: return true
    if match-char B-LINE-FEED_: return true
    return false

  c-byte-order-mark -> bool:
    if can-read 2:
      if match-buffer #[0xFE, 0xFF] or
          match-buffer #[0xFF, 0xFE] or
          bytes_[offset_] == 0 or
          bytes_[offset_ + 1] == 0:
        throw "UNSUPPORTED_BYTE_ORDER"
    if can-read 3 and match-buffer #[0xEF, 0xBB, 0xBF]:
      return true
    return true

  s-white -> int?:
    if res := match-chars S-WHITESPACE_: return res
    return null

  c-comment:
    return match-char C-COMMENT_

  c-quoted-quote:
    return match-string "''"

  nb-char:
    with-rollback:
      if rune := c-printable:
        if not is-break rune and not rune == C-BYTE-ORDER-MARK_:
          return rune
    return false

  nb-json -> int?:
    with-rollback:
      rune := utf-rune
      if rune and (rune == 0x09 or 0x20 <= rune and rune <= 0x10FFFF):
        return rune
    return null

  ns-dec-digit:
    return match-one: '0' <= it and it <= '9'

  ns-hex-digit:
    if ns-dec-digit: return true
    return match-range 'A' 'F' or match-range 'a' 'f'

  ns-ascii-letter:
    return match-range 'A' 'Z' or match-range 'a' 'z'

  ns-word-char:
    if ns-dec-digit: return true
    if ns-ascii-letter: return true
    return match-one: it == '-'

  ns-tag-char:
    with-rollback:
      if char := ns-uri-char:
        if char != C-TAG_ and not C-FLOW-INDICATOR_.contains char:
          return true
    return false

  ns-special-uri ::= {
      '#', ';', '/', '?', ':', '@', '&', '=', '+',
      '$', ',', '-', '.', '!', '~', '*', '\'', '(', ')',
      '[', ']'
  }

  ns-uri-char:
    if (match-char '%' and
        ns-hex-digit and
        ns-hex-digit): return true
    if (ns-word-char or
        match-chars ns-special-uri): return bytes_[offset_ - 1]
    return false

  ns-anchor-char:
    with-rollback:
      if rune := ns-char:
        if not C-FLOW-INDICATOR_.contains rune: return true
    return false

  ns-char -> int?:
    with-rollback:
      if rune := nb-char:
        if not S-WHITESPACE_.contains rune: return rune
    return null

  is-break rune:
    return rune == B-LINE-FEED_ or rune == B-CARRIAGE_RETURN_

  c-special-printable ::= { S-TAB_, B-CARRIAGE_RETURN_, B-LINE-FEED_, 0x85}
  c-printable -> int?:
    with-rollback:
      if rune := utf-rune:
        if 0x20 <= rune and rune<= 0x7E: return rune
        if c-special-printable.contains rune: return rune
        if 0xA0 <= rune and rune <= 0xD7FF: return rune
        if 0xE000 <= rune and rune <= 0xFFFD: return rune
        if 0x010000 <= rune and rune <= 0x10FFFF: return rune
    return null

  utf-rune -> int?:
    if can-read 1:
      c := bytes_[offset_]
      if c < 0xc0:
        offset_++
        return c

      bytes := 2
      if c >= 0xf0:
        bytes = 4
      else if c >= 0xe0:
        bytes = 3

      if can_read bytes:
        buf/ByteArray := slice bytes
        if buf.is-valid-string-content:
          offset_ += bytes
          return buf.to-string[0]

    return null