// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license in lib/LICENSE.

import io
import monitor

/**
Programmable I/O on RP2350.

Programs are generated from `.pio` files by `tools/pio/compile.py`. A program
  owns no hardware. Each $StateMachine reserves its GPIOs, instruction memory,
  and execution resources until closed.

Buffers contain little-endian 32-bit FIFO words. Shift direction and thresholds
  determine how those words map to wire bits. DMA completion permits buffer
  reuse; it does not imply completion of the protocol on the pins.

All waits suspend the calling Toit task. Native primitives never wait for data.
*/

SHIFT-LEFT ::= 0
SHIFT-RIGHT ::= 1
FIFO-TX-RX ::= 0
FIFO-TX ::= 1
FIFO-RX ::= 2

/** An immutable program image with assembler configuration defaults. */
class Program:
  instructions_/ByteArray
  defaults_/List

  /**
  Creates a program from 16-bit $instructions and assembler metadata.

  Pin counts describe consecutive pin groups. Side-set $side-count excludes
    the optional enable bit. Exported entry labels are instruction offsets.
  */
  constructor instructions/List
      --origin/int=-1 --pio-version/int=0 --used-gpio-ranges/int=0
      --wrap-target/int=0 --wrap/int=(instructions.size - 1)
      --side-count/int=0 --side-optional/bool=false --side-pindirs/bool=false
      --in-count/int=0 --out-count/int=0 --set-count/int=0
      --in-shift/int=SHIFT-RIGHT --out-shift/int=SHIFT-RIGHT
      --auto-push/bool=false --auto-pull/bool=false
      --push-threshold/int=32 --pull-threshold/int=32
      --fifo/int=FIFO-TX-RX --clock-divider/num=1
      --mov-status/int=0 --mov-status-n/int=0:
    if not 1 <= instructions.size <= 32: throw "OUT_OF_RANGE"
    if not -1 <= origin <= 32 - instructions.size: throw "OUT_OF_RANGE"
    if not 0 <= pio-version <= 1: throw "OUT_OF_RANGE"
    if not 0 <= used-gpio-ranges <= 7: throw "OUT_OF_RANGE"
    if not 0 <= wrap-target <= wrap < instructions.size: throw "OUT_OF_RANGE"
    if not 0 <= side-count <= (side-optional ? 4 : 5): throw "OUT_OF_RANGE"
    if side-optional and side-count == 0: throw "INVALID_ARGUMENT"
    if not 0 <= in-count <= 32 or not 0 <= out-count <= 32 or not 0 <= set-count <= 5:
      throw "OUT_OF_RANGE"
    if not 0 <= in-shift <= 1 or not 0 <= out-shift <= 1: throw "OUT_OF_RANGE"
    if not 1 <= push-threshold <= 32 or not 1 <= pull-threshold <= 32: throw "OUT_OF_RANGE"
    if not [0, 1, 2, 4, 8, 12].contains fifo: throw "OUT_OF_RANGE"
    if not 1 <= clock-divider <= 65536: throw "OUT_OF_RANGE"
    if not 0 <= mov-status <= 2 or not 0 <= mov-status-n <= 31: throw "OUT_OF_RANGE"
    instructions_ = ByteArray instructions.size * 2
    instructions.size.repeat: |index|
      instruction/int := instructions[index]
      if not 0 <= instruction <= 0xffff: throw "OUT_OF_RANGE"
      if instruction >> 13 == 0 and (instruction & 31) >= instructions.size:
        throw "INVALID_ARGUMENT"
      io.LITTLE-ENDIAN.put-uint16 instructions_ index * 2 instruction
    defaults_ = [origin, pio-version, used-gpio-ranges, wrap-target, wrap,
      side-count, side-optional ? 1 : 0, side-pindirs ? 1 : 0,
      in-count, out-count, set-count, in-shift, out-shift,
      auto-push ? 1 : 0, auto-pull ? 1 : 0, push-threshold, pull-threshold,
      fifo, (clock-divider * 256).to-int, mov-status, mov-status-n]

  /** The number of instructions. */
  size -> int: return instructions_.size / 2

/** An allocated PIO state machine, initially paused at its entry point. */
class StateMachine:
  resource_ := null
  state_/monitor.ResourceState_? := null
  transfers_/List ::= [null, null]
  irqs_/int := 0

  /**
  Allocates hardware and loads $program without starting execution.

  Pin lists must be consecutive and match any nonzero count declared by the
    program. Directions are independent of pin mappings: $output-pins become
    outputs, initially low unless included in $high-pins. All mentioned pins
    are reserved exclusively, including $wait-pins used by absolute WAIT GPIO
    instructions. Other pins remain inputs. Pull resistors are disabled.

  $irqs reserves block-local IRQ flags 0 through 3 for host notification.
    PIO-to-PIO flags 4 through 7 are not exposed as host events.
  $frequency overrides the program's clock divider, in state-machine ticks per
    second; the actual frequency is rounded to the nearest hardware divider.
  */
  constructor program/Program
      --frequency/int?=null --entry/int=0
      --in-pins/List=[] --out-pins/List=[] --set-pins/List=[] --side-pins/List=[]
      --jmp-pin/int?=null --wait-pins/List=[] --output-pins/List=[] --high-pins/List=[]
      --irqs/List=[]
      --in-shift/int?=null --out-shift/int?=null
      --auto-push/bool?=null --auto-pull/bool?=null
      --push-threshold/int?=null --pull-threshold/int?=null --fifo/int?=null:
    if not 0 <= entry < program.size: throw "OUT_OF_RANGE"
    if frequency != null and frequency <= 0: throw "OUT_OF_RANGE"
    config := program.defaults_.copy
    config[8] = pin-count_ in-pins config[8] 32
    config[9] = pin-count_ out-pins config[9] 32
    config[10] = pin-count_ set-pins config[10] 5
    if side-pins.size != config[5]: throw "INVALID_ARGUMENT"
    pin-count_ side-pins config[5] 5
    if in-shift != null: config[11] = in-shift
    if out-shift != null: config[12] = out-shift
    if auto-push != null: config[13] = auto-push ? 1 : 0
    if auto-pull != null: config[14] = auto-pull ? 1 : 0
    if push-threshold != null: config[15] = push-threshold
    if pull-threshold != null: config[16] = pull-threshold
    if fifo != null: config[17] = fifo
    pins := in-pins + out-pins + set-pins + side-pins + wait-pins
    if jmp-pin != null: pins.add jmp-pin
    mask := pin-mask_ pins
    outputs := pin-mask_ output-pins
    highs := pin-mask_ high-pins
    if outputs & ~mask != 0 or highs & ~outputs != 0: throw "INVALID_ARGUMENT"
    irqs.do: |irq/int|
      if not 0 <= irq <= 3: throw "OUT_OF_RANGE"
      irqs_ |= 1 << irq
    config += [entry, frequency or 0,
      in-pins.is-empty ? -1 : in-pins.first,
      out-pins.is-empty ? -1 : out-pins.first,
      set-pins.is-empty ? -1 : set-pins.first,
      side-pins.is-empty ? -1 : side-pins.first,
      jmp-pin == null ? -1 : jmp-pin,
      mask & 0xffff_ffff, mask >> 32, outputs & 0xffff_ffff, outputs >> 32,
      highs & 0xffff_ffff, highs >> 32, irqs_]
    bytes := ByteArray config.size * 4
    config.size.repeat: |index|
      value/int := config[index]
      io.LITTLE-ENDIAN.put-uint32 bytes index * 4 value & 0xffff_ffff
    resource_ = create_ group_ program.instructions_ bytes
    succeeded := false
    try:
      state_ = monitor.ResourceState_ group_ resource_
      add-finalizer this:: close
      succeeded = true
    finally:
      if not succeeded: close

  /** Starts or resumes execution at the current program counter. */
  start -> none: resume
  /** Pauses execution, retaining FIFOs, registers, and pin levels. */
  pause -> none: control_ checked_ 0
  /** Resumes execution. */
  resume -> none: control_ checked_ 1
  /**
  Resets to the configured entry, directions, and levels and remains paused.

  Requires all transfers to have been reclaimed or closed. Clears FIFOs,
    scratch and shift registers, IRQ flags, and clock-divider phase.
  */
  reset -> none:
    critical-do:
      if transfers_[0] != null or transfers_[1] != null: throw "INVALID_STATE"
      control_ checked_ 2
      state_.clear

  /** The actual state-machine clock frequency in Hz. */
  frequency -> float: return frequency_ checked_

  /**
  Submits $bytes and returns immediately, copying by default.

  With $copy false, permits consumption of the buffer as described by $write.
    After successful submission the caller must stop using the original and
    reclaim storage through $Transfer.take-buffer. A rejected submission
    leaves the original usable.
  */
  submit-write bytes/ByteArray --copy/bool=true -> Transfer:
    return submit_ 0 bytes bytes.size copy null

  /**
  Submits reception into $buffer and returns immediately.

  By default receives into native storage and copies back when the transfer
    is reclaimed. With $copy false, permits consumption of an external buffer;
    callers must use the fresh buffer returned by $Transfer.take-buffer.
  */
  submit-read buffer/ByteArray --copy/bool=true -> Transfer:
    return submit_ 1 buffer buffer.size copy (copy ? buffer : null)

  /**
  Writes all FIFO words, suspending this task until DMA completes.

  With $copy false, permits ownership transfer: after successful submission
    the original must no longer be used. For reusable buffers use $submit-write
    and $Transfer.take-buffer instead. Whole aligned external arrays in DMA
    SRAM transfer without copying. Other byte arrays are copied.
  */
  write bytes/ByteArray --copy/bool=true -> none:
    transfer := submit-write bytes --copy=copy
    try:
      transfer.wait
    finally:
      transfer.close

  /** Receives $byte-count bytes into a fresh buffer of 32-bit FIFO words. */
  read byte-count/int -> ByteArray:
    transfer := submit_ 1 null byte-count true null
    try:
      transfer.wait
      return transfer.take-buffer
    finally:
      transfer.close

  /** Writes one unsigned 32-bit FIFO word. */
  write-word value/int -> none:
    if not 0 <= value <= 0xffff_ffff: throw "OUT_OF_RANGE"
    bytes := ByteArray 4
    io.LITTLE-ENDIAN.put-uint32 bytes 0 value
    write bytes

  /** Receives one unsigned 32-bit FIFO word. */
  read-word -> int: return io.LITTLE-ENDIAN.uint32 (read 4) 0

  /** Waits for and acknowledges a reserved PIO IRQ flag. Flags coalesce. */
  wait-for-irq irq/int -> none:
    if not 0 <= irq <= 3 or irqs_ & (1 << irq) == 0: throw "INVALID_ARGUMENT"
    checked_
    state_.wait-for-state 1 << (8 + irq)
    critical-do:
      irq-clear_ checked_ irq
      state_.clear-state 1 << (8 + irq)

  /**
  Closes the machine and wakes its waiters. Repeated calls have no effect.

  Cancels outstanding transfers and releases their buffers once DMA has
    stopped. Buffers cannot be reclaimed through this machine after closing.
    Pins are released to high impedance. Hardware release may be deferred.
  */
  close -> none:
    critical-do:
      if not resource_: return
      if state_: state_.dispose
      close_ resource_
      resource_ = null
      remove-finalizer this

  /** Whether this machine is closed. */
  is-closed -> bool: return resource_ == null

  checked_:
    if not resource_: throw "CLOSED"
    return resource_

  submit_ direction/int bytes/ByteArray? size/int copy/bool destination/ByteArray? -> Transfer:
    checked_
    if size <= 0 or size % 4 != 0 or size > 16 * 1024 * 1024: throw "OUT_OF_RANGE"
    transfer := Transfer_ this direction destination
    critical-do --no-respect-deadline:
      checked_
      if transfers_[direction] != null: throw "ALREADY_IN_USE"
      state_.clear-state 1 << direction
      submit-native_ checked_ direction bytes size copy
      transfers_[direction] = transfer
    return transfer

/** An outstanding transfer. Owns native storage until reclaimed or closed. */
abstract class Transfer:
  /** Waits for completion and throws on cancellation or DMA failure. */
  abstract wait -> none
  /** Requests cancellation without waiting. */
  abstract cancel -> none
  /** Whether DMA has stopped, including cancellation or failure. */
  abstract is-complete -> bool
  /**
  Waits for DMA to stop and returns its buffer, including on transfer failure.

  Transfers ownership exactly once. Old aliases of a consumed buffer remain
    unusable. On partial reads only $transferred bytes contain received data;
    the rest is initialized to zero. Use $wait to check successful completion.
  */
  abstract take-buffer -> ByteArray
  /** The number of bytes transferred so far. */
  abstract transferred -> int
  /** Cancels if needed, waits for DMA to stop, and releases its buffer. */
  abstract close -> none

class Transfer_ extends Transfer:
  machine_/StateMachine
  direction_/int
  destination_/ByteArray? := ?
  released_/bool := false
  result_/int := 0
  count_/int := 0
  reclaim-mutex_/monitor.Mutex ::= monitor.Mutex

  constructor .machine_ .direction_ .destination_:

  is-complete -> bool:
    if released_: return true
    return status_ != 0

  transferred -> int:
    if released_: return count_
    return transferred_ machine_.checked_ direction_

  status_ -> int:
    if released_: return result_
    return status-native_ machine_.checked_ direction_

  wait -> none:
    await_
    if result_ == 2: throw "CANCELLED"
    if result_ == 3: throw "ERROR"

  await_ -> none:
    if released_: return
    result_ = status_
    while result_ == 0:
      machine_.state_.wait-for-state 1 << direction_
      result_ = status_
    count_ = transferred

  cancel -> none:
    if released_: return
    cancel_ machine_.checked_ direction_

  take-buffer -> ByteArray:
    return reclaim-mutex_.do:
      if released_: throw "ALREADY_CLOSED"
      await_
      bytes := take_ machine_.checked_ direction_ destination_
      release_
      return bytes

  close -> none:
    critical-do --no-respect-deadline:
      // A take-buffer caller may hold the reclaim mutex while waiting for
      // DMA. Request cancellation before waiting for that mutex, so close
      // can wake the caller even when no further FIFO data will arrive.
      if not released_ and not machine_.is-closed: cancel
      reclaim-mutex_.do:
        if released_: return
        if machine_.is-closed:
          release_
          return
        await_
        discard_ machine_.checked_ direction_
        release_

  release_ -> none:
    machine_.transfers_[direction_] = null
    destination_ = null
    released_ = true

pin-count_ pins/List declared/int maximum/int -> int:
  if pins.size > maximum or (declared != 0 and pins.size != declared): throw "INVALID_ARGUMENT"
  pins.size.repeat: |index|
    pin/int := pins[index]
    if pin != pins.first + index: throw "INVALID_ARGUMENT"
  return pins.size

pin-mask_ pins/List -> int:
  mask := 0
  pins.do: |pin/int|
    if not 0 <= pin <= 47: throw "OUT_OF_RANGE"
    mask |= 1 << pin
  return mask

group_ ::= init_
init_:
  #primitive.pio.init
create_ group instructions config:
  #primitive.pio.create
close_ resource:
  #primitive.pio.close
control_ resource operation/int:
  #primitive.pio.control
frequency_ resource -> float:
  #primitive.pio.frequency
submit-native_ resource direction/int bytes/ByteArray? size/int copy/bool:
  #primitive.pio.submit
status-native_ resource direction/int -> int:
  #primitive.pio.status
transferred_ resource direction/int -> int:
  #primitive.pio.transferred
cancel_ resource direction/int:
  #primitive.pio.cancel
take_ resource direction/int destination/ByteArray? -> ByteArray:
  #primitive.pio.take
discard_ resource direction/int:
  #primitive.pio.discard
irq-clear_ resource irq/int:
  #primitive.pio.irq-clear
