// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// This parser follows the grammar of the YAML 1.2.2 draft.
// The grammar is almost a PEG grammar (except for one lookbehind).

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

empty-node_ ::= ValueNode_ null

one-element-queue_ elm -> Deque:
  q := Deque
  q.add elm
  return q

keys-as-set_ map/Map -> Set:
   set := Set
   map.do --keys: set.add it
   return set

class ValueNode_:
  tag/string? := null
  value/any
  constructor .value:

  constructor.map-from-collection collection/Collection:
    value = Map
    collection.do: value[it[0]] = it[1]

  // Either use the supplied tag to construct a toit object representing the value or use
  // the core schema tag resolution
  resolve -> any:
    model-value := canonical-value
    if tag:
      if tag == "!!str" and value is string:
        return value
      if tag == "!!float" and model-value is int:
        return model-value.to-float

    return model-value

  static NULL     ::= { "null", "NULL", "Null", "~" }
  static TRUE     ::= { "true", "True", "TRUE" }
  static FALSE    ::= { "false", "False", "FALSE" }
  static INFINITY ::= { ".inf", ".Inf", ".INF"  }
  static NAN      ::= { ".nan", ".Nan", ".NAN" }

  canonical-value -> any:
    if this == empty-node_: return null

    if value is string:
      if NULL.contains value: return null
      if TRUE.contains value: return true
      if FALSE.contains value: return false

      catch:
        return int.parse value

      catch:
        return float.parse value

      if INFINITY.contains value or
         value.size > 1 and value[0] == '+' and INFINITY.contains value[1..]:
        return float.INFINITY

      if value.size > 1 and value[0] == '-' and INFINITY.contains value[1..]:
        return -float.INFINITY

      if NAN.contains value: return float.NAN

      catch:
        if value.starts-with "0x":
          return int.parse --radix=16 value[2..]

      catch:
        if value.starts-with "0o":
          return int.parse --radix=8 value[2..]

    if value is List:
      return value.map: | node/ValueNode_ | node.resolve

    if value is Map:
      map := Map
      value.do:| key/ValueNode_  value/ValueNode_| map[key.resolve] = value.resolve
      return map

    return value

  hash-code:
    return value.hash-code

  stringify: return "VN: $value.stringify"

class Parser_:
  bytes_/ByteArray
  offset_/int := 0
  named-nodes := {:}
  forbidden-detected/int? := null

  constructor .bytes_:

  // As a peg grammar is top-down, the parser needs to be able to rollback
  mark -> any:
    return offset_

  rollback mark -> none:
    offset_ = mark

  at-mark mark -> bool:
    return offset_ == mark

  with-rollback [block] -> none:
    mark := mark
    block.call
    rollback mark

  lookahead [block] -> bool:
    result := false
    with-rollback: result = block.call
    return not (not result)

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

  optional --or-null/bool=false [block] -> any:
    with-rollback:
      if res := block.call: return res

    return or-null?null:empty-node_

  can-read num/int -> bool:
    return offset_ + num <= bytes_.size
           and (not forbidden-detected or offset_ + num <= forbidden-detected)

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

  match-char byte/int -> int?:
    return match-one: it == byte

  match-chars chars/Set -> int?:
    return match-one: chars.contains it

  match-range from/int to/int -> int?:
    return match-one: from <= it and it <= to

  match-buffer buf/ByteArray -> bool:
    return match-many buf.size: (slice buf.size) == buf

  match-string str/string -> bool:
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
    
  string-since start -> string:
    return bytes_[start .. offset_].to_string

  apply-props props value/ValueNode_ -> ValueNode_:
    tag/string? := null
    if props:
      tag = props[0]
      anchor := props[1]
      if anchor: named-nodes[anchor] = value
    value.tag = tag
    return value

  detect-forbidden:
    if forbidden-detected: return
    mark := offset_
    if start-of-line and
       (c-directives-end or c-document-end) and
       (match-chars B-LINE-TERMINATORS_ or s-white or l-eof):
      forbidden-detected = mark
    rollback mark

  find-leading-spaces-on-first-non-empty-line -> int:
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

    return result

  // Overall structure
  l-yaml-stream -> List:
    k := repeat: l-document-prefix
    documents := []
    if document := l-any-document: documents.add document

    repeat: l-yaml-stream-helper documents

    if not l-eof:
      throw "INVALID_YAML_DOCUMENT"
    return documents.map: | node/ValueNode_ | node.resolve

  l-yaml-stream-helper documents/List -> bool:
    with-rollback:
      if (repeat --at-least-one: l-document-suffix):
        repeat: l-document-prefix
        if document := l-any-document: documents.add document
        return true

    if c-byte-order-mark: return true
    if l-comment: return true
    if document := l-explicit-document:
      documents.add document
      return true

    return false

  l-any-document -> ValueNode_?:
    with-rollback:
      if document := l-directive-document: return document
      if document := l-explicit-document: return document
      if document := l-bare-document: return document
    return null

  l-directive-document -> ValueNode_?:
    with-rollback:
      repeat --at-least-one: l-directive
      if res := l-explicit-document:
        return res

    return null

  l-explicit-document -> ValueNode_?:
    with-rollback:
      if c-directives-end:
        if res := l-bare-document: return res
        if s-l-comments: empty-node_
    return null

  l-bare-document -> ValueNode_?:
    with-rollback:
      if res := s-l-plus-block-node -1 BLOCK-IN_: return res
    return null

  l-document-prefix -> bool:
    c-byte-order-mark
    repeat: l-comment
    return true

  l-document-suffix -> bool:
    if not c-document-end: return false
    if not s-l-comments: return false
    return true

  allow-forbidden-read [block]:
    old-forbidden-detected := forbidden-detected
    forbidden-detected = null
    block.call
    forbidden-detected = old-forbidden-detected

  c-document-end -> bool:
    allow-forbidden-read:
      if match-string "...": return true
    return false

  c-directives-end -> bool:
    allow-forbidden-read:
      if match-string "---": return true
    return false

  // Directives
  l-directive -> bool:
    with-rollback:
      if match-char C-DIRECTIVE_ and
         (ns-yaml-directive or
          ns-tag-directive or
          ns-reserved-directive) and
         s-l-comments:
        return true
    return false

  ns-yaml-directive -> bool:
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

  ns-tag-directive -> bool:
    with-rollback:
      if match-string "TAG" and
         s-separate-in-line and
         c-tag-handle and
         s-separate-in-line and
         ns-tag-prefix:
        return true
    return false

  c-tag-handle -> bool:
    with-rollback:
      if c-named-tag-handle or
          match-string "!!"  or
          match-char C-TAG_:
        return true
    return false

  c-named-tag-handle -> bool:
    with-rollback:
      if  match-char C-TAG_ and
         (repeat --at-least-one : ns-word-char) and
          match-char C-TAG_:
        return true
    return false

  ns-tag-prefix -> bool:
    if c-ns-local-tag-prefix or
       ns-global-tag-prefix:
      return true
    return false

  c-ns-local-tag-prefix -> bool:
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

  ns-directive-name -> List?:
    return repeat --at-least-one: ns-char

  ns-directive-parameter -> List?:
    return repeat --at-least-one: ns-char

  // comments
  l-comment -> bool:
    with-rollback:
      if s-separate-in-line:
        c-nb-comment-text
        if b-comment: return true
    return false

  s-l-comments -> bool:
    with-rollback:
      if s-b-comment or start-of-line:
        repeat: l-comment
        return true
    return false

  s-b-comment -> bool:
    with-rollback:
      optional: if s-separate-in-line: (optional: c-nb-comment-text)
      if b-comment: return true
    return false

  s-separate-in-line -> bool:
    with-rollback:
      if (repeat --at-least-one: s-white): return true
      if start-of-line: return true
    return false

  c-nb-comment-text -> bool:
    if c-comment:
      repeat: nb-char
      return true
    return false

  b-comment -> bool:
    with-rollback:
      if b-non-content: return true
    return l-eof

  b-non-content -> bool:
    return b-break

  l-trail-comments n -> bool:
    with-rollback:
      if (s-indent-less-than n and
          c-nb-comment-text and
          b-comment and
          (repeat: l-comment)): return true
    return false

  // Data part
  s-l-plus-block-node n c -> ValueNode_?:
    if node := s-l-plus-block-in-block n c: return node
    if node := s-l-plus-flow-in-block n: return node
    return null

  s-l-plus-block-in-block n c -> ValueNode_?:
    if node := s-l-plus-block-scalar n c: return node
    if node := s-l-plus-block-collection n c: return node
    return null

  s-l-plus-flow-in-block n -> ValueNode_?:
    with-rollback:
      if s-separate n + 1 FLOW-OUT_:
        if node := ns-flow-node n + 1 FLOW-OUT_:
          if s-l-comments:
            return node
    return null

  s-l-plus-block-collection n c -> ValueNode_?:
    with-rollback:
      props := optional --or-null: if s-separate n + 1 c: c-ns-properties n + 1 c
      if s-l-comments:
        if node := seq-space n c: return apply-props props node
        if node := l-plus-block-mapping n c: return apply-props props node
    return null

  s-l-plus-block-scalar n c -> ValueNode_?:
    with-rollback:
      if s-separate n + 1 c:
        props := optional --or-null: if p := c-ns-properties n + 1 c and s-separate n + 1 c: p
        node := c-l-plus-literal n
        if not node: node = c-l-plus-folded n
        if node: return apply-props props (ValueNode_ node)
    return null

  seq-space n c -> ValueNode_?:
    if c == BLOCK-OUT_: return l-plus-block-sequence n - 1
    if c == BLOCK-IN_: return l-plus-block-sequence n
    return null

  l-plus-block-sequence n -> ValueNode_?:
    with-rollback:
      if m := s-indent n + 1 --auto-detect-m:
        if first := c-l-block-seq-entry n + 1 + m:
          rest := repeat:
            node := null
            if s-indent n + 1 + m:
              if tmp :=  c-l-block-seq-entry n + 1 + m:
                node = tmp
            node
          return ValueNode_ (flatten-list_ [first, rest])
    return null

  l-plus-block-mapping n c -> ValueNode_?:
    with-rollback:
      if m := s-indent n + 1 --auto-detect-m:
        if first := ns-l-block-map-entry n + 1 + m:
          rest := repeat:
            entry := null
            if s-indent n + 1 + m:
              if tmp := ns-l-block-map-entry n + 1 + m:
                entry = tmp
            entry
          return ValueNode_.map-from-collection (flatten-list_ [[first], rest])
    return null

  c-l-block-seq-entry n -> ValueNode_?:
    with-rollback:
      if match-char C-SEQUENCE-ENTRY_:
        if (lookahead: not ns-char):
          if node := s-l-plus-block-indented n BLOCK-IN_:
            return node
    return null

  s-l-plus-block-indented n c -> ValueNode_?:
    with-rollback:
      if m := s-indent 0 --auto-detect-m:
        if node := ns-l-compact-sequence n + 1 + m: return node
        if node := ns-l-compact-mapping n + 1 + m: return node

    if res := s-l-plus-block-node n c: return res

    if s-l-comments: return empty-node_

    return null

  ns-l-compact-sequence n -> ValueNode_?:
    with-rollback:
      if first := c-l-block-seq-entry n:
        rest := repeat:
          entry := null
          if s-indent n:
            if tmp := c-l-block-seq-entry n:
              entry = tmp
          entry
        return ValueNode_ (flatten-list_ [first, rest])
    return null

  ns-l-compact-mapping n -> ValueNode_?:
    with-rollback:
      if first := ns-l-block-map-entry n:
        rest := repeat:
          entry := null
          if s-indent n:
            if tmp := ns-l-block-map-entry n:
              entry = tmp
          entry
        return ValueNode_.map-from-collection (flatten-list_ [[first], rest])
    return null

  ns-l-block-map-entry n -> List?:
    if entry := c-l-block-map-explicit-entry n: return entry
    if entry := ns-l-block-map-implicit-entry n: return entry
    return null

  c-l-block-map-explicit-entry n -> List?:
    with-rollback:
      if key := c-l-block-map-explicit-key n:
        if val := l-block-map-explicit-value n:
          return [key, val]
        else:
          return [key, null]
    return null

  c-l-block-map-explicit-key n -> ValueNode_?:
    with-rollback:
      if match-char C-MAPPING_KEY_:
        if node := s-l-plus-block-indented n BLOCK-OUT_: return node
    return null

  l-block-map-explicit-value n -> ValueNode_?:
    with-rollback:
      if s-indent n and match-char C-MAPPING-VALUE_:
        if node := s-l-plus-block-indented n BLOCK-OUT_: return node
    return null

  ns-l-block-map-implicit-entry n -> List?:
    with-rollback:
      key := ns-s-block-map-implicit-key
      if not key: key = empty_node_
      if val := c-l-block-map-implicit-value n:
        return [key, val]
    return null

  ns-s-block-map-implicit-key -> ValueNode_?:
    if node := c-s-implicit-json-key BLOCK-KEY_: return node
    if node := ns-s-implicit-yaml-key BLOCK-KEY_: return node
    return null

  c-l-block-map-implicit-value n -> ValueNode_?:
    with-rollback:
      if match-char C-MAPPING-VALUE_:
        if node := s-l-plus-block-node n BLOCK-OUT_: return node
        if s-l-comments: return empty_node_
    return null

  c-s-implicit-json-key c -> ValueNode_?:
    with-rollback:
      if node := c-flow-json-node 0 c:
        s-separate-in-line
        return node
    return null

  ns-flow-yaml-node n c -> ValueNode_?:
    if node := c-ns-alias-node: return node
    if node := ns-flow-yaml-content n c: return node
    with-rollback:
      if props := c-ns-properties n c:
        with-rollback:
          if s-separate n c:
            if node := ns-flow-yaml-content n c: return apply-props props node
        return empty-node_
    return null

  c-flow-json-node n c -> ValueNode_?:
    with-rollback:
      props := optional --or-null: if p := c-ns-properties n c: if s-separate n c: p
      if node := c-flow-json-content n c:
        return apply-props props node
    return null

  ns-flow-node n c -> ValueNode_?:
    if node := c-ns-alias-node: return node
    if node := ns-flow-content n c: return node
    with-rollback:
      if props := c-ns-properties n c:
        with-rollback:
          if s-separate n c:
            if node := ns-flow-content n c: return apply-props props node
        return empty-node_
    return null

  c-ns-alias-node -> ValueNode_?:
    with-rollback:
      if match-char C-ALIAS_:
        if anchor := ns-anchor-name:
          if not named-nodes.contains anchor: throw "UNRESOLVED_ALIAS"
          return named-nodes[anchor]
    return null

  ns-flow-content n c -> ValueNode_?:
    if node := ns-flow-yaml-content n c: return node
    if node := c-flow-json-content n c: return node
    return null

  c-flow-json-content n c -> ValueNode_?:
    if node := c-flow-sequence n c: return node
    if node := c-flow-mapping n c: return node
    if node := c-single-quoted n c: return node
    if node := c-double-quoted n c: return node
    return null

  ns-flow-yaml-content n c -> ValueNode_?:
    if content := ns-plain n c: return ValueNode_ content
    return null

  c-flow-sequence n c -> ValueNode_?:
    with-rollback:
      if match-char C-SEQUENCE-START_:
        optional: s-separate n c
        res := in-flow n c
        if match-char C-SEQUENCE-END_:
          return ValueNode_ ( res ? List.from res : [] )
    return null

  c-flow-mapping n c -> ValueNode_?:
    with-rollback:
      if match-char C-MAPPING-START_:
        optional: s-separate n c
        map-entries := in-flow-map n c // See https://github.com/yaml/yaml-spec/issues/299
        if match-char C-MAPPING-END_:
          return ValueNode_.map-from-collection ( map-entries ? map-entries : [])
    return null

  in-flow n c -> Deque?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return ns-s-flow-seq-entries n FLOW-IN_
    return ns-s-flow-seq-entries n FLOW-KEY_

  in-flow-map n c -> Deque?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return ns-s-flow-map-entries n FLOW-IN_
    return ns-s-flow-map-entries n FLOW-KEY_

  flow-entries n c [--head] [--tail] -> Deque?:
    with-rollback:
      if head-entry := head.call:
        s-separate n c
        with-rollback:
          if match-char C-COLLECT-ENTRY_:
            s-separate n c
            if tail-entries := tail.call:
              tail-entries.add-first head-entry
              return tail-entries
            return one-element-queue_ head-entry
        return one-element-queue_ head-entry
    return null


  ns-s-flow-seq-entries n c -> Deque?:
    return flow-entries n c
      --head=: ns-flow-seq-entry n c
      --tail=: ns-s-flow-seq-entries n c

  ns-s-flow-map-entries n c -> Deque?:
    return flow-entries n c
      --head=: ns-flow-map-entry n c
      --tail=: ns-s-flow-map-entries n c

  ns-flow-seq-entry n c -> ValueNode_?:
    if pair := ns-flow-pair n c: return pair
    if node := ns-flow-node n c: return node
    return null

  ns-flow-map-entry n c -> List?:
    with-rollback:
      if match-char C-MAPPING-KEY_  and
         s-separate n c:
        if entry := ns-flow-map-explicit-entry n c: return entry
    if entry := ns-flow-map-implicit-entry n c: return entry
    return null

  ns-flow-pair n c -> ValueNode_?:
    with-rollback:
      if match-char C-MAPPING-KEY_ and s-separate n c:
        if entry := ns-flow-map-explicit-entry n c:
          return ValueNode_.map-from-collection [entry]
    if entry := ns-flow-pair-entry n c:
      return ValueNode_.map-from-collection [entry]
    return null

  ns-flow-map-explicit-entry n c -> List?:
    if entry := ns-flow-map-implicit-entry n c: return entry
    return [empty-node_, empty-node_]

  ns-flow-map-implicit-entry n c -> List?:
    if entry := ns-flow-map-yaml-key-entry n c: return entry
    if entry := c-ns-flow-map-empty-key-entry n c: return entry
    if entry := c-ns-flow-map-json-key-entry n c: return entry
    return null

  ns-flow-pair-entry n c -> List?:
    if entry := ns-flow-pair-yaml-key-entry n c: return entry
    if entry := c-ns-flow-map-empty-key-entry n c: return entry
    if entry := c-ns-flow-pair-json-key-entry n c: return entry
    return null

  ns-flow-pair-yaml-key-entry n c -> List?:
    with-rollback:
      if key := ns-s-implicit-yaml-key FLOW-KEY_:
        if value := c-ns-flow-map-separate-value n c:
          return [key, value]
    return null

  c-ns-flow-pair-json-key-entry n c -> List?:
    with-rollback:
      if key := c-s-implicit-json-key FLOW-KEY_:
        if value := c-ns-flow-map-adjacent-value n c:
          return [key, value]
    return null

  c-ns-flow-map-json-key-entry n c -> List?:
    with-rollback:
      if key := c-flow-json-node n c:
        value := optional: optional: s-separate n c; c-ns-flow-map-adjacent-value n c
        return [key, value]
    return null

  c-ns-flow-map-adjacent-value n c -> ValueNode_?:
    with-rollback:
      if match-char C-MAPPING-VALUE_:
        value := optional: optional: s-separate n c; ns-flow-node n c
        return value or empty-node_
    return null

  ns-s-implicit-yaml-key c -> ValueNode_?:
    if node := ns-flow-yaml-node 0 c:
      s-separate-in-line
      return node
    return null

  ns-flow-map-yaml-key-entry n c -> List?:
    with-rollback:
      if key := ns-flow-yaml-node n c:
        value := optional: (optional: s-separate n c); c-ns-flow-map-separate-value n c
        return [key, value]
    return null

  c-ns-flow-map-empty-key-entry n c -> List?:
    if value := c-ns-flow-map-separate-value n c: return [null, value]
    return null

  c-ns-flow-map-separate-value n c -> ValueNode_?:
    with-rollback:
      if match-char C-MAPPING-VALUE_ and
         (lookahead: not ns-plain-safe c):
        with-rollback:
          if s-separate n c:
            if node := ns-flow-node n c: return node
        return empty-node_
    return null

  ns-plain n c -> string?:
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
        return (flatten-list_ [first, rest]).join ""
    return null

  s-ns-plain-next-line n c -> string?:
    with-rollback:
      if folded := s-flow-folded n:
        if first := ns-plain-char c:
          rest := nb-ns-plain-in-line c
          return "$folded$(string.from-rune first)$rest"
    return null

  s-flow-folded n -> string?:
    with-rollback:
      s-separate-in-line
      if folded := b-l-folded n FLOW-IN_:
        if s-flow-line-prefix n:
          return folded
    return null

  nb-ns-plain-in-line c -> string:
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
        while offset_ > 0 and not bytes_[offset_..start - 1].is-valid-string-content:
          offset_--
        is-ns-char := ns-char
        offset_ = start
        if is-ns-char: return C-COMMENT_

    with-rollback:
      if match-char C-MAPPING-VALUE_ and
         (lookahead: ns-plain-safe c):
        return C-MAPPING-VALUE_

    return null

  ns-plain-safe c -> int?:
    if c == FLOW-OUT_ or c == BLOCK-OUT_: return ns-plain-safe-out
    return ns-plain-safe-in

  ns-plain-safe-out: return ns-char

  ns-plain-safe-in -> int?:
    with-rollback:
      if rune := ns-char:
        if not C-FLOW-INDICATOR_.contains rune: return rune
    return null


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

  c-ns-tag-property -> string?:
    if res := c-verbatim-tag: return res
    if res := c-ns-shorthand-tag: return res
    if res := c-non-specific-tag: return res
    return null

  c-verbatim-tag -> string?:
    start := offset_
    with-rollback:
      if match-string "!<" and (repeat --at-least-one: ns-uri-char) and match-char '>':
        return string-since start
    return null

  c-ns-shorthand-tag -> string?:
    start := offset_
    with-rollback:
      if c-tag-handle and (repeat --at-least-one: ns-tag-char):
        return string-since start
    return null

  c-non-specific-tag -> string?:
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

  c-l-plus-literal n -> string?:
    with-rollback:
      if match-char C-LITERAL_:
        if t := c-b-block-header:
          spaces := find-leading-spaces-on-first-non-empty-line
          if res := l-literal-content spaces - t[1] t[0]:
            return res.join ""
    return null

  c-l-plus-folded n -> string?:
    with-rollback:
      if match-char C-FOLDED_:
        t := c-b-block-header
        spaces := find-leading-spaces-on-first-non-empty-line
        if res := l-folded-content spaces - t[1] t[0]:
          return res.join ""
    return null

  c-b-block-header -> List?:
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

        return [ chomp, indent ]
    return null

  l-literal-content n t -> List?:
    with-rollback:
      content := optional --or-null:
        res/List? := null
        if first := l-nb-literal-text n:
          next := repeat: b-nb-literal-next n
          if chomped-last := b-chomped-last t:
            res = flatten-list_ [first, next, chomped-last]
        res
      if chomped-empty := l-chomped-empty n t:
        if content: return flatten-list_ [content, chomped-empty]
        else: return chomped-empty
    return null

  l-folded-content n t -> List?:
    with-rollback:
      content := optional --or-null:
        lines/List? := null
        if tmp := l-nb-diff-lines n:
          if chomped-last := b-chomped-last t:
            lines = flatten-list_ [tmp, chomped-last]
        lines

      if chomped-empty := l-chomped-empty n t:
        if content: return flatten-list_ [content, chomped-empty]
        else: return chomped-empty
    return null

  b-chomped-last t -> string?:
    if t == STRIP_: if b-non-content: return ""
    if b-as-line-feed: return "\n"
    return null

  l-chomped-empty n t -> List?:
    if t == KEEP_: return l-keep-empty n
    return l-strip-empty n

  l-keep-empty n -> List?:
    empty-lines := repeat: l-empty n BLOCK-IN_
    optional: l-trail-comments n
    if empty-lines: return List empty-lines.size "\n"
    return []

  l-strip-empty n -> List?:
    repeat: s-indent-less-or-equals n and (b-non-content or l-eof)
    optional: l-trail-comments n
    return []

  l-nb-literal-text n -> string?:
    with-rollback:
      empty-lines := repeat: l-empty n BLOCK-IN_
      if s-indent n:
        start := offset_
        if (repeat --at-least-one: nb-char):
          prefix := string.from-runes (List empty-lines.size '\n')
          return "$prefix$(string-since start)"
    return null

  b-nb-literal-next n -> string?:
    with-rollback:
      if b-as-line-feed:
        if text := l-nb-literal-text n: return "\n$text"
    return null

  l-nb-diff-lines n -> List?:
    with-rollback:
      if first := l-nb-same-lines n:
        rest := repeat:
          content/string? := null
          if b-as-line-feed:
            if lines := l-nb-same-lines n:
              content = (flatten-list_ ["\n", lines]).join ""
          content
        return flatten-list_ [first, rest]
    return null

  l-nb-same-lines n -> List?:
    with-rollback:
      empty-lines := repeat: l-empty n BLOCK-IN_
      lines := l-nb-folded-lines n
      if not lines:
        lines = l-nb-spaced-lines n
      if lines:
        return flatten-list_ [List empty-lines.size "\n", lines]
    return null

  l-nb-folded-lines n -> List?:
    with-rollback:
      if first := s-nb-folded-text n:
        rest := repeat:
          content/string? := null
          if folded := b-l-folded n BLOCK-IN_:
            if tmp := s-nb-folded-text n:
              content = "$folded$tmp"
          content
        return flatten-list_ [first, rest]
    return null

  s-nb-folded-text n -> string?:
    with-rollback:
      if s-indent n:
        start := offset_
        if ns-char and (repeat: nb-char):
          return string-since start
    return null

  b-l-folded n c -> string?:
    if brreaks := b-l-trimmed n c: return string.from-runes (List brreaks '\n')
    if b-as-space: return " "
    return null

  l-nb-spaced-lines n -> List?:
    with-rollback:
      if first := s-nb-spaced-text n:
        rest := repeat:
          content/string? := null
          if space := b-l-spaced n:
            if text := s-nb-spaced-text n:
              content = "$space$text"
          content
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
        if empty-lines := (repeat --at-least-one: l-empty n c):
          return empty-lines.size
    return null

  // Escaped strings
  c-single-quoted n c -> ValueNode_?:
    with-rollback:
      if match-char C-SINGLE-QUOTE_:
        if res := nb-single-text n c:
          if match-char C-SINGLE-QUOTE_:
            return ValueNode_ (res.replace --all "''" "'")
    return null

  c-double-quoted n c -> ValueNode_?:
    with-rollback:
      if match-char C-DOUBLE-QUOTE_:
        if res := nb-double-text n c:
          if match-char C-DOUBLE-QUOTE_:
            return ValueNode_ (res.join "")
    return null

  nb-single-text n c -> string?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return nb-single-multi-line n c
    return nb-single-one-line n c

  nb-double-text n c -> List?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return nb-double-multi-line n c
    return nb-double-one-line n c

  nb-single-multi-line n c -> string?:
    with-rollback:
      first := nb-ns-single-in-line
      if rest := s-single-next-line n:
        return "$first$(rest.join "")"
      else:
        start := offset_
        repeat: match-chars S-WHITESPACE_
        return "$first$(string-since start)"
    return null

  nb-single-one-line n c -> string:
    start := offset_
    repeat: nb-single-char
    return string-since start

  nb-double-multi-line n c -> List?:
    with-rollback:
      first := nb-ns-double-in-line
      if rest := s-double-next-line n:
        return flatten-list_ [first,  rest]
      else:
        start := offset_
        repeat: s-white
        return [first, string-since start]
    return null

  nb-double-one-line n c -> List:
    runes := repeat: nb-double-char
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
            line := nb-ns-single-in-line
            rest/any := s-single-next-line n
            if not rest:
              start = offset_
              repeat: s-white
              rest = string-since start
            return flatten-list_ [ folded, string.from-rune first, line, rest ]
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
            line := nb-ns-double-in-line
            first := "$(string.from-runes (flatten-list_ [breaks, first-rune]))$line"
            rest/any := s-double-next-line n
            if not rest:
              start := offset_
              repeat: s-white
              rest = string-since start
            return flatten-list_ [ first, rest ]
        return [string.from-runes breaks]
    return null

  s-double-break n -> List?:
    if rune := s-double-esscaped n: return rune
    if folded := s-flow-folded n:
      runes := List
      folded.do --runes: runes.add it
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
        if rune := nb-double-char:
          return rune
    return null

  nb-double-char -> int?:
    if rune := c-ns-esc-char: return rune
    with-rollback:
      if rune := nb-json:
        if rune != C-ESCAPE_ and rune != C-DOUBLE-QUOTE_: return rune
    return null

  static SIMPLE-ESCAPES ::= { '0': 0, 'a': '\a', 'b': '\b', 't': '\t', '\t': '\t', 'n': '\n',
                              'v': '\v', 'f': '\f', 'r': '\r', 'e': 0x18, ' ': ' ', '"': '"',
                              '/': '/', '\\': '\\', 'N': 0x85, '_': 0x0a, 'L': 0x2028,
                              'P': 0x2029 }
  static SIMPLE-ESCAPE-KEYS ::= keys-as-set_ SIMPLE-ESCAPES

  c-ns-esc-char -> int?:
    with-rollback:
      if match-char C-ESCAPE_:
        if rune := match-chars SIMPLE-ESCAPE-KEYS:
          return SIMPLE-ESCAPES[rune]
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

  // Lexigraphical-like productions
  start-of-line -> bool:
    return offset_ == 0 or bytes_[offset_ - 1] == B-LINE-FEED_ or bytes_[offset_ - 1] == B-CARRIAGE-RETURN_

  l-eof -> bool:
    return offset_ == bytes_.size or forbidden-detected != null and offset_ >= forbidden-detected

  b-break-helper -> bool:
    if match-buffer #[B-CARRIAGE_RETURN_, B-LINE-FEED_]: return true
    if match-char B-CARRIAGE_RETURN_: return true
    if match-char B-LINE-FEED_: return true
    return false

  b-break -> bool:
    if is-break := b-break-helper:
      detect-forbidden
      return true
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

  static ns-special-uri ::= {
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