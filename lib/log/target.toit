// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import system.api.log show LogService LogServiceClient

import .level

interface Target:
  log level/int message/string names/List? keys/List? values/List? timestamp/bool -> none

class DefaultTarget implements Target:
  log level/int message/string names/List? keys/List? values/List? timestamp/bool -> none:
    service_.log level message names keys values timestamp

/**
Log service used by $DefaultTarget.
*/
service_/LogService ::= (LogServiceClient).open
   --if-absent=: StandardLogService_

/**
Standard log service used when the system log service cannot
  be resolved.
*/
class StandardLogService_ implements LogService:
  buffer_/io.Buffer ::= io.Buffer.with-capacity 64

  log level/int message/string names/List? keys/List? values/List? timestamp/bool -> none:
    buffer ::= buffer_

    if timestamp:
      buffer.write "$(Time.monotonic-us / 1000)"
      buffer.write " "

    if names and names.size > 0:
      buffer.write "["
      names.size.repeat:
        if it > 0: buffer.write "."
        buffer.write names[it]
      buffer.write "] "

    buffer.write (level-name level)
    buffer.write ": "
    buffer.write message

    if keys and keys.size > 0:
      buffer.write " {"
      keys.size.repeat:
        if it > 0: buffer.write ", "
        buffer.write keys[it]
        buffer.write ": "
        buffer.write values[it]
      buffer.write "}"

    // Printing the constructed message may block, so we have to
    // be careful and clear the buffer before doing so. Otherwise,
    // another task might start using the non-empty buffer and
    // interleaving the output in strange ways.
    constructed ::= buffer.to-string
    buffer.clear
    print constructed
