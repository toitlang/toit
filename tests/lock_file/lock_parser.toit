// Copyright (C) 2021 Toitware ApS. All rights reserved.
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

  parse_top -> any:
    if index_ == 0 and text_.is_empty: return {:}

    return parse_map:
      if it == "prefixes": continue.parse_map parse_prefixes
      if it == "packages": continue.parse_map parse_packages
      if it == "sdk": continue.parse_map parse_string
      throw "Unexpected entry"

  parse_map [value_block] -> Map:
    result := {:}
    map_indentation := indentation_
    while indentation_ == map_indentation and index_ < text_.size:
      key := parse_string --no-allow_colon
      skip_colon
      value := value_block.call key
      result[key] = value
    return result

  parse_string --allow_colon=true -> string:
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
        if c == '\n' or (not allow_colon and c == ':'): break
        index_++
      end = index_
    result := text_.copy start index_
    skip_whitespace
    return result

  parse_prefixes -> Map:
    return parse_map: parse_string

  parse_packages -> Map:
    return parse_map: parse_package

  parse_package -> Map:
    return parse_map:
      it == "prefixes" ? parse_prefixes : parse_string

  skip_colon:
    if text_[index_] != ':': throw "Expected colon"
    index_++
    skip_whitespace

  skip_whitespace:
    counting_indentation := false
    while index_ < text_.size:
      if text_[index_] == '\n':
        counting_indentation = true
        indentation_ = 0
      else if text_[index_] == ' ':
        if counting_indentation: indentation_++
      else:
        return
      index_++

parse_lock_file str/string -> Map:
  parser := LockParser str
  return parser.parse_top
