// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
A reader for the subset of TOML that verified/TRUSTED.toml and the crates'
  Cargo.toml files use.

Supported: comments, `[table]` and `[[array.of.tables]]` headers with dotted
  names, bare, quoted and dotted keys, basic strings (with the escapes \b \t
  \n \f \r \" \\ \uXXXX \UXXXXXXXX), literal strings, decimal integers
  (with an optional sign and underscores), booleans, arrays (over several
  lines, with comments and a trailing comma) and inline tables.

Anything else (multi-line strings, floats, dates, other integer bases) is
  rejected with a $TomlError, so that a file the reader does not understand
  never yields a partial result.
*/

class TomlError:
  message/string
  constructor .message:
  stringify -> string: return message

/**
Parses $text and returns its top-level table as a $Map (insertion ordered).
Throws a $TomlError on syntax the reader does not support or on a
  redefined key.
*/
parse-toml text/string -> Map:
  return (TomlParser_ text).parse

class TomlParser_:
  text_/string
  pos_ := 0
  line_ := 1
  root_ := {:}
  // Tables defined by a header or a dotted key, to reject duplicates.
  defined_ := []

  constructor .text_:

  error message/string:
    throw (TomlError "line $line_: $message")

  peek -> int?:
    return pos_ < text_.size ? (text_.at --raw pos_) : null

  peek-at offset/int -> int?:
    p := pos_ + offset
    return p < text_.size ? (text_.at --raw p) : null

  advance -> int:
    c := text_.at --raw pos_
    pos_++
    if c == '\n': line_++
    return c

  skip-spaces -> none:
    while true:
      c := peek
      if c != ' ' and c != '\t': return
      pos_++

  skip-comment -> none:
    if peek == '#':
      while peek != null and peek != '\n': pos_++

  // Skips the rest of a line: spaces, an optional comment, and the newline.
  end-of-line -> none:
    skip-spaces
    skip-comment
    if peek == '\r' and (peek-at 1) == '\n': pos_++
    if peek == null: return
    if peek != '\n': error "expected the end of the line"
    advance

  // Skips whitespace, newlines and comments (inside arrays).
  skip-blank -> none:
    while true:
      c := peek
      if c == ' ' or c == '\t' or c == '\r' or c == '\n':
        advance
      else if c == '#':
        skip-comment
      else:
        return

  parse -> Map:
    current := root_
    while pos_ < text_.size:
      skip-spaces
      c := peek
      if c == null: break
      if c == '\n' or c == '\r' or c == '#':
        end-of-line
        continue
      if c == '[':
        current = parse-header
        end-of-line
        continue
      parse-key-value current
      end-of-line
    return root_

  parse-header -> Map:
    advance  // '['.
    is-array := false
    if peek == '[':
      advance
      is-array = true
    skip-spaces
    keys := parse-key
    skip-spaces
    if peek != ']': error "expected ']'"
    advance
    if is-array:
      if peek != ']': error "expected ']]'"
      advance
    table := root_
    for i := 0; i < keys.size - 1; i++:
      table = descend table keys[i]
    last := keys.last
    if is-array:
      list := table.get last
      if list == null:
        list = []
        table[last] = list
      else if list is not List:
        error "key '$last' is not an array of tables"
      entry := {:}
      list.add entry
      return entry
    existing := table.get last
    if existing != null:
      if existing is not Map or (defined_.any: identical it existing):
        error "table '$(keys.join ".")' defined twice"
      defined_.add existing
      return existing
    entry := {:}
    table[last] = entry
    defined_.add entry
    return entry

  // The table under $key in $table (the last table of an array of tables),
  //   created if missing.
  descend table/Map key/string -> Map:
    value := table.get key
    if value == null:
      value = {:}
      table[key] = value
      return value
    if value is List and not value.is-empty and value.last is Map: return value.last
    if value is not Map: error "key '$key' is not a table"
    return value

  parse-key -> List:
    keys := []
    while true:
      skip-spaces
      keys.add parse-simple-key
      skip-spaces
      if peek != '.': return keys
      advance

  parse-simple-key -> string:
    c := peek
    if c == '"': return parse-basic-string
    if c == '\'': return parse-literal-string
    start := pos_
    while true:
      c = peek
      if c == null: break
      if not ('a' <= c <= 'z' or 'A' <= c <= 'Z' or '0' <= c <= '9' or c == '_' or c == '-'): break
      pos_++
    if start == pos_: error "expected a key"
    return text_[start..pos_]

  parse-key-value table/Map -> none:
    keys := parse-key
    skip-spaces
    if peek != '=': error "expected '='"
    advance
    skip-spaces
    value := parse-value
    for i := 0; i < keys.size - 1; i++:
      table = descend table keys[i]
    if table.contains keys.last: error "key '$(keys.join ".")' defined twice"
    table[keys.last] = value

  parse-value -> any:
    c := peek
    if c == null: error "expected a value"
    if c == '"':
      if (peek-at 1) == '"' and (peek-at 2) == '"': error "multi-line strings are not supported"
      return parse-basic-string
    if c == '\'':
      if (peek-at 1) == '\'' and (peek-at 2) == '\'': error "multi-line strings are not supported"
      return parse-literal-string
    if c == '[': return parse-array
    if c == '{': return parse-inline-table
    if text_[pos_..].starts-with "true" and not is-bare-char (peek-at 4):
      pos_ += 4
      return true
    if text_[pos_..].starts-with "false" and not is-bare-char (peek-at 5):
      pos_ += 5
      return false
    return parse-integer

  is-bare-char c/int? -> bool:
    if c == null: return false
    return 'a' <= c <= 'z' or 'A' <= c <= 'Z' or '0' <= c <= '9' or c == '_' or c == '-'

  parse-integer -> int:
    start := pos_
    if peek == '+' or peek == '-': pos_++
    digits-start := pos_
    while true:
      c := peek
      if c == null or not ('0' <= c <= '9' or c == '_'): break
      pos_++
    token := text_[digits-start..pos_]
    c := peek
    if token.is-empty or token.starts-with "_" or token.ends-with "_" or token.contains "__"
        or (token.size > 1 and token.starts-with "0")
        or (c != null and c != ' ' and c != '\t' and c != '\r' and c != '\n' and c != ','
            and c != ']' and c != '}' and c != '#'):
      error "unsupported value"
    return int.parse (text_[start..pos_].replace --all "_" "")

  parse-basic-string -> string:
    advance  // '"'.
    start := pos_
    result := ""
    while true:
      c := peek
      if c == null or c == '\n': error "unterminated string"
      if c == '"':
        result += text_[start..pos_]
        advance
        return result
      if c == '\\':
        result += text_[start..pos_]
        advance
        e := peek
        if e == null: error "unterminated string"
        advance
        if e == 'b': result += "\b"
        else if e == 't': result += "\t"
        else if e == 'n': result += "\n"
        else if e == 'f': result += "\f"
        else if e == 'r': result += "\r"
        else if e == '"': result += "\""
        else if e == '\\': result += "\\"
        else if e == 'u' or e == 'U':
          n := e == 'u' ? 4 : 8
          if pos_ + n > text_.size: error "bad escape"
          hex := text_[pos_..pos_ + n]
          value := int.parse hex --radix=16 --if-error=: error "bad escape"
          pos_ += n
          result += string.from-rune value
        else:
          error "bad escape"
        start = pos_
        continue
      if c < 0x20 and c != '\t': error "control character in a string"
      pos_++

  parse-literal-string -> string:
    advance  // '\''.
    start := pos_
    while true:
      c := peek
      if c == null or c == '\n': error "unterminated string"
      if c == '\'':
        result := text_[start..pos_]
        advance
        return result
      pos_++

  parse-array -> List:
    advance  // '['.
    result := []
    while true:
      skip-blank
      if peek == ']':
        advance
        return result
      result.add parse-value
      skip-blank
      if peek == ',':
        advance
        continue
      if peek == ']':
        advance
        return result
      error "expected ',' or ']'"

  parse-inline-table -> Map:
    advance  // '{'.
    result := {:}
    skip-spaces
    if peek == '}':
      advance
      return result
    while true:
      skip-spaces
      parse-key-value result
      skip-spaces
      if peek == ',':
        advance
        continue
      if peek == '}':
        advance
        return result
      error "expected ',' or '}'"
