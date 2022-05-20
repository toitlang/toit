// Copyright (C) 2019 Toitware ApS.
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

import host.file
import monitor
import reader show Reader
import host.os

PACKAGE_CACHE_PATH := ".cache/toit/tpkg/"

/// Finds the directories where to look for downloaded (cached) packages.
find_package_cache_paths -> List:
  cache_paths := os.env.get "TOIT_PACKAGE_CACHE_PATHS"
  if cache_paths:
    entries := cache_paths.split ":"
    if not entries.is_empty: return entries
  // TODO(florian): we currently require the `HOME` env variable to be set.
  // There are other ways to find the home directory but they aren't
  //   accessible in Toit yet.
  home := os.env["HOME"]
  if not home.ends_with "/": home += "/"
  return [
    "$home$PACKAGE_CACHE_PATH"
  ]

class FakePipeLink:
  next := null
  data/ByteArray := ?

  constructor .data:

// TODO(florian): replace this with a "Buffer" class from io, once that one exists.
class FakePipe implements Reader:
  first := null
  last := null
  is_closed := false
  channel := monitor.Channel 1

  write data from=0 to=data.size:
    copied := null
    if data is string:
      copied = data.to_byte_array
      if from != 0 or to != copied.size: copied = copied.copy from to
    else:
      copied = data.copy from to
    assert: copied is ByteArray
    link := FakePipeLink copied
    if not first:
      first = last = link
    else:
      last.next = link
      last = link
    channel.send null
    return to - from

  read -> ByteArray?:
    while true:
      if not first and is_closed: return null
      if not first:
        signal := channel.receive
        continue
      result := first.data
      first = first.next
      if first == null: last = null
      return result

  close_write:
    is_closed = true
    channel.send null

/**
A Reader/Writer that logs all read/written data.
*/
class LoggingIO implements Reader:
  /// The wrapped reader/writer.
  wrapped_ ::= ?

  /// The writer all read messages should go to.
  log_writer_ / file.Stream ::= ?

  must_close_writer_ /bool ::= false

  constructor .log_writer_ .wrapped_:
  constructor.path path/string .wrapped_ :
    must_close_writer_ = true
    log_writer_ = file.Stream path file.CREAT | file.WRONLY 0x1ff

  read:
    msg := wrapped_.read
    if msg != null: log_writer_.write msg
    return msg

  write data from=0 to=data.size:
    log_writer_.write data from to
    return wrapped_.write data from to

  close:
    if must_close_writer_: log_writer_.close
    wrapped_.close

log_to_file msg:
  log_file := file.Stream "/tmp/lsp.log" (file.WRONLY | file.CREAT | file.APPEND) 0x1ff
  log_file.write "$Time.monotonic_us: $msg\n"

/**
A binary search to find a $needle in a $list of intervals.

Assumes that the $list is sorted.
Returns the greatest index such that element at that slot is less than or equal to $needle.

If $try_first is given, tries that index first.
*/
interval_binary_search list/List needle/int --try_first=null -> int:
  assert: not list.is_empty
  assert: needle >= list.first
  if needle >= list.last: return list.size - 1

  if try_first and
      try_first < list.size - 1 and
      try_first < list[try_first] <= needle < list[try_first]:
    return try_first

  result := list.index_of needle --binary --if_absent=: | insertion_index |
    // $insertion_index points to the index where $needle would need to
    //   inserted. As such, it lies in the range delimited by
    //   $insertion_index - 1 and $insertion_index.
    insertion_index - 1
  // The list might contain empty intervals. Skip over them.
  // Not that $list.last is different from $needle (see above), and
  //   that we thus won't access out of bounds.
  while list[result + 1] == needle: result++
  assert: list[result] <= needle < list[result + 1]
  return result
