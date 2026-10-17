// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import io show LITTLE-ENDIAN
import monitor
import monitor show ResourceState_

/**
USB host support: control transfers and IN/OUT transfers on bulk and
  interrupt endpoints of an attached device.

Isochronous endpoints and hubs are not supported.

Currently only one device can be open at a time, and only one $Host can
  be open at a time in the whole system.

# ESP32-S2 and ESP32-S3
USB host is only available when the firmware is built with
  `CONFIG_TOIT_ENABLE_USB_HOST`. The chips have one full-speed port, so
  exactly one device can be attached.

The same USB PHY is shared between a $Host and the USB Serial/JTAG
  console: while a $Host is open, the console's USB connection is gone, and
  it comes back when the $Host is closed. If you intend to switch between
  the two, start reading stdin before opening a $Host: stdin that starts
  while a $Host is open reads only the UART console, until every program
  reading stdin has stopped.

The board must supply VBUS to the port: most USB devices are powered from
  it. On most devkits a diode between the port and the 5V rail lets power
  flow only into the board, so it has to be bypassed; some devkits have a
  jumper for this.

An open $Host with a device attached uses about 14 KB of internal RAM (not
  PSRAM): two task stacks, the transfer buffers and the host stack's own
  state. Transfers allocate nothing beyond the byte arrays they return.
  Closing the $Host returns all of it.

Control transfers carry at most `CONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE`
  bytes of data (256 by default).

# Examples
```
import usb.host as usb

main:
  host := usb.Host
  try:
    device := host.wait-for-device
    print "$(%04x device.vendor-id):$(%04x device.product-id) $device.product"
    device.interfaces.do: | descriptor/usb.InterfaceDescriptor |
      print descriptor
  finally:
    host.close
```
*/

// Keep in sync with src/resources/usb_host_esp32.cc, see comments there for
// explanation on each state bit.
CONNECTED-STATE_ ::= 1 << 0
GONE-STATE_ ::= 1 << 1
CONTROL-DONE-STATE_ ::= 1 << 2
IN-DONE-STATE_ ::= 1 << 3
OUT-DONE-STATE_ ::= 1 << 4
DEVICE-CLOSED-STATE_ ::= 1 << 5
STOPPED-STATE_ ::= 1 << 6
IN-STOPPED-STATE_ ::= 1 << 7

// How long to wait for the native side to finish a close, a stop or a
//   cancel. It is quick unless a transfer the device never answers is in
//   the way; the native side then carries on without us.
TEARDOWN-TIMEOUT-MS_ ::= 1_000
// How long a new $Host waits for the previous one to be gone.
HOST-BUSY-TIMEOUT-MS_ ::= 3_000
// How long a failed transfer waits for the unplug that may have caused it
//   to be reported, so it can fail with "USB_NO_DEVICE" like the rest.
UNPLUG-GRACE-MS_ ::= 100

// Size of the native IN and OUT transfer buffers.
TRANSFER-BUFFER-SIZE_ ::= 512

DIRECTION-IN_ ::= 0x80

/** Type bits of a control request's `bmRequestType`: a standard request. */
REQUEST-TYPE-STANDARD ::= 0x00
/** Type bits of a control request's `bmRequestType`: a class request. */
REQUEST-TYPE-CLASS ::= 0x20
/** Type bits of a control request's `bmRequestType`: a vendor request. */
REQUEST-TYPE-VENDOR ::= 0x40

/** Recipient bits of a control request's `bmRequestType`: the device. */
REQUEST-RECIPIENT-DEVICE ::= 0x00
/** Recipient bits of a control request's `bmRequestType`: an interface. */
REQUEST-RECIPIENT-INTERFACE ::= 0x01
/** Recipient bits of a control request's `bmRequestType`: an endpoint. */
REQUEST-RECIPIENT-ENDPOINT ::= 0x02

REQUEST-CLEAR-FEATURE_ ::= 1
REQUEST-SET-INTERFACE_ ::= 11

FEATURE-ENDPOINT-HALT_ ::= 0

DESCRIPTOR-TYPE-INTERFACE_ ::= 4
DESCRIPTOR-TYPE-ENDPOINT_ ::= 5

resource-group_ ::= usb-host-init_

/**
The USB host controller.

Creating a $Host installs the USB host stack and enables the port.
  Closing it uninstalls the stack again.

On the ESP32-S2 and ESP32-S3, closing hands the PHY back to USB
  Serial/JTAG; see the module documentation.
*/
class Host:
  resource_ := null
  state_/ResourceState_ := ?
  device_/Device? := null
  // Set by $close before it yields, so no device is opened meanwhile.
  is-closing_/bool := false
  // Set by $Device.close while it waits for the native close, so
  //   $wait-for-device leaves the DEVICE-CLOSED bit to it.
  is-device-closing_/bool := false
  // Holds the open device's flag, set when it is unplugged.
  gone_/GoneHolder_ ::= GoneHolder_

  /**
  Creates the host.

  Throws "ALREADY_IN_USE" if another $Host is open, in this or another
    process.

  Throws "USB_HOST_STUCK" if an earlier $Host is still being cleaned up
    after a few seconds, because the device never finished a transfer.
    Unplugging the device finishes it; a reboot always does.
  */
  constructor:
    deadline := Time.monotonic-us + HOST-BUSY-TIMEOUT-MS_ * 1_000
    resource := null
    while true:
      resource = usb-host-create_ resource-group_
      if resource: break
      // The previous Host is still winding down.
      if Time.monotonic-us >= deadline: throw "USB_HOST_STUCK"
      sleep --ms=10
    state_ = create-state_ resource
    resource_ = resource
    // The callback must not capture this: the state is a GC root while it
    //   is registered, so the finalizer would never run.
    gone := gone_
    state_.set-callback:: | state/int |
      if state & GONE-STATE_ != 0: gone.flag.is-set = true
    add-finalizer this:: close

  // Closes the native resource if the state can't be created: otherwise
  //   it would stay in use until the process exits. Not inlined: a `:= ?`
  //   field can't be assigned inside a try before the implicit super call.
  static create-state_ resource -> ResourceState_:
    try:
      return ResourceState_ resource-group_ resource
    finally: | is-exception _ |
      if is-exception: usb-host-close_ resource

  /**
  Closes the host. Any open $Device is closed first.

  Waits briefly for the native side to shut down; if that takes longer (see
    $Device.close), the shutdown goes on in the background and the next
    $Host waits for it.
  */
  close -> none:
    if not resource_: return
    is-closing_ = true
    try:
      if device_: device_.close
    finally:
      critical-do --no-respect-deadline:
        // Another task may have finished closing while this one waited.
        if resource_:
          catch:
            usb-host-stop_ resource_
            with-timeout --ms=TEARDOWN-TIMEOUT-MS_:
              state_.wait-for-state STOPPED-STATE_
        if resource_:
          state_.dispose
          usb-host-close_ resource_
          resource_ = null
          remove-finalizer this

  /**
  Waits until a device is attached and enumerated, then opens it.

  Returns immediately if a device is already attached. If the previous
    $Device is still being closed (see $Device.close), waits for that
    first.
  Throws "ALREADY_IN_USE" if a device is already open: currently only one
    device can be open at a time.
  */
  wait-for-device -> Device:
    while true:
      if not resource_ or is-closing_: throw "CLOSED"
      if device_: throw "ALREADY_IN_USE"
      // While $Device.close waits for DEVICE-CLOSED the bit is its: clearing
      //   it here would make the close wait out its timeout. A stale bit
      //   otherwise just costs one extra round.
      clear := CONNECTED-STATE_ | GONE-STATE_
      if not is-device-closing_: clear |= DEVICE-CLOSED-STATE_
      state_.clear-state clear
      info := usb-host-device-open_ resource_
      if info:
        // Another task may have opened it while this one yielded.
        if device_: throw "ALREADY_IN_USE"
        gone := GoneFlag_
        gone_.flag = gone
        device_ = Device.private_ this info gone
        return device_
      state_.wait-for-state CONNECTED-STATE_ | DEVICE-CLOSED-STATE_
      // Woken by the closing task's bit: let it finish before looping on it.
      if is-device-closing_: yield

  /**
  Calls $block until it returns non-null, waiting for $done-state in
    between.

  The state bit is only a hint: it may belong to an earlier transfer, so
    $block must check for itself (the finish primitives return null while
    their transfer is pending).
  */
  wait-for_ done-state/int [block] -> any:
    while true:
      state_.clear-state done-state
      result := block.call
      if result != null: return result
      // Returns at once if the host is closed; the block then throws.
      state_.wait-for-state done-state

/**
An interface descriptor of a device's active configuration.

Each alternate setting of an interface has its own descriptor.
*/
class InterfaceDescriptor:
  /** The interface number (`bInterfaceNumber`). */
  number/int
  /** The alternate setting (`bAlternateSetting`). */
  alternate/int
  /** The class code (`bInterfaceClass`). */
  class-code/int
  /** The subclass code (`bInterfaceSubClass`). */
  subclass/int
  /** The protocol code (`bInterfaceProtocol`). */
  protocol/int
  /** The $EndpointDescriptor list of this interface. Must not be modified. */
  endpoints/List

  constructor.private_ .number .alternate .class-code .subclass .protocol .endpoints:

  stringify -> string:
    return "interface $number alt $alternate class $(%02x class-code)/$(%02x subclass)/$(%02x protocol) endpoints $endpoints"

/** An endpoint descriptor of an $InterfaceDescriptor. */
class EndpointDescriptor:
  /** The $type of a control endpoint. */
  static TYPE-CONTROL ::= 0
  /** The $type of an isochronous endpoint; not supported for transfers. */
  static TYPE-ISOCHRONOUS ::= 1
  /** The $type of a bulk endpoint. */
  static TYPE-BULK ::= 2
  /** The $type of an interrupt endpoint. */
  static TYPE-INTERRUPT ::= 3

  /** The endpoint address (`bEndpointAddress`), including the direction bit. */
  address/int
  /** The raw `bmAttributes`. */
  attributes/int
  /** The maximum packet size in bytes. */
  max-packet-size/int
  /** The polling interval (`bInterval`) of interrupt endpoints. */
  interval/int

  constructor.private_ .address .attributes .max-packet-size .interval:

  /** Whether data flows from the device to the host. */
  is-in -> bool: return address & DIRECTION-IN_ != 0
  /** Whether data flows from the host to the device. */
  is-out -> bool: return not is-in
  /** The transfer type; one of $TYPE-CONTROL, $TYPE-ISOCHRONOUS, $TYPE-BULK, or $TYPE-INTERRUPT. */
  type -> int: return attributes & 0x03
  /** Whether this is a bulk endpoint. */
  is-bulk -> bool: return type == TYPE-BULK
  /** Whether this is an interrupt endpoint. */
  is-interrupt -> bool: return type == TYPE-INTERRUPT

  stringify -> string:
    return "ep $(%02x address) type $type mps $max-packet-size"

/**
An attached and opened device.

At most one transfer per kind (control, IN, OUT) is in flight at a time;
  calls of the same kind from several tasks are serialized.
*/
class Device:
  host_/Host
  /** The vendor ID (`idVendor`). */
  vendor-id/int
  /** The product ID (`idProduct`). */
  product-id/int
  /** The device release number (`bcdDevice`), binary-coded decimal. */
  bcd-device/int
  /** The class code (`bDeviceClass`); 0 if each interface has its own. */
  class-code/int
  /** The subclass code (`bDeviceSubClass`). */
  subclass/int
  /** The protocol code (`bDeviceProtocol`). */
  protocol/int
  /** The manufacturer string, if the device has one. */
  manufacturer/string?
  /** The product string, if the device has one. */
  product/string?
  /** The serial number string, if the device has one. */
  serial-number/string?
  /** The raw active configuration descriptor, including all sub-descriptors. */
  configuration-descriptor/ByteArray
  /** The $InterfaceDescriptor list of the active configuration. */
  interfaces/List
  max-packet-size0_/int
  control-mutex_ ::= monitor.Mutex
  in-mutex_ ::= monitor.Mutex
  out-mutex_ ::= monitor.Mutex
  // Received bytes beyond the requested maximum, not yet returned by
  //   $transfer-in, keyed by endpoint address.
  in-leftover_/Map ::= {:}
  // Addresses of the endpoints with a transfer in flight, or null.
  in-pending_/int? := null
  out-pending_/int? := null
  // Whether a $transfer-in is waiting for the IN transfer in flight.
  in-waiting_/bool := false
  // The open $InStream, if any.
  in-stream_/InStream? := null
  gone_/GoneFlag_
  is-open_/bool := true

  constructor.private_ .host_ info/List .gone_:
    vendor-id = info[0]
    product-id = info[1]
    bcd-device = info[2]
    max-packet-size0_ = info[3]
    class-code = info[4]
    subclass = info[5]
    protocol = info[6]
    configuration-descriptor = info[7]
    manufacturer = decode-string_ info[8]
    product = decode-string_ info[9]
    serial-number = decode-string_ info[10]
    interfaces = parse-interfaces_ configuration-descriptor

  /**
  Whether the device has been unplugged.

  Once this is true, all transfers fail and the device should be closed.
  */
  is-gone -> bool:
    return gone_.is-set

  /**
  Releases claimed interfaces and closes the device.

  Pending IN and OUT transfers are canceled. Waits briefly for the device
    to be closed. If a transfer still doesn't finish within about a second
    (a control transfer the device never answers), the close goes on in
    the background until it does: $Host.wait-for-device waits for it, and
    a new $Host waits for it too; see $Host.constructor.
  */
  close -> none:
    if not is-open_: return
    is-open_ = false
    host_.device_ = null
    // Closing the device stops the stream; this just marks the handle.
    if in-stream_: in-stream_.close
    // Without a deadline: catch rethrows nothing once it has passed, and
    //   closing is often done in a finally after a timeout.
    critical-do --no-respect-deadline:
      if host_.resource_:
        host_.is-device-closing_ = true
        try:
          catch:
            with-timeout --ms=TEARDOWN-TIMEOUT-MS_:
              host_.wait-for_ DEVICE-CLOSED-STATE_: usb-host-device-close_ host_.resource_
        finally:
          host_.is-device-closing_ = false

  /**
  Claims the interface with the given $number, so its endpoints can be
    used, and selects the $alternate setting.

  Throws "ALREADY_IN_USE" if the interface is already claimed, and the
    error of the control transfer if the device rejects the alternate
    setting or an endpoint's halt clear (the interface is released again).
  */
  claim-interface number/int --alternate/int=0 -> none:
    usb-host-claim-interface_ resource_ number alternate
    is-claimed := false
    try:
      if alternate != 0:
        // The IDF does not send SET_INTERFACE itself.
        control-out
            --request-type=REQUEST-TYPE-STANDARD | REQUEST-RECIPIENT-INTERFACE
            --request=REQUEST-SET-INTERFACE_
            --value=alternate
            --index=number
      // The IDF gives the endpoints new pipes, which start at DATA0, but the
      //   device keeps its data toggles from an earlier claim (the device is
      //   not reset in between), and silently drops packets until the two
      //   agree. Clearing the halt feature resets the device's toggles.
      interfaces.do: | descriptor/InterfaceDescriptor |
        if descriptor.number == number and descriptor.alternate == alternate:
          descriptor.endpoints.do: | endpoint/EndpointDescriptor | clear-halt endpoint
      is-claimed = true
    finally:
      if not is-claimed:
        critical-do --no-respect-deadline:
          catch: release-interface number

  /**
  Releases the interface with the given $number.

  Throws "USB_INTERFACE_BUSY" if a transfer on one of its endpoints keeps
    it busy for more than a second, and throws if the interface is not
    claimed.
  */
  release-interface number/int -> none:
    // The IDF refuses for a moment after it reported the completion of a
    //   transfer on one of the interface's endpoints.
    deadline := Time.monotonic-us + TEARDOWN-TIMEOUT-MS_ * 1_000
    while not usb-host-release-interface_ resource_ number:
      if Time.monotonic-us >= deadline: throw "USB_INTERFACE_BUSY"
      sleep --ms=1

  /**
  Clears the halt (stall) condition of the $endpoint on the device.

  A transfer that fails with "USB_TRANSFER_STALL" leaves the endpoint halted
    on the device, which rejects further transfers until the halt is
    cleared. This sends CLEAR_FEATURE(ENDPOINT_HALT), which also resets the
    device's data toggle. The host side is reset on its own when the failed
    transfer is picked up.
  */
  clear-halt endpoint/EndpointDescriptor -> none:
    control-out
        --request-type=REQUEST-TYPE-STANDARD | REQUEST-RECIPIENT-ENDPOINT
        --request=REQUEST-CLEAR-FEATURE_
        --value=FEATURE-ENDPOINT-HALT_
        --index=endpoint.address

  /**
  Performs a control transfer with a data stage from the device.

  The $request-type is the type and recipient part of `bmRequestType`, for
    example `REQUEST-TYPE-VENDOR | REQUEST-RECIPIENT-DEVICE`; the direction
    bit is set by this method.
  Returns the received bytes, at most $length.

  Control transfers can't be canceled. If the wait is interrupted, for
    example by a timeout, the transfer stays pending, and the next control
    transfer first waits for it to finish.
  */
  control-in --request-type/int --request/int --value/int=0 --index/int=0 --length/int -> ByteArray:
    return control_ (request-type | DIRECTION-IN_) request value index #[] length

  /**
  Performs a control transfer with $data going to the device.

  See $control-in for $request-type and for interrupted transfers.
  */
  control-out --request-type/int --request/int --value/int=0 --index/int=0 --data/io.Data=#[] -> none:
    control_ (request-type & ~DIRECTION-IN_) request value index data 0

  control_ request-type/int request/int value/int index/int data/io.Data length/int -> any:
    bytes/ByteArray := data is ByteArray ? data : ByteArray.from data
    control-mutex_.do:
      // The submit returns null while an interrupted control transfer is
      //   still pending.
      wait-for_ CONTROL-DONE-STATE_:
        usb-host-control-submit_ resource_ request-type request value index bytes length max-packet-size0_
      return wait-for_ CONTROL-DONE-STATE_: usb-host-control-finish_ resource_
    unreachable

  wait-for_ done-state/int [block] -> any:
    exception := catch: return host_.wait-for_ done-state block
    throw (unplug-error_ exception)

  // A transfer in flight while the device is unplugged can fail with a bus
  //   error a moment before the unplug itself is reported. Gives it that
  //   moment, so every transfer on a gone device throws "USB_NO_DEVICE".
  unplug-error_ error -> any:
    if error is not string or not error.starts-with "USB_TRANSFER_": return error
    if not gone_.is-set: sleep --ms=UNPLUG-GRACE-MS_
    return gone_.is-set ? "USB_NO_DEVICE" : error

  /**
  Reads from the bulk or interrupt IN $endpoint.

  Blocks until the device sends data or the transfer fails. Returns at most
    $max bytes, and possibly fewer even if the device has more to send: a
    single call may be limited by the platform's transfer buffer. If the
    device sends more than $max (the transfer is rounded up to whole
    packets), the rest is returned by the next call.

  If the wait is interrupted, for example by a timeout, the transfer stays
    in flight and the next call for the same endpoint picks it up, so no
    data is lost. Only one IN transfer can be in flight: a call for another
    endpoint cancels it, and whatever it had received is lost. Throws
    "USB_TRANSFER_BUSY" if that transfer doesn't complete within a second.

  Throws "USB_TRANSFER_STALL" if the device halts the endpoint; see
    $clear-halt.
  */
  transfer-in endpoint/EndpointDescriptor --max/int=endpoint.max-packet-size -> ByteArray:
    if not endpoint.is-in or max <= 0: throw "INVALID_ARGUMENT"
    address := endpoint.address
    in-mutex_.do:
      if in-stream_: throw "ALREADY_IN_USE"
      leftover/ByteArray? := in-leftover_.get address
      if leftover:
        if leftover.size <= max:
          in-leftover_.remove address
          return leftover
        in-leftover_[address] = leftover[max..]
        return leftover[..max]
      if in-pending_ and in-pending_ != address:
        drop-in_
        // Still in flight after the cancel wait timed out.
        if in-pending_: throw "USB_TRANSFER_BUSY"
      if not in-pending_:
        packet-size := endpoint.max-packet-size
        if packet-size <= 0: throw "INVALID_ARGUMENT"
        if packet-size > TRANSFER-BUFFER-SIZE_: throw "UNSUPPORTED"
        size := min
            (max + packet-size - 1) / packet-size * packet-size
            TRANSFER-BUFFER-SIZE_ / packet-size * packet-size
        usb-host-in-submit_ resource_ address size packet-size
        in-pending_ = address
      data := wait-in_
      if data.size > max:
        in-leftover_[address] = data[max..]
        data = data[..max]
      return data
    unreachable

  wait-in_ -> ByteArray:
    in-waiting_ = true
    try:
      return wait-for_ IN-DONE-STATE_: finish-in_
    finally:
      in-waiting_ = false

  // Returns the result of the IN transfer in flight, or null while it is
  //   pending. The transfer is no longer in flight once this returns data
  //   or throws.
  finish-in_ -> ByteArray?:
    is-done := true
    try:
      data := usb-host-in-finish_ resource_
      is-done = data != null
      return data
    finally:
      if is-done: in-pending_ = null

  // Cancels the IN transfer in flight and drops its result. The IDF reports
  //   no data for a canceled transfer, even if some packets had arrived.
  drop-in_ -> none:
    critical-do --no-respect-deadline:
      usb-host-cancel_ resource_ in-pending_
      // The transfer completes with "USB_TRANSFER_CANCELED", unless it
      //   finished first. Either way wait-in_ clears in-pending_.
      catch: with-timeout --ms=TEARDOWN-TIMEOUT-MS_: wait-in_

  /**
  Writes $data to the bulk or interrupt OUT $endpoint.

  Blocks until all data has been accepted by the device.

  If the wait is interrupted, for example by a timeout, the transfer is
    canceled before the exception propagates. Part of the data may have
    been sent. If the cancel doesn't complete within a second, the next
    call throws "USB_TRANSFER_BUSY".

  Throws "USB_TRANSFER_STALL" if the device halts the endpoint; see
    $clear-halt.
  */
  transfer-out endpoint/EndpointDescriptor data/io.Data -> none:
    if endpoint.is-in: throw "INVALID_ARGUMENT"
    bytes/ByteArray := data is ByteArray ? data : ByteArray.from data
    address := endpoint.address
    out-mutex_.do:
      if out-pending_:
        // An earlier call was interrupted and its cancel wait timed out.
        drop-out_
        if out-pending_: throw "USB_TRANSFER_BUSY"
      offset := 0
      while offset < bytes.size:
        accepted := usb-host-out-submit_ resource_ address bytes[offset..]
        out-pending_ = address
        try:
          wait-for_ OUT-DONE-STATE_: finish-out_
        finally: | is-exception _ |
          // Does nothing if the transfer already finished. Keeps the
          //   original exception if the cancel fails.
          if is-exception and out-pending_ and is-open_ and host_.resource_: drop-out_
        offset += accepted

  // Returns the number of bytes the OUT transfer in flight sent, or null
  //   while it is pending. The transfer is no longer in flight once this
  //   returns a number or throws.
  finish-out_ -> int?:
    is-done := true
    try:
      result := usb-host-out-finish_ resource_
      is-done = result != null
      return result
    finally:
      if is-done: out-pending_ = null

  // Cancels the OUT transfer in flight and drops its result. Leaves
  //   out-pending_ set if the transfer hasn't completed within the timeout.
  drop-out_ -> none:
    critical-do --no-respect-deadline:
      usb-host-cancel_ resource_ out-pending_
      catch:
        with-timeout --ms=TEARDOWN-TIMEOUT-MS_:
          wait-for_ OUT-DONE-STATE_: finish-out_

  /**
  Opens a reader that streams from the bulk or interrupt IN $endpoint.

  Transfers keep running in the background, into a buffer of $buffer-size
    bytes, so no data is lost while the program is busy, as long as the
    buffer doesn't fill up; then the device is asked to wait. Packet
    boundaries are not kept: use $transfer-in for message-oriented
    endpoints.

  Only one IN transfer can be in flight, so $transfer-in throws
    "ALREADY_IN_USE" while the stream is open. Close the returned
    $InStream when done.

  Data an earlier $transfer-in on the same $endpoint received but didn't
    return yet comes first.

  The $buffer-size must hold at least one transfer: the packet size for an
    interrupt endpoint, up to 512 bytes for a bulk endpoint; throws
    "OUT_OF_RANGE" otherwise. Throws "MALLOC_FAILED" if the buffer can't be
    allocated, and "USB_TRANSFER_BUSY" if a $transfer-in left a transfer in
    flight that can't be canceled.

  If closing the stream times out (its transfer never completes, see
    $Device.close), the endpoint stays busy: $transfer-in and $in-stream
    throw until the transfer completes or the device is closed.
  */
  in-stream endpoint/EndpointDescriptor --buffer-size/int=4096 -> InStream:
    if not endpoint.is-in: throw "INVALID_ARGUMENT"
    address := endpoint.address
    packet-size := endpoint.max-packet-size
    if packet-size <= 0: throw "INVALID_ARGUMENT"
    if packet-size > TRANSFER-BUFFER-SIZE_: throw "UNSUPPORTED"
    // A transfer completes on a short packet or once it is full. Interrupt
    //   endpoints send one full-size report at a time, so a transfer bigger
    //   than a packet would hold reports back until it fills; bulk endpoints
    //   stream, so they get the whole buffer.
    transfer-size := endpoint.is-interrupt
        ? packet-size
        : TRANSFER-BUFFER-SIZE_ / packet-size * packet-size
    in-mutex_.do:
      if in-stream_: throw "ALREADY_IN_USE"
      if in-pending_:
        drop-in_
        if in-pending_: throw "USB_TRANSFER_BUSY"
      stream := InStream.private_ this endpoint buffer-size (in-leftover_.get address)
      usb-host-in-stream-start_ resource_ address transfer-size packet-size buffer-size
      in-stream_ = stream
      in-leftover_.remove address
      return stream
    unreachable

  /**
  Cancels the transfer in flight on the $endpoint, if any.

  The $transfer-in or $transfer-out call waiting for it, typically in
    another task, throws "USB_TRANSFER_CANCELED". Data the transfer had
    already received is lost.

  Does nothing for an endpoint with an open $InStream: close the stream
    instead.
  */
  cancel-transfer endpoint/EndpointDescriptor -> none:
    address := endpoint.address
    if in-pending_ == address:
      if in-waiting_:
        usb-host-cancel_ resource_ address
      else:
        in-mutex_.do:
          if in-pending_ == address: drop-in_
    else if out-pending_ == address:
      usb-host-cancel_ resource_ address

  // The native resource; throws if the device or the host is closed.
  resource_ -> any:
    if not is-open_: throw "CLOSED"
    resource := host_.resource_
    if not resource: throw "CLOSED"
    return resource

  stringify -> string:
    return "usb device $(%04x vendor-id):$(%04x product-id) rev $(%04x bcd-device)"

/**
A reader for a bulk or interrupt IN endpoint, see $Device.in-stream.

Reading returns whatever has arrived, and blocks while nothing has. Reads
  throw "USB_NO_DEVICE" when the device is unplugged, and "USB_TRANSFER_STALL"
  (see $Device.clear-halt) or another transfer error when the endpoint
  fails; the stream is over then and should be closed.
*/
class InStream extends io.CloseableReader:
  device_/Device
  endpoint_/EndpointDescriptor
  buffer-size_/int
  is-stream-open_/bool := true
  // Bytes to return before the stream's own.
  leftover_/ByteArray? := ?

  constructor.private_ .device_ .endpoint_ .buffer-size_ .leftover_:

  read_ -> ByteArray?:
    state := device_.host_.state_
    while true:
      if not is-stream-open_ or not device_.is-open_: return null
      if leftover_:
        data := leftover_
        leftover_ = null
        return data
      state.clear-state IN-DONE-STATE_
      data/ByteArray? := null
      // A close in another task cancels the stream under us; clear-state
      //   can yield, so the close can come after the check above.
      exception := catch:
        data = usb-host-in-stream-read_ device_.resource_ buffer-size_
      if exception:
        if not is-stream-open_ or not device_.is-open_: return null
        throw (device_.unplug-error_ exception)
      if data: return data
      state.wait-for-state IN-DONE-STATE_

  close_ -> none:
    if not is-stream-open_: return
    is-stream-open_ = false
    leftover_ = null
    try:
      host := device_.host_
      if device_.is-open_ and host.resource_:
        // Stopping cancels the transfer in flight; the stop is done once it
        //   has completed. The completion wakes up a read blocked in
        //   another task, which then sees is-stream-open_.
        critical-do --no-respect-deadline:
          catch:
            with-timeout --ms=TEARDOWN-TIMEOUT-MS_:
              host.wait-for_ IN-STOPPED-STATE_: usb-host-in-stream-stop_ host.resource_
    finally:
      if device_.in-stream_ == this: device_.in-stream_ = null

class GoneFlag_:
  is-set/bool := false

// Points the Host's state callback at the open device's flag.
class GoneHolder_:
  flag/GoneFlag_ := GoneFlag_

decode-string_ utf-16/ByteArray? -> string?:
  if not utf-16: return null
  return string.from-utf-16 utf-16

/**
Parses the interface and endpoint descriptors of a configuration descriptor.

Stops at the first descriptor with an impossible length, as Linux does
  ("skipping remainder of the config"): the length is the only way to find
  the next descriptor. Endpoints before the first interface descriptor are
  ignored.
*/
parse-interfaces_ bytes/ByteArray -> List:
  result := []
  current/InterfaceDescriptor? := null
  offset := 0
  while offset + 2 <= bytes.size:
    length := bytes[offset]
    type := bytes[offset + 1]
    if length < 2 or offset + length > bytes.size: break
    if type == DESCRIPTOR-TYPE-INTERFACE_:
      if length >= 9:
        current = InterfaceDescriptor.private_
            bytes[offset + 2]
            bytes[offset + 3]
            bytes[offset + 5]
            bytes[offset + 6]
            bytes[offset + 7]
            []
        result.add current
      else:
        // Too short to be one; its endpoints belong to no interface.
        current = null
    else if type == DESCRIPTOR-TYPE-ENDPOINT_ and length >= 7 and current:
      // Bits 11-12 are additional high-speed transactions per microframe.
      max-packet-size := (LITTLE-ENDIAN.uint16 bytes offset + 4) & 0x7ff
      current.endpoints.add
          EndpointDescriptor.private_ bytes[offset + 2] bytes[offset + 3] max-packet-size bytes[offset + 6]
    offset += length
  return result

usb-host-init_:
  #primitive.usb_host.init

usb-host-create_ group:
  #primitive.usb_host.create

usb-host-stop_ resource:
  #primitive.usb_host.stop

usb-host-close_ resource:
  #primitive.usb_host.close

usb-host-device-open_ resource:
  #primitive.usb_host.device_open

usb-host-device-close_ resource:
  #primitive.usb_host.device_close

usb-host-claim-interface_ resource number alternate:
  #primitive.usb_host.claim_interface

usb-host-release-interface_ resource number:
  #primitive.usb_host.release_interface

usb-host-control-submit_ resource request-type request value index data length max-packet-size0:
  #primitive.usb_host.control_submit

usb-host-control-finish_ resource:
  #primitive.usb_host.control_finish

usb-host-out-submit_ resource endpoint data:
  #primitive.usb_host.out_submit

usb-host-out-finish_ resource:
  #primitive.usb_host.out_finish

usb-host-in-submit_ resource endpoint max max-packet-size:
  #primitive.usb_host.in_submit

usb-host-in-finish_ resource:
  #primitive.usb_host.in_finish

usb-host-cancel_ resource endpoint:
  #primitive.usb_host.cancel

usb-host-in-stream-start_ resource endpoint transfer-size max-packet-size capacity:
  #primitive.usb_host.in_stream_start

usb-host-in-stream-read_ resource max:
  #primitive.usb_host.in_stream_read

usb-host-in-stream-stop_ resource:
  #primitive.usb_host.in_stream_stop
