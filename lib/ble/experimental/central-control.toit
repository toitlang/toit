// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

import .connection as connection
import .signaling as signaling
import .hci as hci
import .cancellation show checkpoint
import .link
import .central show Central
import .central-establish show LinkEstablishment_
import .timeouts as timeouts

/**
Link-layer control of a link owner ($Central): connection parameters,
  L2CAP signaling, remote features, PHY, RSSI and transmit power.

Part of $Central; the abstract members are provided by it.
*/
abstract mixin LinkControl_:
  // Provided by Central.
  abstract owns-link link/Link -> bool
  abstract controller_ -> hci.Controller
  abstract fail_ error --propagate-close-error/bool=false -> none
  abstract cleanup_ -> Cleanup_
  abstract abort link/Link --error="HCI_LINK_CLOSED" -> none
  abstract disconnect_ link/Link -> none
  abstract send link/Link channel/int payload/ByteArray -> none
  abstract accept-parameter-requests_ -> bool
  abstract phy-2m_ -> bool

  /**
  Updates a central-role link and waits for the controller's applied parameters.

  One update may be outstanding per link. The returned values can differ from
    the requested range. A command rejection leaves the link usable; timeout or
    cancellation aborts the link because a late completion cannot identify a new
    request. The default completion bound is 30 seconds.
  */
  update-parameters link/Link --interval-min/int --interval-max/int
      --latency/int=0 --supervision-timeout/int=400
      --timeout/Duration=(Duration --s=30) -> connection.Update:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.info.role != 0: throw "HCI_UPDATE_REQUIRES_CENTRAL"
    if timeout.in-us <= 0: throw "INVALID_ARGUMENT"
    bytes := connection.update-parameters link.info.handle
        --interval-min=interval-min
        --interval-max=interval-max
        --latency=latency
        --supervision-timeout=supervision-timeout
    if link.parameter-worker_: throw "HCI_PARAMETER_UPDATE_BUSY"
    return update-parameters_ link bytes timeout

  update-parameters_ link/Link bytes/ByteArray timeout/Duration -> connection.Update:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    if link.parameter-pending_: throw "HCI_PARAMETER_UPDATE_BUSY"
    pending := monitor.Latch
    link.parameter-pending_ = pending
    completed := false
    try:
      return with-timeout timeout:
        error := catch: controller_.command 0x2013 bytes --status-event
        if error:
          if error is hci.CommandError: completed = true
          throw error
        result/connection.Update := pending.get
        completed = true
        if result.status != 0: throw (ConnectionError result.status)
        result
    finally:
      critical-do --no-respect-deadline:
        if link.parameter-pending_ == pending: link.parameter-pending_ = null
        if not completed and link.connected: abort link --error="HCI_PARAMETER_UPDATE_ABORTED"

  /**
  Handles an LE signaling PDU without waiting for parameter application.

  With the owner's explicit acceptance option, valid peripheral requests are
    accepted only while this link has no outstanding update. A single bounded
    worker submits the HCI command; applied state and failure are exposed on
    the link. Other requests retain the fixed-channel rejection policy.
  */
  handle-signaling link/Link bytes/ByteArray -> none:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    // Core 6.3, Vol 3 Part A, 4: duplicate requests should receive the same
    // response. Keep only the last request, scoped to this connection lifetime.
    if link.peer-parameter-request_ == bytes:
      send link 5 #[0x13, bytes[1], 2, 0, link.peer-parameter-verdict_, 0]
      return
    request/signaling.ParameterRequest? := null
    if link.info.role == 0 and accept-parameter-requests_ and bytes.size <= 23:
      request = signaling.decode-parameter-request bytes
    // The public caller may reuse its buffer once this call returns.
    retained := request and bytes.copy
    if not request or link.info.role != 0 or not accept-parameter-requests_ or
        not request.valid or link.parameter-pending_ or link.parameter-worker_:
      response := signaling.response bytes --peripheral=(link.info.role == 1)
      if response:
        send link 5 response
        // Another request, including an unsupported one, supersedes the
        // saved request. Ignored responses do not change this state.
        link.peer-parameter-request_ = retained
        link.peer-parameter-verdict_ = 1
      return
    parameters := connection.update-parameters link.info.handle
        --interval-min=request.interval-min
        --interval-max=request.interval-max
        --latency=request.latency
        --supervision-timeout=request.supervision-timeout
    tracked := false
    started := false
    try:
      link.parameter-worker_ = true
      link.peer-parameter-error_ = null
      cleanup_.start
      tracked = true
      with-timeout timeouts.SEND: send link 5 #[0x13, request.identifier, 2, 0, 0, 0]
      link.peer-parameter-request_ = retained
      link.peer-parameter-verdict_ = 0
      task --background --name="BLE peer parameters"::
        try:
          error := catch: update-parameters_ link parameters (Duration --s=30)
          if error: link.peer-parameter-error_ = error
        finally:
          critical-do --no-respect-deadline:
            link.parameter-worker_ = false
            cleanup_.done
      started = true
    finally:
      if not started:
        critical-do --no-respect-deadline:
          link.parameter-worker_ = false
          if tracked: cleanup_.done
          if link.connected: abort link --error="HCI_PARAMETER_UPDATE_ABORTED"

  /**
  Completes connection setup with the LE feature exchange on a central link.

  Every mainstream host reads remote features right after connection, and
    peers rely on that ordering: a BlueZ peripheral, for example, drops SMP
    and ATT traffic that arrives before its own side of the exchange has
    finished. The exchange therefore belongs to connection setup: $LinkEstablishment_.connect
    returns only after LE Read Remote Features Complete, within the caller's
    connect deadline. A controller rejection or a failed exchange leaves the
    features unknown without failing the connection. Interruption disconnects
    the new link before unwinding.
  */
  read-features_ link/Link -> none:
    ready := false
    try:
      // A cancelled task skips this classification; cleanup then disconnects
      // the link, so the abandoned command's outcome no longer matters.
      error := catch:
        controller_.command 0x2016 (connection.features-parameters link.info.handle) --status-event
      if error:
        if not (error is hci.CommandError): throw error
        link.features-known_ null
      checkpoint
      error = catch: link.wait-peer-features
      // An ended link is reported by the caller as a lost connection.
      if error and link.connected: throw error
      ready = true
    finally:
      if not ready and link.connected:
        cleanup-error := catch:
          disconnect_ link
        if cleanup-error: fail_ cleanup-error

  /**
  Asks for the 2M PHY on a link this owner initiated when both sides have it.

  The update completes asynchronously ($Link.phy); a rejection or a peer
    that keeps 1M is not an error.
  */
  request-phy_ link/Link -> none:
    if not phy-2m_: return
    features := link.peer-features
    if not features or features.size < 2 or features[1] & 0x01 == 0: return
    // Tracked like an explicit request: controllers run one PHY procedure
    // at a time, and $set-phy waits for this one first.
    pending := monitor.Latch
    link.phy-pending_ = pending
    error := catch:
      controller_.command hci.LE-SET-PHY (connection.phy-2m-parameters link.info.handle) --status-event
    if error:
      if link.phy-pending_ == pending: link.phy-pending_ = null
      if not (error is hci.CommandError): throw error

  /**
  Asks the controllers for PHYs and waits for the outcome.

  $tx and $rx are preference masks (bit 0 1M, bit 1 2M, bit 2 Coded). Either
    side of the link may start this procedure. Returns the PHYs in effect
    afterwards, which may differ from the preference when the peer does not
    support it. One request per link at a time. $timeout bounds the wait for
    the PHY Update Complete event; expiry leaves the link as it is.
  */
  set-phy link/Link --tx/int --rx/int --timeout/Duration=timeouts.PARAMETER-UPDATE -> connection.Phy:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    bytes := connection.phy-parameters link.info.handle --tx=tx --rx=rx
    // Let a running procedure (the automatic one after connecting, or
    // another request) finish; its outcome does not matter here.
    while link.phy-pending_:
      earlier := link.phy-pending_
      catch: with-timeout timeout: earlier.get
      if link.phy-pending_ == earlier: link.phy-pending_ = null
    pending := monitor.Latch
    link.phy-pending_ = pending
    try:
      controller_.command-if hci.LE-SET-PHY bytes --status-event: owns-link link
      return with-timeout timeout: pending.get
    finally:
      critical-do --no-respect-deadline:
        if link.phy-pending_ == pending: link.phy-pending_ = null

  /** Reads the controller's RSSI for this link in dBm (Read RSSI, 7.5.4). */
  read-rssi link/Link -> int:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    parameters := ByteArray 2
    io.LITTLE-ENDIAN.put-uint16 parameters 0 link.info.handle
    result := controller_.command-if 0x1405 parameters: owns-link link
    if result.size != 3: throw "HCI_MALFORMED_RESPONSE"
    return io.LITTLE-ENDIAN.int8 result 2

  /**
  Reads this link's transmit power in dBm (Read Transmit Power Level, 7.3.35).

  $maximum reads the highest level the controller would use instead of the
    current one.
  */
  read-tx-power link/Link --maximum/bool=false -> int:
    if not (owns-link link): throw "HCI_INVALID_LINK"
    parameters := ByteArray 3
    io.LITTLE-ENDIAN.put-uint16 parameters 0 link.info.handle
    parameters[2] = maximum ? 1 : 0
    result := controller_.command-if 0x0c2d parameters: owns-link link
    if result.size != 3: throw "HCI_MALFORMED_RESPONSE"
    return io.LITTLE-ENDIAN.int8 result 2
