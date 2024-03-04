// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio
import monitor show ResourceState_
import reader
import writer

class StopBits:
  value_ /int

  constructor.private_ value:
    value_ = value

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
  static STOP-BITS-1   ::= StopBits.private_ 1
  static STOP-BITS-1-5 ::= StopBits.private_ 2
  static STOP-BITS-2   ::= StopBits.private_ 3

  static PARITY-DISABLED ::= 1
  static PARITY-EVEN     ::= 2
  static PARITY-ODD      ::= 3

  /** Normal UART mode. */
  static MODE-UART ::= 0
  /** Uses the RTS pin to reserve the RS485 line when sending. */
  static MODE-RS485-HALF-DUPLEX ::= 1
  /** IRDA UART mode. */
  static MODE-IRDA ::= 2

  uart_ := ?
  state_/ResourceState_

  /** Number of encountered errors. */
  errors := 0

  /**
  Constructs a UART port using the given $tx for transmission and $rx
    for read.

  The pins use the given $baud-rate. The baud rate must match the baud
    rate of the device.

  The $rts and $cts pins are optional flow-control pins. The host can signal
    on $rts that whether it is ready to receive data. The peripheral can
    signal the host on $cts whether it is ready to receive data.

  The $data-bits, $parity, and $stop-bits define the data framing of the UART
    messages.

  The $mode parameter must be one of:
  - $MODE-UART (default)
  - $MODE-RS485-HALF-DUPLEX: uses the $rts pin to reserve the RS485 line when sending.
    Disables flow control, and $cts must be null.
  - $MODE-IRDA

  Some pins are preferred (more efficient) for use as UART pins on the ESP 32:

  tx = 17, rx = 16 rts = 7 and cts = 8

  (Note that pins 16 and 17 are used for PSRAM on some modules, so they cannot
   be used for UART0.)

  Setting a $high-priority increases the interrupt priority to level 3 on the ESP32.
    If you do not specify true or false for this argument, the high priority is
    automatically selected for baud rates of 460800 or above.

  The ESP32 has hardware support for up to two UART ports (the third one is
    normally already taken for the USB connection/debugging console.
  */
  constructor
      --tx/gpio.Pin? --rx/gpio.Pin? --rts/gpio.Pin?=null --cts/gpio.Pin?=null
      --baud-rate/int --data-bits/int=8 --stop-bits/StopBits=STOP-BITS-1
      --invert-tx/bool=false --invert-rx/bool=false
      --parity/int=PARITY-DISABLED
      --mode/int=MODE-UART
      --high-priority/bool?=null:
    if (not tx) and (not rx): throw "INVALID_ARGUMENT"
    if mode == MODE-RS485-HALF-DUPLEX and cts: throw "INVALID_ARGUMENT"
    if not MODE-UART <= mode <= MODE-IRDA: throw "INVALID_ARGUMENT"

    tx-flags := (invert-tx ? 1 : 0) + (invert-rx ? 2 : 0)
    if high-priority == null: high-priority = baud-rate >= 460800
    if high-priority:
      tx-flags |= 8
    uart_ = uart-create_
      resource-group_
      tx ? tx.num : -1
      rx ? rx.num : -1
      rts ? rts.num : -1
      cts ? cts.num : -1
      baud-rate
      data-bits
      stop-bits.value_
      parity
      tx-flags
      mode
    state_ = ResourceState_ resource-group_ uart_

  /**
  Constructs a UART port using a $device path.

  This constructor does not work on embedded devices, such as the ESP32.

  On some platforms the $baud-rate must match one that is supported by the operating system. See $Port.baud-rate=.
  */
  constructor device/string
      --baud-rate/int
      --data-bits/int=8
      --stop-bits/StopBits=STOP-BITS-1
      --parity/int=PARITY-DISABLED:
    return HostPort device --baud-rate=baud-rate --data-bits=data-bits --stop-bits=stop-bits --parity=parity

  constructor.host-port_ device/string
       --baud-rate/int
       --data-bits/int=8
       --stop-bits/StopBits=STOP-BITS-1
       --parity/int=PARITY-DISABLED:
     group := resource-group_
     uart_ = uart-create-path_ group device baud-rate data-bits stop-bits.value_ parity
     state_ = ResourceState_ group uart_

  /**
  Sets the baud rate to the given $new-rate.

  The receiver should be ready to read and write data at the specified
    baud rate.

  Some platforms only support a fixed set of baud rates. For example, on Linux only the
    following baud rates are supported: 50, 75, 110, 134, 150, 200, 300, 600, 1200,
    1800, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 576000, 921600,
    1152000, 1500000, 2000000, 2500000, 3000000, 3500000, 4000000.

  On macOS the baud rate can be set to arbitrary values.
  */
  baud-rate= new-rate/int:
    uart-set-baud-rate_ uart_ new-rate

  /** The current baud rate. */
  baud-rate -> int:
    return uart-get-baud-rate_ uart_

  /**
  Closes this UART port and releases all associated resources.
  */
  close:
    if not uart_: return
    critical-do:
      state_.dispose
      uart-close_ resource-group_ uart_
      uart_ = null

  /**
  Writes data to the Port.

  If $break-length is greater than 0, an additional break signal is added after
    the data is written. The duration of the break signal is bit-duration * $break-length,
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
  write data from=0 to=data.size --break-length=0 --wait=false -> int:
    size := to - from
    while from < to:
      from += write-no-wait_ data from to --break-length=break-length

    if wait: flush

    return size

  /**
  Reads data from the port.

  This method blocks until data is available.

  Returns null if closed.
  */
  read -> ByteArray?:
    while true:
      state-bits := state_.wait-for-state READ-STATE_ | ERROR-STATE_
      if not uart_: return null
      if state-bits & ERROR-STATE_ != 0:
        state_.clear-state ERROR-STATE_
        errors++
      else if state-bits & READ-STATE_ != 0:
        data := uart-read_ uart_
        if data and data.size > 0: return data
        state_.clear-state READ-STATE_

  /**
  Flushes the output buffer, waiting until all written data has been transmitted.

  Often, one can just use the `--wait` flag of the $write function instead.
  */
  flush -> none:
    while true:
      if not uart_: throw "CLOSED"
      flushed := uart-wait-tx_ uart_
      if flushed: return
      yield

  write-no-wait_ data from=0 to=data.size --break-length=0:
    while true:
      s := state_.wait-for-state WRITE-STATE_ | ERROR-STATE_
      if not uart_: throw "CLOSED"
      written := uart-write_ uart_ data from to break-length
      if written < to - from:
        // Not everything was written, clear write flag and try again.
        state_.clear-state WRITE-STATE_
        if written == 0: continue

      return written

/**
Extends the functionality of the UART Port on platforms that support configurable RS232 devices. It allows setting
  and reading control lines.
*/
class HostPort extends Port:
  /**
    See super class constructor.
  */
  constructor device/string
      --baud-rate/int
      --data-bits/int=8
      --stop-bits/StopBits=Port.STOP-BITS-1
      --parity/int=Port.PARITY-DISABLED:
    super.host-port_ device --baud-rate=baud-rate --data-bits=data-bits --stop-bits=stop-bits --parity=parity

  static CONTROL-FLAG-LE  ::= 1 << 0            /* line enable */
  static CONTROL-FLAG-DTR ::= 1 << 1            /* data terminal ready */
  static CONTROL-FLAG-RTS ::= 1 << 2            /* request to send */
  static CONTROL-FLAG-ST  ::= 1 << 3            /* secondary transmit */
  static CONTROL-FLAG-SR  ::= 1 << 4            /* secondary receive */
  static CONTROL-FLAG-CTS ::= 1 << 5            /* clear to send */
  static CONTROL-FLAG-CAR ::= 1 << 6            /* carrier detect */
  static CONTROL-FLAG-RNG ::= 1 << 7            /* ring */
  static CONTROL-FLAG-DSR ::= 1 << 8            /* data set ready */

  /**
  Read the value of the given control $flag. $flag must be one of the CONTROL_ constants.

  Returns the state of the $flag
  */
  read-control-flag flag/int -> bool:
    return (uart-get-control-flags_ uart_) & flag != 0

  /**
  Read the value of all the control flags. Each bit in the returned value corresponds to the bit position indicated
  by the CONTROL_ constants.
  */
  read-control-flags -> int:
    return uart-get-control-flags_ uart_

  /**
  Sets the $state of a control $flag. $flag must be one of the CONTROL_ constants.
  */
  set-control-flag flag/int state/bool:
    flags := uart-get-control-flags_ uart_
    if state:
      flags |= flag
    else:
      flags &= ~flag
    uart-set-control-flags_ uart_ flags

  /**
  Sets all control $flags to the specified value. Each bit in the $flags corresponds to one of the CONTROL_ constants.
  */
  set-control-flags flags/int:
    uart-set-control-flags_ uart_ flags

resource-group_ ::= uart-init_

READ-STATE_  ::= 1 << 0
ERROR-STATE_ ::= 1 << 1
WRITE-STATE_ ::= 1 << 2

uart-init_:
  #primitive.uart.init

uart-create_ group tx rx rts cts baud-rate data-bits stop-bits parity tx-flags mode:
  #primitive.uart.create

uart-create-path_ resource-group device baud-rate data-bits stop-bits parity:
  #primitive.uart.create-path

uart-set-baud-rate_ uart baud:
  #primitive.uart.set-baud-rate

uart-get-baud-rate_ uart:
  #primitive.uart.get-baud-rate

uart-close_ group uart:
  #primitive.uart.close

/**
Writes the $data to the uart.
Returns the amount of bytes that were written.
*/
uart-write_ uart data from to break-length:
  #primitive.uart.write

uart-wait-tx_ uart:
  #primitive.uart.wait-tx

uart-read_ uart:
  #primitive.uart.read

uart-set-control-flags_ uart flags:
  #primitive.uart.set-control-flags

uart-get-control-flags_ uart:
  #primitive.uart.get-control-flags

