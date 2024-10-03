// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
A YAML parser.

Follows the grammar of the YAML 1.2.2 draft: https://yaml.org/spec/1.2.2/
*/

B-LINE-FEED_        ::= '\n'
B-CARRIAGE-RETURN_  ::= '\r'
B-LINE-TERMINATORS_ ::= { B-LINE-FEED_, B-CARRIAGE-RETURN_ }

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
C-RESERVED-1_       ::= '@'
C-RESERVED-2_       ::= '`'
C-ESCAPE_           ::= '\\'

C-FLOW-INDICATOR_  ::= { C-COLLECT-ENTRY_, C-SEQUENCE-START_, C-SEQUENCE-END_, C-MAPPING-START_, C-MAPPING-END_ }
C-INDICATOR_       ::= { C-SEQUENCE-ENTRY_, C-MAPPING-KEY_, C-MAPPING-VALUE_, C-COLLECT-ENTRY_, C-SEQUENCE-START_,
                         C-SEQUENCE-END_, C-MAPPING-START_, C-MAPPING-END_, C-COMMENT_, C-ANCHOR_, C-ALIAS_,
                         C-TAG_, C-LITERAL_, C-FOLDED_, C-SINGLE-QUOTE_, C-DOUBLE-QUOTE_, C-DIRECTIVE_,
                         C-RESERVED-1_, C-RESERVED-2_}

S-SECONDARY-TAG-HANDLE_ ::= "!!"

BLOCK-IN_    ::= 0
BLOCK-OUT_   ::= 1
BLOCK-KEY_   ::= 2
FLOW-IN_     ::= 3
FLOW-OUT_    ::= 4
FLOW-KEY_    ::= 5

STRIP_ ::= 0
CLIP_  ::= 1
KEEP_  ::= 2

/** Flattens the given list recursively. */
flatten-list_ list/List -> List:
  result := List
  list.do:
    if it is List: result.add-all (flatten-list_ it)
    else: result.add it
  return result

EMPTY-NODE_ ::= ValueNode_ null

one-element-queue_ elm -> Deque:
  q := Deque
  q.add elm
  return q

keys-as-set_ map/Map -> Set:
   set := Set
   map.do --keys: set.add it
   return set

STANDARD-STR-TAG_   ::= "!!str"
STANDARD-FLOAT-TAG_ ::= "!!float"
STANDARD-MAP-TAG_   ::= "!!map"
STANDARD-SEQ-TAG_  ::= "!!seq"
STANDARD-INT-TAG_   ::= "!!int"
class ValueNode_:
  tag/string? := null
  value/any
  force-string/bool
  constructor .value --.force-string=false:

  constructor.map-from-collection list/List:
    // Assume list is alternating [key1, value1, key2, value2, ...]
    value = {:}
    assert: list.size % 2 == 0
    (list.size / 2).repeat:
      key_ := list[2 * it]
      value_ :=  list[2 * it + 1]
      value[key_] = value_
    force-string = false

  // Either use the supplied tag to construct a toit object representing the value or use
  // the core schema tag resolution
  resolve -> any:
    if tag and tag == STANDARD-STR-TAG_ and value is string: return value
    model-value := canonical-value
    if tag:
      if tag == STANDARD-FLOAT-TAG_ and model-value is int:
        return model-value.to-float
      // All other tags and conditions are intentionally ignored.
    return model-value

  static NULL     ::= { "null", "NULL", "Null", "~" }
  static TRUE     ::= { "true", "True", "TRUE" }
  static FALSE    ::= { "false", "False", "FALSE" }
  static INFINITY ::= { ".inf", ".Inf", ".INF"  }
  static NAN      ::= { ".nan", ".Nan", ".NAN" }

  canonical-value -> any:
    if this == EMPTY-NODE_: return null

    if value is string and not force-string:
      if NULL.contains value: return null
      if TRUE.contains value: return true
      if FALSE.contains value: return false

      if as-int := int.parse value --on-error=(: null): return as-int

      catch:
        // TODO(florian): Fix when float.parse takes an --on-error argument
        return float.parse value

      if INFINITY.contains value or
         value.size > 1 and value[0] == '+' and INFINITY.contains value[1..]:
        return float.INFINITY

      if value.size > 1 and value[0] == '-' and INFINITY.contains value[1..]:
        return -float.INFINITY

      if NAN.contains value: return float.NAN

      if value.starts-with "0x":
        if as-int := int.parse --radix=16 value[2..] --on-error=(: null):
          return as-int

      if value.starts-with "0o":
        if as-int := int.parse --radix=8 value[2..] --on-error=(: null):
          return as-int

    if value is List:
      return value.map: | node/ValueNode_ | node.resolve

    if value is Map:
      map := {:}
      value.do:| key/ValueNode_  value/ValueNode_| map[key.resolve] = value.resolve
      return map

    return value

  check-key -> string?:
    if value == null:
      return "NULL_KEYS_UNSUPPORTED"
    if value is List:
      return "LIST_KEYS_UNSUPPORTED"
    if value is Map:
      return "MAP_KEYS_UNSUPPORTED"
    return null

  // As a potential key is checked against 'is-valid-key' above this hash-code
  // should always succeed.
  hash-code:
    return value.hash-code


/** Holds infomration about the properties apply to a node. */
class NodeProperty_:
 tag/string?
 anchor/string?
 constructor .tag .anchor:

/** A base class for PEG parsers. */
abstract class PegParserBase_:
  bytes_/ByteArray
  offset_/int := 0

  constructor .bytes_:

  // As a peg grammar is top-down, the parser needs to be able to rollback
  mark -> any:
    return offset_

  rollback mark -> none:
    offset_ = mark

  at-mark mark -> bool:
    return offset_ == mark

  /**
  Runs the given $block and rolls back if the returned value is null.
  A non-local return is guaranteed to not rollback.
  If the block uses a non-local return, then this function does *not* roll back.
  Example usage:
    try-parse:
      if production-one-result := production-one:
        if production-two-result := production-two:
          return true
    If any of the two production returns false/null then a roll back is issued,
    otherwise no roll back is issued as we sucessfully parsed the two concatenated productions.

    Use this for concatenated productions separated by |.
  */
  try-parse [block] -> any:
    rollback-mark := mark
    result := block.call
    if not result: rollback rollback-mark
    return result

  /**
  Evaluates the $block and rolls back.
  The $block can return any value,
    and the method will return a boolified version of the return value.
    null and false are considered false values, everything else is true.
  */
  lookahead [block] -> bool:
    result := try-parse block
    return not (not result) // Boolify the result.

  /**
  Evaluates the given $block starting $rune-count amount of runes behind the current offset.
  */
  lookbehind rune-count [block] -> bool:
    old-offset := offset_
    try:
      rune-count.repeat:
        if offset_ == 0:
          return false
        offset_--
        // Skip to the first byte of Unicode surrogates.
        // Byte 2, 3, and 4 all start with bits 10.
        // Since the input is a valid string we do not need to check for offset_ > 0.
        //  An UTF-8 surrogate will have the two MSB bits set to 0b10 for all but the
        //  first byte, where it wil be 0b11.
        while (bytes_[offset_] & 0b1100_0000) == 0b1000_0000: offset_--
      behind-result := block.call
      return behind-result
    finally:
      offset_ = old-offset

  // Returns the current position in the input buffer
  current-position -> int: return offset_

  eof -> bool: return offset_ >= bytes_.size
  bof -> bool: return offset_ == 0

  consume-rune -> int?:
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

      if can-read bytes:
         // TODO(florian): Add a static function to ByteArray to return a rune at a given position.
        buf/ByteArray := peek-slice bytes
        if buf.is-valid-string-content:
          offset_ += bytes
          return buf.to-string[0]

    return null

  peek-slice n/int -> ByteArray:
    return bytes_[offset_..offset_ + n]

  string-since mark -> string:
    return bytes_[mark..offset_].to-string

  /**
  Returns the amount of bytes since the given $mark.
  Returns a negative value if the mark is in the 'future'.
  */
  bytes-since-mark mark -> int:
    return offset_ - mark

  /**
  Repeatedly calls the given $block as long as it returns a truthful value.
  Returns null if $at-least-one is true and no invocation of $block is truthful.
  Returns a list of the results of the (truthful) $block invocations, otherwise.

  Use this for *- and +-productions.
  */
  repeat --at-least-one/bool=false [block] -> List?:
    result := []
    while true:
      rollback-mark := mark
      element := block.call
      if not element:
        rollback rollback-mark
        break
      if at-mark rollback-mark:
        // No progress, so matched empty. This should terminate the loop.
        break
      result.add element
    return not at-least-one or not result.is-empty
        ? result
        : null

  /**
  Calls $block and returns its value if it is truthful, consuming the input.
  If $block returns null or false, rolls back and returns either null if $or-null or
    the $EMPTY-NODE_.

  Use this for ?-productions.
  */
  optional --or-null/bool=false [block] -> any:
    result := try-parse block
    return result or (or-null ? null : EMPTY-NODE_)

  can-read num/int -> bool:
    return offset_ + num <= bytes_.size

  match-one [block] -> int?:
    if can-read 1:
      if (block.call bytes_[offset_]):
        offset_++
        return bytes_[offset_ - 1]
    return null

  match-many n [block] -> bool:
    if can-read n:
      if block.call:
        offset_ += n
        return true
    return false

  match-any:
    offset_++

  match-char byte/int -> int?:
    return match-one: it == byte

  match-chars chars/Set -> int?:
    return match-one: chars.contains it

  match-range from/int to/int -> int?:
    return match-one: from <= it <= to

  match-buffer buf/ByteArray -> bool:
    return match-many buf.size: (peek-slice buf.size) == buf

  match-string str/string -> bool:
    return match-buffer str.to-byte-array


// Used to signal a successful parse. Useful when on-error return should return an alternative value.
class ParseResult_:
  documents/List
  constructor .documents:


/**
A YAML parser based on https://yaml.org/spec/1.2.2.
The grammar is almost a PEG grammar (except for one lookbehind).

Naming conventions:
- `e-`: A production matching no characters.
- `c-`: A production starting and ending with a special character.
- `b-`: A production matching a single line break.
- `nb-`: A production starting and ending with a non-break character.
- `s-`: A production starting and ending with a white-space character.
- `ns-`: A production starting and ending with a non-space character.
- `l-`: A production matching complete line(s).
- `X-Y-`: A production starting with an `X-~` character and ending with a `Y-` character, where `X-` and `Y-` are any of the above prefixes.
- `X-plus`, `X-Y-plus`: A production as above, with the additional property that the matched content indentation level is greater than the specified `n` parameter.
*/
class Parser_ extends PegParserBase_:
  named-nodes ::= {:}
  /**
  Mark (as in position) for the forbidden directive marks ('---' and '...').
  This mark is frequently in the "future".
  */
  forbidden-mark/int? := null
  error/string? := null

  constructor bytes/ByteArray:
    super bytes

  set-error error/string:
    if not this.error: this.error = error

  can-read num/int -> bool:
    super-result := super num
    if not super-result: return false
    if not forbidden-mark: return true
    // bytes-since-mark returns a negative value if the mark is in the future.
    forbidden-distance := -(bytes-since-mark forbidden-mark)
    return forbidden-distance >= num

  static as-bool val/any -> bool:
    return not (not val)

  try-parse --as-bool/True [block] -> any:
    // Error-aware try-parse to limit unnecessary work on parse errors and
    // supports boolean conversion.
    rollback-mark := mark
    result := block.call
    if not result:
      rollback rollback-mark
      return false
    return true

  check-valid-key key/ValueNode_? -> ValueNode_?:
    if not key: return null
    if error_ := key.check-key:
      set-error error_
      return null
    return key

  match-hex digits/int -> int?:
    try-parse:
      start := mark
      failed := false
      while digits-- > 0:
        if not ns-hex-digit:
          failed = true
          break
      if not failed: return int.parse --radix=16 (string-since start)
    return null

  apply-props props/NodeProperty_? value/ValueNode_ -> ValueNode_:
    if props:
      if props.anchor: named-nodes[props.anchor] = value
    value.tag = props and props.tag
    return value

  /**
  Finds the forbidden "---" and "..." that separate the documents from directives.
  Updates the $forbidden-mark mark if it finds one.
  */
  detect-forbidden:
    if forbidden-mark: return
    mark := mark
    if start-of-line and
       (c-directives-end or c-document-end) and
       (match-chars B-LINE-TERMINATORS_ or s-white or l-eof):
      forbidden-mark = mark
    rollback mark

  find-leading-spaces-on-first-non-empty-line -> int:
    start-mark := mark
    start-of-line := mark
    while true:
      if s-white: continue
      if b-break:
        start-of-line = mark
        continue
      break
    result := bytes-since-mark start-of-line
    rollback start-mark
    return result

  // Overall structure.
  l-yaml-stream [--on-error] -> any:
    repeat: l-document-prefix
    documents := []
    if document := l-any-document: documents.add document

    // Modifies the documents list with any additional documents.
    repeat: l-yaml-stream-helper documents

    if not l-eof:
      set-error "INVALID_YAML_DOCUMENT"

    parsed-value := documents.map: | node/ValueNode_ | node.resolve

    if error:
      return on-error.call error

    return ParseResult_ parsed-value

  /**
  Parses the remaining documents and comments from the stream.
  Modifies $documents.
  Note: This is mostly separated out from the l-yaml-stream to allow for returns.
  */
  l-yaml-stream-helper documents/List -> bool:
    named-nodes.clear
    try-parse:
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
    return l-directive-document or l-explicit-document or l-bare-document

  l-directive-document -> ValueNode_?:
    return try-parse: (repeat --at-least-one: l-directive) and l-explicit-document

  l-explicit-document -> ValueNode_?:
    try-parse:
      if c-directives-end:
        if res := l-bare-document: return res
        if e-node and s-l-comments: return EMPTY-NODE_
    return null

  l-bare-document -> ValueNode_?:
    return s-l-plus-block-node -1 BLOCK-IN_

  l-document-prefix -> bool:
    optional: c-byte-order-mark
    repeat: l-comment
    return true

  l-document-suffix -> bool:
    return c-document-end and s-l-comments

  allow-forbidden-read [block] -> bool:
    old-forbidden-detected := forbidden-mark
    forbidden-mark = null
    result := block.call
    if not result:
      forbidden-mark = old-forbidden-detected
    return result

  c-document-end -> bool:
    return allow-forbidden-read: match-string "..."

  c-directives-end -> bool:
    return allow-forbidden-read: match-string "---"

  // Directives.
  l-directive -> bool:
    return try-parse --as-bool:
      match-char C-DIRECTIVE_ and
          (ns-yaml-directive or ns-tag-directive or ns-reserved-directive) and
          s-l-comments

  ns-yaml-directive -> bool:
    return try-parse --as-bool: match-string "YAML" and s-separate-in-line and ns-yaml-version

  ns-yaml-version -> bool:
    mark := mark
    return try-parse --as-bool:
      if (repeat --at-least-one: ns-dec-digit) and
          match-char '.' and
         (repeat --at-least-one: ns-dec-digit):
        version := string-since mark
        parts := version.split "."
        major := int.parse parts[0]
        minor := int.parse parts[1]
        if major > 1 or minor > 2:
          set-error "UNSUPPORTED_YAML_VERSION"
          false
        else:
          true

  ns-tag-directive -> bool:
   return try-parse --as-bool:
     match-string "TAG" and
         s-separate-in-line and
         c-tag-handle and
         s-separate-in-line and
         ns-tag-prefix

  c-tag-handle -> bool:
    return c-named-tag-handle or match-string S-SECONDARY-TAG-HANDLE_ or (match-char C-TAG_) != null

  c-named-tag-handle -> bool:
    return try-parse --as-bool:
      match-char C-TAG_ and
          (repeat --at-least-one : ns-word-char) and
          match-char C-TAG_

  ns-tag-prefix -> bool:
    return c-ns-local-tag-prefix or ns-global-tag-prefix

  c-ns-local-tag-prefix -> bool:
    return try-parse --as-bool: match-char C-TAG_ and (repeat: ns-uri-char)

  ns-global-tag-prefix -> bool:
    return try-parse --as-bool: ns-tag-char and (repeat: ns-uri-char)

  ns-reserved-directive -> bool:
    return try-parse --as-bool: ns-directive-name and (repeat: s-separate-in-line and ns-directive-parameter)

  ns-directive-name -> List?:
    return repeat --at-least-one: ns-char

  ns-directive-parameter -> List?:
    return repeat --at-least-one: ns-char

  // Comments.
  l-comment -> bool:
    return try-parse --as-bool: s-separate-in-line and (optional: c-nb-comment-text) and b-comment

  s-l-comments -> bool:
    return try-parse --as-bool: (s-b-comment or start-of-line) and (repeat: l-comment)

  s-b-comment -> bool:
    return try-parse --as-bool: (optional: s-separate-in-line and (optional: c-nb-comment-text)) and b-comment

  s-separate-in-line -> bool:
    return try-parse --as-bool: (repeat --at-least-one: s-white) or start-of-line

  c-nb-comment-text -> bool:
    return as-bool (c-comment and (repeat: nb-char))

  b-comment -> bool:
    return b-non-content or l-eof

  b-non-content -> bool:
    return b-break

  l-trail-comments n/int -> bool:
    return try-parse --as-bool:
      s-indent-less-than n and
          c-nb-comment-text and
          b-comment and
          (repeat: l-comment)

  // Data part.
  s-l-plus-block-node n/int c/int -> ValueNode_?:
    return s-l-plus-block-in-block n c or s-l-plus-flow-in-block n

  s-l-plus-block-in-block n/int c/int -> ValueNode_?:
    return s-l-plus-block-scalar n c or s-l-plus-block-collection n c

  s-l-plus-flow-in-block n/int -> ValueNode_?:
    try-parse:
      node := s-separate n + 1 FLOW-OUT_ and ns-flow-node n + 1 FLOW-OUT_
      if node and s-l-comments: return node
    return null

  s-l-plus-block-collection n/int c/int -> ValueNode_?:
    try-parse:
      props := optional --or-null: s-separate n + 1 c ? c-ns-properties n + 1 c : null
      if s-l-comments:
        if node := (seq-space n c or l-plus-block-mapping n):
          return apply-props props node
    return null

  s-l-plus-block-scalar n/int c/int -> ValueNode_?:
    try-parse:
      if s-separate n + 1 c:
        props := optional --or-null:
          p := c-ns-properties n + 1 c
          s-separate n + 1 c ? p : null
        if node := (c-l-plus-literal n or c-l-plus-folded n):
          return apply-props props (ValueNode_ node)
    return null

  seq-space n c/int -> ValueNode_?:
    if c == BLOCK-OUT_: return l-plus-block-sequence n - 1
    if c == BLOCK-IN_: return l-plus-block-sequence n
    return null

  l-plus-block-sequence n/int -> ValueNode_?:
    try-parse:
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

  l-plus-block-mapping n/int -> ValueNode_?:
    try-parse:
      if m := s-indent n + 1 --auto-detect-m:
        if first := ns-l-block-map-entry n + 1 + m:
          rest := repeat:
            if s-indent n + 1 + m:
              if entry := ns-l-block-map-entry n + 1 + m:
                continue.repeat entry
            false
          return ValueNode_.map-from-collection (flatten-list_ [[first], rest])
    return null

  c-l-block-seq-entry n/int -> ValueNode_?:
    try-parse:
      if match-char C-SEQUENCE-ENTRY_ and
          (lookahead: not ns-char):
        return s-l-plus-block-indented n BLOCK-IN_
    return null

  s-l-plus-block-indented n/int c/int -> ValueNode_?:
    try-parse:
      if m := s-indent 0 --auto-detect-m:
        if node := (ns-l-compact-sequence n + 1 + m or ns-l-compact-mapping n + 1 + m):
          return node

    return s-l-plus-block-node n c or (e-node and s-l-comments ? EMPTY-NODE_ : null)

  ns-l-compact-sequence n/int -> ValueNode_?:
    try-parse:
      if first := c-l-block-seq-entry n:
        rest := repeat:
          if s-indent n:
            if entry := c-l-block-seq-entry n:
              continue.repeat entry
        return ValueNode_ (flatten-list_ [first, rest])
    return null

  ns-l-compact-mapping n/int -> ValueNode_?:
    try-parse:
      if first := ns-l-block-map-entry n:
        rest := repeat:
          if s-indent n:
            if entry := ns-l-block-map-entry n:
              continue.repeat entry
        return ValueNode_.map-from-collection (flatten-list_ [first, rest])
    return null

  ns-l-block-map-entry n/int -> List?:
    return c-l-block-map-explicit-entry n or ns-l-block-map-implicit-entry n

  c-l-block-map-explicit-entry n/int -> List?:
    try-parse:
      if key := check-valid-key (c-l-block-map-explicit-key n):
        if val := l-block-map-explicit-value n:
          return [key, val]
        else:
          return [key, EMPTY-NODE_]
    return null

  c-l-block-map-explicit-key n/int -> ValueNode_?:
    return try-parse: match-char C-MAPPING-KEY_ and s-l-plus-block-indented n BLOCK-OUT_

  l-block-map-explicit-value n/int -> ValueNode_?:
    return try-parse: s-indent n and match-char C-MAPPING-VALUE_ and s-l-plus-block-indented n BLOCK-OUT_

  ns-l-block-map-implicit-entry n/int -> List?:
    try-parse:
      key := ns-s-block-map-implicit-key or e-node and EMPTY-NODE_
      if val := c-l-block-map-implicit-value n:
        if error_ := key.check-key:
          set-error error_
          return null
        return [key, val]
    return null

  ns-s-block-map-implicit-key -> ValueNode_?:
    return  c-s-implicit-json-key BLOCK-KEY_ or ns-s-implicit-yaml-key BLOCK-KEY_

  c-l-block-map-implicit-value n/int -> ValueNode_?:
    return try-parse:
      match-char C-MAPPING-VALUE_ and
          (s-l-plus-block-node n BLOCK-OUT_ or
              (e-node and s-l-comments ? EMPTY-NODE_ : null))

  c-s-implicit-json-key c/int -> ValueNode_?:
    try-parse:
      if node := c-flow-json-node 0 c:
        s-separate-in-line
        return node
    return null

  ns-flow-yaml-node n/int c/int -> ValueNode_?:
    if node := (c-ns-alias-node or ns-flow-yaml-content n c): return node
    try-parse:
      if props := c-ns-properties n c:
        try-parse:
          if s-separate n c:
            if node := ns-flow-yaml-content n c:
              return apply-props props node
        if e-node: return EMPTY-NODE_
    return null

  c-flow-json-node n/int c/int -> ValueNode_?:
    try-parse:
      props := optional --or-null:
        p := c-ns-properties n c
        s-separate n c ? p : null
      if node := c-flow-json-content n c:
        return apply-props props node
    return null

  ns-flow-node n/int c/int -> ValueNode_?:
    if node := (c-ns-alias-node or ns-flow-content n c): return node
    try-parse:
      if props := c-ns-properties n c:
        try-parse:
          if s-separate n c:
            if node := ns-flow-content n c: return apply-props props node
        if e-node: return EMPTY-NODE_
    return null

  c-ns-alias-node -> ValueNode_?:
    if anchor := (try-parse: match-char C-ALIAS_ and ns-anchor-name):
      if not named-nodes.contains anchor:
        set-error "UNRESOLVED_ALIAS"
        return null
      return named-nodes[anchor]
    return null

  ns-flow-content n/int c/int -> ValueNode_?:
    return ns-flow-yaml-content n c or c-flow-json-content n c

  c-flow-json-content n/int c/int -> ValueNode_?:
    return c-flow-sequence n c or c-flow-mapping n c or c-single-quoted n c or c-double-quoted n c

  ns-flow-yaml-content n/int c/int -> ValueNode_?:
    if content := ns-plain n c: return ValueNode_ content
    return null

  c-flow-sequence n/int c/int -> ValueNode_?:
    try-parse:
      if match-char C-SEQUENCE-START_:
        optional: s-separate n c
        res := in-flow n c
        if match-char C-SEQUENCE-END_:
          return ValueNode_ ( res ? List.from res : [] )
    return null

  c-flow-mapping n/int c/int -> ValueNode_?:
    try-parse:
      if match-char C-MAPPING-START_:
        optional: s-separate n c
        map-entries := in-flow-map n c // See https://github.com/yaml/yaml-spec/issues/299.
        if match-char C-MAPPING-END_:
          return ValueNode_.map-from-collection (flatten-list_ (List.from (map-entries or [])))
    return null

  in-flow n/int c/int -> Deque?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return ns-s-flow-seq-entries n FLOW-IN_
    return ns-s-flow-seq-entries n FLOW-KEY_

  in-flow-map n/int c/int -> Deque?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return ns-s-flow-map-entries n FLOW-IN_
    return ns-s-flow-map-entries n FLOW-KEY_

  flow-entries n/int c/int [--head] [--tail] -> Deque?:
    try-parse:
      if head-entry := head.call:
        s-separate n c
        try-parse:
          if match-char C-COLLECT-ENTRY_:
            s-separate n c
            if tail-entries := tail.call:
              tail-entries.add-first head-entry
              return tail-entries
            return one-element-queue_ head-entry
        return one-element-queue_ head-entry
    return null


  ns-s-flow-seq-entries n/int c/int -> Deque?:
    return flow-entries n c
      --head=: ns-flow-seq-entry n c
      --tail=: ns-s-flow-seq-entries n c

  ns-s-flow-map-entries n/int c/int -> Deque?:
    return flow-entries n c
      --head=: ns-flow-map-entry n c
      --tail=: ns-s-flow-map-entries n c

  ns-flow-seq-entry n/int c/int -> ValueNode_?:
    return ns-flow-pair n c or ns-flow-node n c

  ns-flow-map-entry n/int c/int -> List?:
    return try-parse:
      match-char C-MAPPING-KEY_  and s-separate n c and ns-flow-map-explicit-entry n c or
          ns-flow-map-implicit-entry n c

  ns-flow-pair n/int c/int -> ValueNode_?:
    entry := try-parse:
      match-char C-MAPPING-KEY_ and s-separate n c and  ns-flow-map-explicit-entry n c or
          ns-flow-pair-entry n c
    return entry and ValueNode_.map-from-collection entry

  ns-flow-map-explicit-entry n/int c/int -> List?:
    return ns-flow-map-implicit-entry n c or [EMPTY-NODE_, EMPTY-NODE_]

  ns-flow-map-implicit-entry n/int c/int -> List?:
    return ns-flow-map-yaml-key-entry n c or c-ns-flow-map-empty-key-entry n c or c-ns-flow-map-json-key-entry n c

  ns-flow-pair-entry n/int c/int -> List?:
    return ns-flow-pair-yaml-key-entry n c or c-ns-flow-map-empty-key-entry n c or c-ns-flow-pair-json-key-entry n c

  ns-flow-pair-yaml-key-entry n/int c/int -> List?:
    try-parse:
      if key := ns-s-implicit-yaml-key FLOW-KEY_:
        if value := c-ns-flow-map-separate-value n c:
          if check-valid-key key:
            return [key, value]
    return null

  c-ns-flow-pair-json-key-entry n/int c/int -> List?:
    try-parse:
      if key := c-s-implicit-json-key FLOW-KEY_:
        if value := c-ns-flow-map-adjacent-value n c:
          if check-valid-key key:
            return [key, value]
    return null

  c-ns-flow-map-json-key-entry n/int c/int -> List?:
    try-parse:
      if key := check-valid-key (c-flow-json-node n c):
        value := optional: (optional: s-separate n c) and c-ns-flow-map-adjacent-value n c
        return [key, value]
    return null

  c-ns-flow-map-adjacent-value n/int c/int -> ValueNode_?:
    return try-parse:
      match-char C-MAPPING-VALUE_ and (optional: (optional:  s-separate n c) and ns-flow-node n c)

  ns-s-implicit-yaml-key c/int -> ValueNode_?:
    if node := ns-flow-yaml-node 0 c:
      s-separate-in-line
      return node
    return null

  ns-flow-map-yaml-key-entry n/int c/int -> List?:
    try-parse:
      if key := check-valid-key (ns-flow-yaml-node n c):
        value := optional: (optional: s-separate n c) and c-ns-flow-map-separate-value n c
        return [key, value]
    return null

  c-ns-flow-map-empty-key-entry n/int c/int -> List?:
    if value := c-ns-flow-map-separate-value n c: return [EMPTY-NODE_, value]
    return null

  c-ns-flow-map-separate-value n/int c/int -> ValueNode_?:
    return try-parse:
      match-char C-MAPPING-VALUE_ and (lookahead: not ns-plain-safe c) and
          ((try-parse: s-separate n c and ns-flow-node n c) or e-node and EMPTY-NODE_)

  ns-plain n/int c/int -> string?:
    if c == FLOW-OUT_:  return ns-plain-multi-line n c
    if c == FLOW-IN_:   return ns-plain-multi-line n c
    if c == BLOCK-KEY_: return ns-plain-one-line c
    if c == FLOW-KEY_:  return ns-plain-one-line c
    return null

  ns-plain-one-line c/int -> string?:
    try-parse:
      mark := mark
      if ns-plain-first c and nb-ns-plain-in-line c:
        return string-since mark
    return null

  ns-plain-multi-line n/int c/int -> string?:
    try-parse:
      if first := ns-plain-one-line c:
        rest := repeat: s-ns-plain-next-line n c
        return (flatten-list_ [first, rest]).join ""
    return null

  s-ns-plain-next-line n/int c/int -> string?:
    try-parse:
      if folded := s-flow-folded n:
        if first := ns-plain-char c:
          rest := nb-ns-plain-in-line c
          return "$folded$(string.from-rune first)$rest"
    return null

  s-flow-folded n/int -> string?:
    try-parse:
      s-separate-in-line
      if folded := b-l-folded n FLOW-IN_:
        if s-flow-line-prefix n:
          return folded
    return null

  nb-ns-plain-in-line c/int -> string:
    mark := mark
    repeat: (repeat: match-chars S-WHITESPACE_) and ns-plain-char c
    return string-since mark

  static NS-PLAIN-SEMI-SAFE_ ::= { C-MAPPING-KEY_, C-MAPPING-VALUE_, C-SEQUENCE-ENTRY_ }
  ns-plain-first c:
    try-parse:
      if rune := ns-char:
        if not C-INDICATOR_.contains rune: return true
    try-parse:
      if (match-chars NS-PLAIN-SEMI-SAFE_ and
          lookahead: ns-plain-safe c): return true
    return false

  ns-plain-char c/int -> int?:
    try-parse:
      if rune := ns-plain-safe c:
        if rune != C-MAPPING-VALUE_ and rune != C-COMMENT_: return rune

    try-parse:
      if match-char C-COMMENT_:
        //  [ lookbehind = ns-char ].
        is-ns-char := lookbehind 2: ns-char != null
        if is-ns-char: return C-COMMENT_

    try-parse:
      if match-char C-MAPPING-VALUE_ and
         (lookahead: ns-plain-safe c):
        return C-MAPPING-VALUE_

    return null

  ns-plain-safe c/int -> int?:
    if c == FLOW-OUT_ or c == BLOCK-KEY_: return ns-plain-safe-out
    return ns-plain-safe-in

  ns-plain-safe-out: return ns-char

  ns-plain-safe-in -> int?:
    try-parse:
      if rune := ns-char:
        if not C-FLOW-INDICATOR_.contains rune: return rune
    return null


  c-ns-properties n/int c/int -> NodeProperty_?:
    try-parse:
      if tag := c-ns-tag-property:
        anchor := optional --or-null: s-separate n c ? c-ns-anchor-property : null
        return NodeProperty_ tag anchor
    try-parse:
      if anchor := c-ns-anchor-property:
        tag := optional --or-null: s-separate n c ? c-ns-tag-property : null
        return NodeProperty_ tag anchor
    return null

  c-ns-tag-property -> string?:
    if res := c-verbatim-tag: return res
    if res := c-ns-shorthand-tag: return res
    if res := c-non-specific-tag: return res
    return null

  c-verbatim-tag -> string?:
    mark := mark
    try-parse:
      if match-string "!<" and (repeat --at-least-one: ns-uri-char) and match-char '>':
        return string-since mark
    return null

  c-ns-shorthand-tag -> string?:
    mark := mark
    try-parse:
      if c-tag-handle and (repeat --at-least-one: ns-tag-char):
        return string-since mark
    return null

  c-non-specific-tag -> string?:
    if match-char C-TAG_: return "!"
    return null

  c-ns-anchor-property -> string?:
    try-parse:
      if match-char C-ANCHOR_:
        if res := ns-anchor-name:
          return res
    return null

  ns-anchor-name -> string?:
    mark := mark
    try-parse:
      if (repeat --at-least-one: ns-anchor-char):
        return string-since mark
    return null

  c-l-plus-literal n/int -> string?:
    try-parse:
      if match-char C-LITERAL_:
        if t := c-b-block-header n:
          chomp := t[0]
          indent := t[1]
          if res := l-literal-content indent chomp:
            return res.join ""
    return null

  c-l-plus-folded n/int -> string?:
    try-parse:
      if match-char C-FOLDED_:
        t := c-b-block-header n
        chomp := t[0]
        indent := t[1]
        if res := l-folded-content indent chomp:
          return res.join ""
    return null

  c-b-block-header n/int -> List?:
    try-parse:
      indent-char := match-range '1' '9'
      chomp-char := match-chars { '-', '+' }
      if not indent-char: indent-char = match-range '1' '9'
      // It might seem from the spec that indent is not optional. This is an error, see
      // https://github.com/yaml/yaml-spec/issues/230.
      // c-chomping-indicator(CLIP)  ::= "" allows for an empty chomping indicator.
      if s-b-comment:
        chomp := CLIP_
        if chomp-char == '-': chomp = STRIP_
        else if chomp-char == '+': chomp = KEEP_

        indent := 0
        if indent-char:
          indent = n + indent-char - '0'
        else:
          indent = find-leading-spaces-on-first-non-empty-line
        return [ chomp, indent ]
    return null

  l-literal-content n/int t/int -> List?:
    try-parse:
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

  l-folded-content n/int t/int -> List?:
    try-parse:
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

  b-chomped-last t/int -> string?:
    if t == STRIP_: if b-non-content or eof: return ""
    if b-as-line-feed or eof: return "\n"
    return null

  l-chomped-empty n/int t/int -> List?:
    if t == KEEP_: return l-keep-empty n
    return l-strip-empty n

  l-keep-empty n/int -> List:
    empty-lines := repeat: l-empty n BLOCK-IN_
    optional: l-trail-comments n
    return List empty-lines.size --initial="\n"

  l-strip-empty n/int -> List:
    repeat: s-indent-less-or-equals n and (b-non-content or l-eof)
    optional: l-trail-comments n
    return []

  l-nb-literal-text n/int -> string?:
    try-parse:
      empty-lines := repeat: l-empty n BLOCK-IN_
      if s-indent n:
        mark := mark
        if (repeat --at-least-one: nb-char):
          prefix := string.from-runes (List empty-lines.size --initial='\n')
          return "$prefix$(string-since mark)"
    return null

  b-nb-literal-next n/int -> string?:
    try-parse:
      if b-as-line-feed:
        if text := l-nb-literal-text n: return "\n$text"
    return null

  l-nb-diff-lines n/int -> List?:
    try-parse:
      if first := l-nb-same-lines n:
        rest := repeat:
          content/string? := null
          if b-as-line-feed:
            if lines := l-nb-same-lines n:
              content = (flatten-list_ ["\n", lines]).join ""
          content
        return flatten-list_ [first, rest]
    return null

  l-nb-same-lines n/int -> List?:
    try-parse:
      empty-lines := repeat: l-empty n BLOCK-IN_
      if lines := l-nb-folded-lines n or l-nb-spaced-lines n:
        return flatten-list_ [List empty-lines.size --initial="\n", lines]
    return null

  l-nb-folded-lines n/int -> List?:
    try-parse:
      if first := s-nb-folded-text n:
        rest := repeat:
          content/string? := null
          if folded := b-l-folded n BLOCK-IN_:
            if tmp := s-nb-folded-text n:
              content = "$folded$tmp"
          content
        return flatten-list_ [first, rest]
    return null

  s-nb-folded-text n/int -> string?:
    try-parse:
      if s-indent n:
        mark := mark
        if ns-char and (repeat: nb-char):
          return string-since mark
    return null

  b-l-folded n/int c/int -> string?:
    if breaks := b-l-trimmed n c: return string.from-runes (List breaks --initial='\n')
    if b-as-space: return " "
    return null

  l-nb-spaced-lines n/int -> List?:
    try-parse:
      if first := s-nb-spaced-text n:
        rest := repeat:
          content/string? := null
          if space := b-l-spaced n:
            if text := s-nb-spaced-text n:
              content = "$space$text"
          content
        return flatten-list_ [first, rest]
    return null

  s-nb-spaced-text n/int -> string?:
    try-parse:
      if s-indent n:
        mark := mark
        if match-chars S-WHITESPACE_  and (repeat: nb-char):
          return string-since mark
    return null

  b-l-spaced n/int -> string?:
    try-parse:
      if b-as-line-feed:
        empty-lines := (repeat: l-empty n BLOCK-IN_)
        return string.from-runes (List (empty-lines.size + 1) --initial='\n')
    return null

  b-l-trimmed n/int c/int -> int?:
    try-parse:
      if b-non-content:
        if empty-lines := (repeat --at-least-one: l-empty n c):
          return empty-lines.size
    return null

  // Escaped strings.
  c-single-quoted n/int c/int -> ValueNode_?:
    try-parse:
      if match-char C-SINGLE-QUOTE_:
        if res := nb-single-text n c:
          if match-char C-SINGLE-QUOTE_:
            return ValueNode_ (res.replace --all "''" "'") --force-string
    return null

  c-double-quoted n/int c/int -> ValueNode_?:
    try-parse:
      if match-char C-DOUBLE-QUOTE_:
        if res := nb-double-text n c:
          if match-char C-DOUBLE-QUOTE_:
            return ValueNode_ (res.join "") --force-string
    return null

  nb-single-text n/int c/int -> string?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return nb-single-multi-line n c
    return nb-single-one-line n c

  nb-double-text n/int c/int -> List?:
    if c == FLOW-OUT_ or c == FLOW-IN_: return nb-double-multi-line n c
    return nb-double-one-line n c

  nb-single-multi-line n/int c/int -> string?:
    try-parse:
      first := nb-ns-single-in-line
      if rest := s-single-next-line n:
        return "$first$(rest.join "")"
      else:
        mark := mark
        repeat: match-chars S-WHITESPACE_
        return "$first$(string-since mark)"
    return null

  nb-single-one-line n/int c/int -> string:
    mark := mark
    repeat: nb-single-char
    return string-since mark

  nb-double-multi-line n/int c/int -> List?:
    try-parse:
      first := nb-ns-double-in-line
      if rest := s-double-next-line n:
        return flatten-list_ [first,  rest]
      else:
        mark := mark
        repeat: s-white
        return [first, string-since mark]
    return null

  nb-double-one-line n/int c/int -> List:
    runes := repeat: nb-double-char
    return [ string.from-runes runes ]

  nb-ns-single-in-line -> string:
    mark := mark
    repeat: (repeat: s-white) and ns-single-char
    return string-since mark


  s-single-next-line n/int -> List?:
    try-parse:
      if folded := s-flow-folded n:
        try-parse:
          start-mark := mark
          if first := ns-single-char:
            line := nb-ns-single-in-line
            rest/any := s-single-next-line n
            if not rest:
              start-mark = mark
              repeat: s-white
              rest = string-since start-mark
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

  s-double-next-line n/int -> List?:
    try-parse:
      if breaks := s-double-break n:
        try-parse:
          if first-rune := ns-double-char:
            line := nb-ns-double-in-line
            first := "$(string.from-runes (flatten-list_ [breaks, first-rune]))$line"
            rest/any := s-double-next-line n
            if not rest:
              mark := mark
              repeat: s-white
              rest = string-since mark
            return flatten-list_ [ first, rest ]
        return [string.from-runes breaks]
    return null

  s-double-break n/int -> List?:
    if rune := s-double-escaped n: return rune
    if folded := s-flow-folded n:
      runes := []
      folded.do --runes: runes.add it
      return runes
    return null

  s-double-escaped n/int -> List?:
    try-parse:
      white-spaces := repeat: s-white
      if match-char C-ESCAPE_ and
         b-non-content and
         (repeat: l-empty n FLOW-IN_) and
         s-flow-line-prefix n:
        return white-spaces
    return null

  ns-single-char -> int?:
    return try-parse: (not s-white or null) and nb-single-char

  nb-single-char -> int?:
    try-parse:
      if rune := c-quoted-quote: return '\''
      if rune := nb-json:
        if rune != C-SINGLE-QUOTE_: return rune
    return null

  ns-double-char -> int?:
    return try-parse: (not s-white or null) and nb-double-char

  nb-double-char -> int?:
    if rune := c-ns-esc-char: return rune
    try-parse:
      if rune := nb-json:
        if rune != C-ESCAPE_ and rune != C-DOUBLE-QUOTE_: return rune
    return null

  static SIMPLE-ESCAPES ::= { '0': 0, 'a': '\a', 'b': '\b', 't': '\t', '\t': '\t', 'n': '\n',
                              'v': '\v', 'f': '\f', 'r': '\r', 'e': 0x18, ' ': ' ', '"': '"',
                              '/': '/', '\\': '\\', 'N': 0x85, '_': 0x0a, 'L': 0x2028,
                              'P': 0x2029 }
  static SIMPLE-ESCAPE-KEYS ::= keys-as-set_ SIMPLE-ESCAPES

  c-ns-esc-char -> int?:
    try-parse:
      if match-char C-ESCAPE_:
        if rune := match-chars SIMPLE-ESCAPE-KEYS:
          return SIMPLE-ESCAPES[rune]
        if match-char 'x': if res := match-hex 2: return res
        if match-char 'u':
          if res := match-hex 4:
            if 0xd800 <= res <= 0xdbff:
              // The spec does not mention anything about surrogates, but we assume that since YAML is an
              // extension of JSON that 16-bit surrogates shoud be supported.
              if part-2 := c-ns-esc-char:
                 if not 0xdc00 <= part-2 <= 0xdfff:
                   set-error "INVALID_SURROGATE_PAIR"
                   return null
                 return 0x10000 + ((res & 0x3ff) << 10) | (part-2 & 0x3ff)
            else:
              return res
        if match-char 'U': if res := match-hex 8: return res
    return null

  // Space.
  b-as-space -> bool: return b-break

  b-as-line-feed -> bool: return b-break

  l-empty n c -> bool:
    try-parse:
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
    try-parse:
      if s-l-comments and s-flow-line-prefix n: return true
    return s-separate-in-line

  s-flow-line-prefix n -> int?:
    if indent := s-indent n:
      optional: s-separate-in-line
      return indent
    return null

  s-block-line-prefix n -> int?:
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
    while n-- > 0 and match-char S-SPACE_: /* Do nothing. */
    return true

  s-indent-less-than n:
    return s-indent-less-or-equals (n - 1)

  // Lexicographical-like productions.
  e-node -> bool:
    // We can always match the empty-node.
    // Completely empty nodes are only valid when following some explicit indication for their existence.
    return true

  start-of-line -> bool:
    return bof or
           lookbehind 1: (match-chars B-LINE-TERMINATORS_) != null

  l-eof -> bool:
    return eof or forbidden-mark != null and (bytes-since-mark forbidden-mark) >= 0

  b-break-helper -> bool:
    return as-bool (match-buffer #[B-CARRIAGE-RETURN_, B-LINE-FEED_] or
                    match-char B-CARRIAGE-RETURN_ or
                    match-char B-LINE-FEED_)

  b-break -> bool:
    if is-break := b-break-helper:
      detect-forbidden
      return true
    return false

  c-byte-order-mark -> bool:
    if can-read 2:
      if match-buffer #[0xFE, 0xFF] or
          match-buffer #[0xFF, 0xFE] or
          match-char 0:
        set-error "UNSUPPORTED_BYTE_ORDER"
        return false
      try-parse:
        match-any
        if match-char 0:
          set-error "UNSUPPORTED_BYTE_ORDER"
          return false
    // Toit only supports UTF-8.
    if can-read 3 and match-buffer #[0xEF, 0xBB, 0xBF]:
      return true
    return false

  s-white -> int?:
    if res := match-chars S-WHITESPACE_: return res
    return null

  c-comment -> int?:
    return match-char C-COMMENT_

  c-quoted-quote -> bool:
    return match-string "''"

  nb-char -> int?:
    try-parse:
      if rune := c-printable:
        if not is-break rune and not rune == C-BYTE-ORDER-MARK_:
          return rune
    return null

  nb-json -> int?:
    try-parse:
      rune := consume-rune
      if rune and (rune == 0x09 or 0x20 <= rune and rune <= 0x10FFFF):
        return rune
    return null

  ns-dec-digit -> int?:
    return match-one: '0' <= it <= '9'

  ns-hex-digit -> bool:
    if ns-dec-digit: return true
    return (match-range 'A' 'F' or match-range 'a' 'f') != null

  ns-ascii-letter -> int?:
    return match-range 'A' 'Z' or match-range 'a' 'z'

  ns-word-char -> int?:
    if char := ns-dec-digit: return char
    if char := ns-ascii-letter: return char
    return match-one: it == '-'

  ns-tag-char -> bool:
    try-parse:
      if char := ns-uri-char:
        if char != C-TAG_ and not C-FLOW-INDICATOR_.contains char:
          return true
    return false

  static ns-special-uri ::= {
      '#', ';', '/', '?', ':', '@', '&', '=', '+',
      '$', ',', '-', '.', '!', '~', '*', '\'', '(', ')',
      '[', ']'
  }

  ns-uri-char -> int?:
    try-parse:
      if (match-char '%' and
          ns-hex-digit and
          ns-hex-digit): return '%'
    if char := ns-word-char: return char
    if char := match-chars ns-special-uri: return char
    return null

  ns-anchor-char -> bool:
    try-parse:
      if rune := ns-char:
        if not C-FLOW-INDICATOR_.contains rune: return true
    return false

  ns-char -> int?:
    try-parse:
      if rune := nb-char:
        if not S-WHITESPACE_.contains rune: return rune
    return null

  is-break rune -> bool:
    return rune == B-LINE-FEED_ or rune == B-CARRIAGE-RETURN_

  c-special-printable ::= { S-TAB_, B-CARRIAGE-RETURN_, B-LINE-FEED_, 0x85}
  c-printable -> int?:
    try-parse:
      if rune := consume-rune:
        if 0x20 <= rune <= 0x7E: return rune
        if c-special-printable.contains rune: return rune
        if 0xA0 <= rune <= 0xD7FF: return rune
        if 0xE000 <= rune <= 0xFFFD: return rune
        if 0x010000 <= rune <= 0x10FFFF: return rune
    return null

