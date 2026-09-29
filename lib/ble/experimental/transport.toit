// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

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
