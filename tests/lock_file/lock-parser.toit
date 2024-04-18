// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A simplified lock-file parser.

Since lock-files are yaml files, this parser is a simplified YAML parser.

Does not deal with lists, or escapes.
Does not allow ":" in keys (unless quoted).
No comments.
Doesn't support JSON-like encodings.
*/
class LockParser:
  text_ / string ::= ?

  // Points to the next non-consumed character.
  index_ / int := 0
  // The indentation of the current line.
  indentation_ / int := 0

  constructor .text_:

  parse-top -> any:
    if index_ == 0 and text_.is-empty: return {:}

    return parse-map:
      if it == "prefixes": continue.parse-map parse-prefixes
      if it == "packages": continue.parse-map parse-packages
      if it == "sdk": continue.parse-map parse-string
      throw "Unexpected entry"

  parse-map [value-block] -> Map:
    result := {:}
    map-indentation := indentation_
    while indentation_ == map-indentation and index_ < text_.size:
      key := parse-string --no-allow-colon
      skip-colon
      value := value-block.call key
      result[key] = value
    return result

  parse-string --allow-colon=true -> string:
    start /int := ?
    end /int := ?
    if text_[index_] == '"':
      start = index_ + 1
      index_++
      while text_[index_] != '"':
        index_++
      end = index_
      index_++
    else:
      start = index_
      while index_ < text_.size:
        c := text_[index_]
        if c == '\n' or (not allow-colon and c == ':'): break
        index_++
      end = index_
    result := text_.copy start index_
    skip-whitespace
    return result

  parse-prefixes -> Map:
    return parse-map: parse-string

  parse-packages -> Map:
    return parse-map: parse-package

  parse-package -> Map:
    return parse-map:
      it == "prefixes" ? parse-prefixes : parse-string

  skip-colon:
    if text_[index_] != ':': throw "Expected colon"
    index_++
    skip-whitespace

  skip-whitespace:
    counting-indentation := false
    while index_ < text_.size:
      if text_[index_] == '\n':
        counting-indentation = true
        indentation_ = 0
      else if text_[index_] == ' ':
        if counting-indentation: indentation_++
      else:
        return
      index_++

parse-lock-file str/string -> Map:
  parser := LockParser str
  return parser.parse-top
