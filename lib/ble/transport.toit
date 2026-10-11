// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The interface between the host and a controller.

$Transport carries complete HCI packets (packet-type byte included) in both
  directions; the controller engine owns one and the native Linux and ESP32
  transports, the in-memory test transport and the btsnoop and hexdump
  tracing wrappers implement it. $TxPowerControl is the optional extension a
  transport implements when its controller can set transmit power through a
  vendor interface.
*/

/**
A transport whose controller has vendor transmit power control.

HCI has no command to set the transmit power of legacy advertising or of
  connections; some controllers offer it through their vendor API.
*/
interface TxPowerControl:
  /** Returns the advertising transmit power in dBm, or null while the controller is off. */
  tx-power -> int?

  /**
  Sets advertising, scanning and connection transmit power.

  Uses the supported level closest to $dbm and returns it, or returns null
    without effect while the controller is off.
  */
  set-tx-power dbm/int -> int?

  /** Returns the supported level closest to $dbm without changing anything. */
  closest-tx-power dbm/int -> int

  /**
  Sets the transmit power of the connection with the HCI $handle, until it
    ends; others keep theirs.

  Uses the supported level closest to $dbm and returns it, or returns null
    without effect while the controller is off.
  */
  set-connection-tx-power handle/int dbm/int -> int?

  /**
  Returns the transmit power of the connection with the HCI $handle in dBm,
    as the vendor control knows it, or null while the controller is off.
  */
  connection-tx-power handle/int -> int?

/** A transport of complete HCI packets, including their packet-type byte. */
interface Transport:
  /** Waits for and returns one owned packet. Throws when closed or failed. */
  receive -> ByteArray

  /** Waits until the transport accepts the packet's bytes. */
  send packet/ByteArray -> none

  /**
  Submits only if $allowed is true immediately before transport acceptance.

  Rechecks after every wait. The scoped predicate must not wait or perform IO.
    Returns false without submitting when permission has expired.
  */
  send-if packet/ByteArray [allowed] -> bool

  /** Closes the transport and wakes pending operations. Idempotent. */
  close -> none
