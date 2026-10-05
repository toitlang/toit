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

// Keep in sync with src/resources/usb_host_esp32.cc.
CONNECTED-STATE_ ::= 1 << 0
GONE-STATE_ ::= 1 << 1
CONTROL-DONE-STATE_ ::= 1 << 2
IN-DONE-STATE_ ::= 1 << 3
OUT-DONE-STATE_ ::= 1 << 4

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
  Closing it uninstalls the stack again. Closing blocks for up to about 3
  seconds if transfers do not finish.

On the ESP32-S2 and ESP32-S3, closing hands the PHY back to USB
  Serial/JTAG; see the module documentation.
*/
class Host:
  resource_ := ?
  state_/ResourceState_ := ?
  device_/Device? := null
  // Set when the open device is unplugged.
  gone_/GoneFlag_ ::= GoneFlag_

  /**
  Creates the host.

  Throws "ALREADY_IN_USE" if another $Host is open, in this or another
    process.

  Throws "USB_HOST_STUCK" if an earlier $Host could not be cleaned up
    because the device never finished a transfer, and the transfer is
    still in flight. Unplugging the device finishes it; a reboot always
    does.
  */
  constructor:
    resource_ = usb-host-create_ resource-group_
    state_ = ResourceState_ resource-group_ resource_
    // The callback must not capture this: the state is a GC root while it
    //   is registered, so the finalizer would never run.
    gone := gone_
    state_.set-callback:: | state/int |
      if state & GONE-STATE_ != 0: gone.is-set = true
    add-finalizer this:: close

  /**
  Closes the host. Any open $Device is closed first.
  */
  close -> none:
    if not resource_: return
    try:
      if device_: device_.close
    finally:
      critical-do:
        state_.dispose
        usb-host-close_ resource_
        resource_ = null
        remove-finalizer this

  /**
  Waits until a device is attached and enumerated, then opens it.

  Returns immediately if a device is already attached.
  Throws "ALREADY_IN_USE" if a device is already open: currently only one
    device can be open at a time.
  Throws "USB_TRANSFER_STUCK" if the previous device's close couldn't
    finish (see $Device.close) and still can't.
  */
  wait-for-device -> Device:
    if device_: throw "ALREADY_IN_USE"
    while true:
      if not resource_: throw "CLOSED"
      state_.clear-state CONNECTED-STATE_ | GONE-STATE_
      gone_.is-set = false
      info := usb-host-device-open_ resource_
      if info:
        // Another task may have opened it while this one yielded.
        if device_: throw "ALREADY_IN_USE"
        device_ = Device.private_ this info
        return device_
      state_.wait-for-state CONNECTED-STATE_

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
  endpoints/List ::= []

  constructor .number .alternate .class-code .subclass .protocol:

  stringify -> string:
    return "interface $number alt $alternate class $(%02x class-code)/$(%02x subclass)/$(%02x protocol) endpoints $endpoints"

/** An endpoint descriptor of an $InterfaceDescriptor. */
class EndpointDescriptor:
  static TYPE-CONTROL ::= 0
  static TYPE-ISOCHRONOUS ::= 1
  static TYPE-BULK ::= 2
  static TYPE-INTERRUPT ::= 3

  /** The endpoint address (`bEndpointAddress`), including the direction bit. */
  address/int
  /** The raw `bmAttributes`. */
  attributes/int
  /** The maximum packet size in bytes. */
  max-packet-size/int
  /** The polling interval (`bInterval`) of interrupt endpoints. */
  interval/int

  constructor .address .attributes .max-packet-size .interval:

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

  constructor.private_ .host_ info/List:
    gone_ = host_.gone_
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

  Pending IN and OUT transfers are canceled. If a transfer still doesn't
    finish within about a second (a control transfer the device never
    answers), the device stays open on the native side until it does: the
    next $Host.wait-for-device retries the close, and a new $Host reports
    it; see $Host.constructor.
  */
  close -> none:
    if not is-open_: return
    is-open_ = false
    host_.device_ = null
    // Without a deadline: catch rethrows nothing once it has passed, and
    //   closing is often done in a finally after a timeout.
    critical-do --no-respect-deadline:
      // USB_TRANSFER_STUCK is reported by the next wait-for-device or Host
      //   instead.
      if host_.resource_: catch: usb-host-device-close_ host_.resource_

  /**
  Claims the interface with the given $number, so its endpoints can be
    used, and selects the $alternate setting.
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
      if not is-claimed: catch: usb-host-release-interface_ resource_ number

  /** Releases the interface with the given $number. */
  release-interface number/int -> none:
    usb-host-release-interface_ resource_ number

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
  control-out --request-type/int --request/int --value/int=0 --index/int=0 --data/ByteArray=#[] -> none:
    control_ (request-type & ~DIRECTION-IN_) request value index data 0

  control_ request-type/int request/int value/int index/int data/ByteArray length/int -> any:
    control-mutex_.do:
      // The submit returns null while an interrupted control transfer is
      //   still pending.
      wait-for_ CONTROL-DONE-STATE_:
        usb-host-control-submit_ resource_ request-type request value index data length max-packet-size0_
      return wait-for_ CONTROL-DONE-STATE_: usb-host-control-finish_ resource_
    unreachable

  /**
  Calls $block until it returns non-null, waiting for $done-state in
    between.

  The state bit is only a hint: it may belong to an earlier transfer, so
    $block must check for itself (the finish primitives return null while
    their transfer is pending).
  */
  wait-for_ done-state/int [block] -> any:
    state := host_.state_
    while true:
      state.clear-state done-state
      result := block.call
      if result != null: return result
      // Returns at once if the host is closed; the block then throws.
      state.wait-for-state done-state

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
    endpoint cancels it, and whatever it had received is lost.

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
      if in-pending_ and in-pending_ != address: drop-in_
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
  //   The cancel waits natively; throws "USB_TRANSFER_STUCK" after about a
  //   second.
  drop-in_ -> none:
    usb-host-cancel_ resource_ in-pending_
    in-pending_ = null

  /**
  Writes $data to the bulk or interrupt OUT $endpoint.

  Blocks until all data has been accepted by the device.

  If the wait is interrupted, for example by a timeout, the transfer is
    canceled (which waits for it, briefly) before the exception propagates.
    Part of the data may have been sent.

  Throws "USB_TRANSFER_STALL" if the device halts the endpoint; see
    $clear-halt.
  */
  transfer-out endpoint/EndpointDescriptor data/ByteArray -> none:
    if endpoint.is-in: throw "INVALID_ARGUMENT"
    address := endpoint.address
    out-mutex_.do:
      offset := 0
      while offset < data.size:
        accepted := usb-host-out-submit_ resource_ address data[offset..]
        out-pending_ = address
        try:
          wait-for_ OUT-DONE-STATE_: usb-host-out-finish_ resource_
        finally: | is-exception _ |
          out-pending_ = null
          // Does nothing if the transfer already finished. Keeps the
          //   original exception if the cancel fails.
          if is-exception and is-open_ and host_.resource_:
            critical-do --no-respect-deadline:
              catch: usb-host-cancel_ resource_ address
        offset += accepted

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
    interrupt endpoint, up to 512 bytes for a bulk endpoint.
  */
  in-stream endpoint/EndpointDescriptor --buffer-size/int=4096 -> InStream:
    if not endpoint.is-in: throw "INVALID_ARGUMENT"
    address := endpoint.address
    packet-size := endpoint.max-packet-size
    if packet-size <= 0: throw "INVALID_ARGUMENT"
    if packet-size > TRANSFER-BUFFER-SIZE_: throw "UNSUPPORTED"
    // A transfer completes with a short packet or when it is full. An
    //   interrupt endpoint typically sends whole-packet reports, which
    //   would pile up in a bigger transfer; a bulk stream fills whatever
    //   it is given.
    transfer-size := endpoint.is-interrupt
        ? packet-size
        : TRANSFER-BUFFER-SIZE_ / packet-size * packet-size
    in-mutex_.do:
      if in-stream_: throw "ALREADY_IN_USE"
      if in-pending_: drop-in_
      usb-host-in-stream-start_ resource_ address transfer-size buffer-size
      in-stream_ = InStream.private_ this endpoint buffer-size (in-leftover_.get address)
      in-leftover_.remove address
    return in-stream_

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
  throw "USB_NO_DEVICE" when the device is unplugged.
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
      exception := catch --unwind=(: is-stream-open_ and device_.is-open_):
        data = usb-host-in-stream-read_ device_.resource_ buffer-size_
      if exception: return null
      if data: return data
      state.wait-for-state IN-DONE-STATE_

  close_ -> none:
    if not is-stream-open_: return
    is-stream-open_ = false
    leftover_ = null
    try:
      if device_.is-open_ and device_.host_.resource_:
        // Stopping cancels the transfer in flight and waits for it natively
        //   (throwing "USB_TRANSFER_STUCK" after about a second; the next
        //   $Device.in-stream then reports "ALREADY_IN_USE" until
        //   $Device.close finishes the stop). The completion wakes up a read
        //   blocked in another task, which then sees is-stream-open_.
        usb-host-in-stream-stop_ device_.resource_
    finally:
      if device_.in-stream_ == this: device_.in-stream_ = null

class GoneFlag_:
  is-set/bool := false

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
    if type == DESCRIPTOR-TYPE-INTERFACE_ and length >= 9:
      current = InterfaceDescriptor
          bytes[offset + 2]
          bytes[offset + 3]
          bytes[offset + 5]
          bytes[offset + 6]
          bytes[offset + 7]
      result.add current
    else if type == DESCRIPTOR-TYPE-ENDPOINT_ and length >= 7 and current:
      // Bits 11-12 are additional high-speed transactions per microframe.
      max-packet-size := (LITTLE-ENDIAN.uint16 bytes offset + 4) & 0x7ff
      current.endpoints.add
          EndpointDescriptor bytes[offset + 2] bytes[offset + 3] max-packet-size bytes[offset + 6]
    offset += length
  return result

usb-host-init_:
  #primitive.usb_host.init

usb-host-create_ group:
  #primitive.usb_host.create

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

usb-host-in-stream-start_ resource endpoint transfer-size capacity:
  #primitive.usb_host.in_stream_start

usb-host-in-stream-read_ resource max:
  #primitive.usb_host.in_stream_read

usb-host-in-stream-stop_ resource:
  #primitive.usb_host.in_stream_stop
