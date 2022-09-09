// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import system.api.log show LogService LogServiceClient

import .level

interface Target:
  log level/int message/string names/List? keys/List? values/List? -> none

class DefaultTarget implements Target:
  log level/int message/string names/List? keys/List? values/List? -> none:
    service_.log level message names keys values

/**
Log service used by $DefaultTarget.
*/
service_/LogService ::= (LogServiceClient --no-open).open or
    StandardLogService_

/**
Standard log service used when the system log service cannot
  be resolved.
*/
class StandardLogService_ implements LogService:
  buffer_/bytes.Buffer ::= bytes.Buffer.with_initial_size 64

  log level/int message/string names/List? keys/List? values/List? -> none:
    buffer ::= buffer_
    if names and names.size > 0:
      buffer.write "["
      names.size.repeat:
        if it > 0: buffer.write "."
        buffer.write names[it]
      buffer.write "] "

    buffer.write (level_name level)
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

    print buffer.to_string
    buffer.clear
