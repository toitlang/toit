// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

import .data
import .reader
import .writer

/**
Provides direct access to the platform's standard input, output, and error
  streams.

On host platforms, the `host` package provides closeable, terminal-aware
  versions of the same streams. Both packages access the same underlying
  platform streams.
*/

STDIN-READ-STATE_ ::= 1 << 0

stdin-group_ ::= stdin-init_
stdin-instance_ ::= Stdin_
stdout-instance_ ::= StandardWriter_ true
stderr-instance_ ::= StandardWriter_ false

/**
Returns the standard input stream.

On ESP32, input merges the primary console UART and USB Serial/JTAG when they
  are configured as console backends. The ESP32-S2 USB CDC console and other
  console backends are unsupported.

The stream cannot be closed. It shares the platform input with other standard
  input APIs. If multiple readers or containers read concurrently, the first
  reader to consume available data receives it.

On host platforms, use `host.stdin` when closing the stream or querying whether
  it is a terminal is required.
*/
stdin -> Reader:
  return stdin-instance_

/**
Returns the standard output stream.

Writes go directly to the platform's standard output and do not pass through
  the print service. A write is synchronous and may block in the underlying
  platform operation. The stream cannot be closed.

On host platforms, use `host.stdout` when closing the stream or querying
  whether it is a terminal is required.
*/
stdout -> Writer:
  return stdout-instance_

/**
Returns the standard error stream.

Writes go directly to the platform's standard error and do not pass through
  the print service. A write is synchronous and may block in the underlying
  platform operation. The stream cannot be closed.

On host platforms, use `host.stderr` when closing the stream or querying
  whether it is a terminal is required.
*/
stderr -> Writer:
  return stderr-instance_

class Stdin_ extends Reader:
  resource_ := ?
  state_/monitor.ResourceState_

  constructor:
    resource_ = stdin-open_ stdin-group_
    state_ = monitor.ResourceState_ stdin-group_ resource_

  read_ -> ByteArray?:
    while true:
      state_.clear-state STDIN-READ-STATE_
      result := stdin-read_ resource_
      if result != -1: return result
      state_.wait-for-state STDIN-READ-STATE_

class StandardWriter_ extends Writer:
  is-stdout_/bool

  constructor .is-stdout_:

  try-write_ data/Data from/int to/int -> int:
    if from == to: return 0
    bytes := ByteArray.from data from to
    // Deliberately use the synchronous primitives also used by 'print_'. This
    // gives direct standard-stream writes the same printf-like semantics.
    if is-stdout_:
      write-on-stdout_ bytes false
    else:
      write-on-stderr_ bytes false
    return to - from

stdin-init_:
  #primitive.stdio.stdin-init

stdin-open_ group:
  #primitive.stdio.stdin-open

stdin-read_ resource:
  #primitive.stdio.stdin-read

write-on-stdout_ data add-newline/bool:
  #primitive.core.write-on-stdout

write-on-stderr_ data add-newline/bool:
  #primitive.core.write-on-stderr
