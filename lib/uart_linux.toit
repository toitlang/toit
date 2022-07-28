// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import monitor show ResourceState_
import reader
import writer

/**
Support for Universal asynchronous receiver-transmitter (UART).

UART features asynchronous communication with an external device on two data
  pins and two optional flow-control pins.
*/

/**
The UART port exposes the hardware features for communicating with an external
  peripheral using asynchronous communication.
*/
class Port implements reader.Reader:
  static STOP_BITS_1   ::= 1
  static STOP_BITS_1_5 ::= 2
  static STOP_BITS_2   ::= 3

  static PARITY_DISABLED ::= 1
  static PARITY_EVEN     ::= 2
  static PARITY_ODD      ::= 3

  state_/ResourceState_? := ?

  constructor device/string
      --baud_rate/int
      --data_bits/int=8
      --stop_bits/int=STOP_BITS_1
      --parity/int=PARITY_DISABLED:
    group := resource_group_
    id := uart_create_ group device baud_rate data_bits stop_bits parity
    state_ = ResourceState_ group id

  /**
  Changes the baud rate.
  Deprecated. Use $baud_rate= instead
  */
  set_baud_rate new_rate/int:
    uart_set_baud_rate_ state_.resource new_rate

  /**
  Sets the baud rate to the given $new_rate.

  The receiver should be ready to read and write data at the specified
    baud rate.
  */
  baud_rate= new_rate/int:
    uart_set_baud_rate_ state_.resource new_rate

  /** The current baud rate. */
  baud_rate:
    return uart_get_baud_rate_ state_.resource

  /**
  Closes this UART port and release all associated resources.
  */
  close:
    state := state_
    if not state: return
    critical_do:
      state_ = null
      uart_close_ state.group state.resource

  /**
  Writes data to the port.

  If $break_length is greater than 0, an additional break signal is added after
    the data is written. The duration of the break signal is bit-duration * $break_length,
    where bit-duration is the duration it takes to write one bit at the current baud rate.

  If not all bytes could be written without blocking, this will be indicated by
    the return value.  In this case the break is not written even if requested.
    The easiest way to handle this by using the $writer.Writer class.  Alternatively,
    something like the following could be used.

  ```
  for position := 0; position < data.size; null:
    position += my_uart.write data[position..data.size]
  ```

  If $wait is true, the method blocks until all bytes that were written have been emitted to the
    physical pins. This is equivalent to calling $flush. Otherwise, returns as soon as the data is
    buffered.

  Returns the number of bytes written.
  */
  write data from=0 to=data.size --break_length=0 --wait=false -> int:
    while true:
      state := ensure_state_ WRITE_STATE_
      written := uart_write_ state.resource data from to break_length wait
      if written == 0 and from != to:
        // We shouldn't have tried to write.
        state.clear_state WRITE_STATE_
        continue

      if written >= 0: return written
      assert: wait
      flush
      return -written

  /**
  Reads data from the port.

  This method will block until data is available.
  */
  read -> ByteArray?:
    while true:
      state := ensure_state_ READ_STATE_
      if not state: return null
      res := uart_read_ state.resource
      if res: return res
      state.clear_state READ_STATE_

  /**
  Flushes the output buffer, waiting until all written data has been transmitted.

  Often, one can just use the `--wait` flag of the $write function instead.
  */
  flush -> none:
    while true:
      flushed := uart_wait_tx_ state_.resource
      if flushed: return
      sleep --ms=1

  ensure_state_ bits:
    state := ensure_state_
    state_bits /int? := null
    while state_bits == null:
      state_bits = state.wait_for_state (bits | ERROR_STATE_)
    if not state_.resource: return null  // Closed from a different task.
    assert: state_bits != 0
    // If the ERROR_STATE_ bit is set the next operation (read or write) will fail and
    // give an appropriate error message.
    // The UDP implementation simply closes by itself and uses getsockopt to get the error. There
    // doesn't seem to be anything similar for normal file descriptors, which is why we call
    // read/write instead.
    return state

  ensure_state_:
    if state_: return state_
    throw "CLOSED"

resource_group_ ::= uart_init_

READ_STATE_  ::= 1 << 0
ERROR_STATE_ ::= 1 << 1
WRITE_STATE_ ::= 1 << 2

uart_init_:
  #primitive.uart_linux.init

uart_create_ resource_group device baud_rate data_bits stop_bits parity:
  #primitive.uart_linux.create

uart_set_baud_rate_ resource baud:
  #primitive.uart_linux.set_baud_rate

uart_get_baud_rate_ resource:
  #primitive.uart_linux.get_baud_rate

uart_close_ resource_group resource:
  #primitive.uart_linux.close

/**
Writes the $data to the uart.
Returns the amount of bytes that were written.

If $wait is true, but the baud rate was too low to wait, returns a negative number, where
  the absolute value is the amount of bytes that were written.
*/
uart_write_ uart data from to break_length wait:
  #primitive.uart_linux.write

uart_wait_tx_ resource:
  #primitive.uart_linux.wait_tx

uart_read_ resource:
  #primitive.uart_linux.read
