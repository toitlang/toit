// Copyright (C) 2021 Toitware ApS.
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

import log.target as log
import log.level show PRINT_LEVEL
import bytes

log_buffer_/bytes.Buffer ::= bytes.Buffer.with_initial_size 128

log_format names/List?/* <string> */ level/int message/string tags/Map? /* <string, any> */ --timestamp=true -> string:
  if level == PRINT_LEVEL:
    return message

  buffer ::= log_buffer_

  // Format the string like this:
  //
  //  (5.252721) [at] DEBUG: reading data {foo: bar}

  if timestamp:
    buffer.write "("
    timestamp_prefix buffer
    buffer.write ") "

  if names and names.size > 0:
    buffer.write "["
    for i := 0; i < names.size; i++:
      if i > 0: buffer.write "."
      buffer.write names[i]
    buffer.write "] "
  buffer.write (log.level_name level)
  buffer.write ": "
  buffer.write message
  if tags and tags.size > 0:
    buffer.write " {"
    first := true
    tags.do: | key value |
      if first: first = false
      else: buffer.write ", "
      buffer.write key.stringify
      buffer.write ": "
      buffer.write value.stringify
    buffer.write "}"

  output := buffer.to_string
  buffer.clear
  return output

timestamp_prefix buffer/bytes.Buffer:
  time := Time.monotonic_us
  s := "$(time / 1_000_000)"
  buffer.write s
  buffer.put_byte '.'
  buffer.write "$(%06d time % 1_000_000)"
