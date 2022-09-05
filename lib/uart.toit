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
  pins and two optional flow-control pins. Commonly they are called "serial ports".
*/

/**
The UART Port exposes the hardware features for communicating with an external
  peripheral using asynchronous communication.
*/
class Port implements reader.Reader:
  static STOP_BITS_1   ::= 1
  static STOP_BITS_1_5 ::= 2
  static STOP_BITS_2   ::= 3

  static PARITY_DISABLED ::= 1
  static PARITY_EVEN     ::= 2
  static PARITY_ODD      ::= 3

  /** Normal UART mode. */
  static MODE_UART ::= 0
  /** Uses the RTS pin to reserve the RS485 line when sending. */
  static MODE_RS485_HALF_DUPLEX ::= 1
  /** IRDA UART mode. */
  static MODE_IRDA ::= 2

  uart_ := ?
  state_/ResourceState_
  should_ensure_write_state_/bool

  /** Amount of encountered errors. */
  errors := 0

  /**
  Constructs a UART port using the given $tx for transmission and $rx
    for read.

  The pins use the given $baud_rate. The baud rate must match the baud
    rate of the device.

  The $rts and $cts pins are optional flow-control pins. The host can signal
    on $rts that whether it is ready to receive data. The peripheral can
    signal the host on $cts whether it is ready to receive data.

  The $data_bits, $parity, and $stop_bits define the data framing of the UART
    messages.

  The $mode parameter must be one of:
  - $MODE_UART (default)
  - $MODE_RS485_HALF_DUPLEX: uses the $rts pin to reserve the RS485 line when sending.
    Disables flow control, and $cts must be null.
  - $MODE_IRDA

  Some pins are preferred (more efficient) for use as UART pins on the ESP 32:

  tx = 17, rx = 16 rts = 7 and cts = 8

  (Note that pins 16 and 17 are used for PSRAM on some modules, so they cannot
   be used for UART0.)

  The ESP32 has hardware support for up to two UART ports (the third one is
    normally already taken for the USB connection/debugging console.
  */
  constructor
      --tx/gpio.Pin? --rx/gpio.Pin? --rts/gpio.Pin?=null --cts/gpio.Pin?=null
      --baud_rate/int --data_bits/int=8 --stop_bits/int=STOP_BITS_1
      --invert_tx/bool=false --invert_rx/bool=false
      --parity/int=PARITY_DISABLED
      --mode/int=MODE_UART:
    if (not tx) and (not rx): throw "INVALID_ARGUMENT"
    if mode == MODE_RS485_HALF_DUPLEX and cts: throw "INVALID_ARGUMENT"
    if not MODE_UART <= mode <= MODE_IRDA: throw "INVALID_ARGUMENT"

    tx_flags := (invert_tx ? 1 : 0) + (invert_rx ? 2 : 0)
    uart_ = uart_create_
      resource_group_
      tx ? tx.num : -1
      rx ? rx.num : -1
      rts ? rts.num : -1
      cts ? cts.num : -1
      baud_rate
      data_bits
      stop_bits
      parity
      tx_flags
      mode
    should_ensure_write_state_ = false
    state_ = ResourceState_ resource_group_ uart_

  /**
  Constructs a UART port using a $device path.

  This constructor does not work on embedded devices, such as the ESP32.

  On some platforms the $baud_rate must match one that is supported by the operating system. See $Port.baud_rate=.
  */
  constructor device/string
      --baud_rate/int
      --data_bits/int=8
      --stop_bits/int=STOP_BITS_1
      --parity/int=PARITY_DISABLED:
    group := resource_group_
    should_ensure_write_state_ = true
    uart_ = uart_create_path_ group device baud_rate data_bits stop_bits parity
    state_ = ResourceState_ group uart_

  /**
  Changes the baud rate.
  Deprecated. Use $baud_rate= instead
  */
  set_baud_rate new_rate/int:
    uart_set_baud_rate_ uart_ new_rate

  /**
  Sets the baud rate to the given $new_rate.

  The receiver should be ready to read and write data at the specified
    baud rate.

  Some platforms only support a fixed set of baud rates. For example, on Linux only the
    following baud rates are supported: 50, 75, 110, 134, 150, 200, 300, 600, 1200,
    1800, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 576000, 921600,
    1152000, 1500000, 2000000, 2500000, 3000000, 3500000, 4000000.

  On macOS the baud rate can be arbitrary
  */
  baud_rate= new_rate/int:
    uart_set_baud_rate_ uart_ new_rate

  /** The current baud rate. */
  baud_rate -> int:
    return uart_get_baud_rate_ uart_

  /**
  Closes this UART port and releases all associated resources.
  */
  close:
    if not uart_: return
    critical_do:
      state_.dispose
      uart_close_ resource_group_ uart_
      uart_ = null

  /**
  Writes data to the Port.

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
      if should_ensure_write_state_: state_.wait_for_state WRITE_STATE_ | ERROR_STATE_
      if not uart_: throw "CLOSED"
      written := uart_write_ uart_ data from to break_length wait
      if should_ensure_write_state_ and written == 0 and from != to:
        // We shouldn't have tried to write.
        state_.clear_state WRITE_STATE_
        continue

      if written >= 0: return written
      assert: wait
      flush
      return -written

  /**
  Reads data from the port.

  This method blocks until data is available.

  Returns null if closed.
  */
  read -> ByteArray?:
    while true:
      state_bits := state_.wait_for_state READ_STATE_ | ERROR_STATE_
      if not uart_: return null
      if state_bits & ERROR_STATE_ != 0:
        state_.clear_state ERROR_STATE_
        errors++
      else if state_bits & READ_STATE_ != 0:
        data := uart_read_ uart_
        if data and data.size > 0: return data
        state_.clear_state READ_STATE_

  /**
  Flushes the output buffer, waiting until all written data has been transmitted.

  Often, one can just use the `--wait` flag of the $write function instead.
  */
  flush -> none:
    while true:
      flushed := uart_wait_tx_ uart_
      if flushed: return
      sleep --ms=1

/**
Extends the functionality of the UART Port on platforms that support configuratble RS232 devices. It allows setting
and reading control lines.
*/

class ConfigurableDevicePort extends Port:
  /**
    See super class constructor.
  */
  constructor device/string
      --baud_rate/int
      --data_bits/int=8
      --stop_bits/int=Port.STOP_BITS_1
      --parity/int=Port.PARITY_DISABLED:
    super device --baud_rate=baud_rate --data_bits=data_bits --stop_bits=stop_bits --parity=parity

  static CONTROL_FLAG_LE  ::= 1 << 0            /* line enable */
  static CONTROL_FLAG_DTR ::= 1 << 1            /* data terminal ready */
  static CONTROL_FLAG_RTS ::= 1 << 2            /* request to send */
  static CONTROL_FLAG_ST  ::= 1 << 3            /* secondary transmit */
  static CONTROL_FLAG_SR  ::= 1 << 4            /* secondary receive */
  static CONTROL_FLAG_CTS ::= 1 << 5            /* clear to send */
  static CONTROL_FLAG_CAR ::= 1 << 6            /* carrier detect */
  static CONTROL_FLAG_RNG ::= 1 << 7            /* ring */
  static CONTROL_FLAG_DSR ::= 1 << 8            /* data set ready */

  /**
  Read the value of the given control $flag. $flag must be one of the CONTROL_ constants.

  Returns the state of the $flag
  */
  read_control_flag flag/int -> bool:
    return (uart_get_control_flags_ uart_) & flag != 0

  /**
  Read the value of all the control flags. Each bit in the returned value corresponds to the bit position indicated
  by the CONTROL_ constants.
  */
  read_control_flags -> int:
    return uart_get_control_flags_ uart_

  /**
  Sets the $state of a control $flag. $flag must be one of the CONTROL_ constants.
  */
  set_control_flag flag/int state/bool:
    flags := uart_get_control_flags_ uart_
    if state:
      flags |= flag
    else:
      flags &= ~flag
    uart_set_control_flags_ uart_ flags

  /**
  Sets all control $flags to the specified value. Each bit in the $flags corresponds to one of the CONTROL_ constants.
  */
  set_control_flags flags/int:
    uart_set_control_flags_ uart_ flags

resource_group_ ::= uart_init_

READ_STATE_  ::= 1 << 0
ERROR_STATE_ ::= 1 << 1
WRITE_STATE_ ::= 1 << 2

uart_init_:
  #primitive.uart.init

uart_create_ group tx rx rts cts baud_rate data_bits stop_bits parity tx_flags mode:
  #primitive.uart.create

uart_create_path_ resource_group device baud_rate data_bits stop_bits parity:
  #primitive.uart.create_path

uart_set_baud_rate_ uart baud:
  #primitive.uart.set_baud_rate

uart_get_baud_rate_ uart:
  #primitive.uart.get_baud_rate

uart_close_ group uart:
  #primitive.uart.close

/**
Writes the $data to the uart.
Returns the amount of bytes that were written.

If $wait is true, but the baud rate was too low to wait, returns a negative number, where
  the absolute value is the amount of bytes that were written.
*/
uart_write_ uart data from to break_length wait:
  #primitive.uart.write

uart_wait_tx_ uart:
  #primitive.uart.wait_tx

uart_read_ uart:
  #primitive.uart.read

uart_set_control_flags_ uart flags:
  #primitive.uart.set_control_flags

uart_get_control_flags_ uart:
  #primitive.uart.get_control_flags

