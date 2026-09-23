// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import io
import monitor

import .central as central
import .connection as connection
import .extended-central as extended
import .hci as hci
import .advertising-updates as advertising-updates
import .cancellation show checkpoint
import .timeouts as timeouts

/**
Owns extended central links and accepts through finite legacy advertising PDUs.

Call this module's $configure on a freshly initialized controller before creating
  the owner. Each advertising window lasts at most the requested one second of
  controller advertising time. Cancellation waits for natural termination under
  a separate three-second bound and disconnects a winning link before reuse.
  Missing or inconsistent completion fails the shared controller.

Only one advertising set is used. No extra receive task, packet queue or retained
  per-packet callback is introduced. Controller-based address resolution remains
  unsupported; local random addresses are selected by the host.
*/
class Central extends extended.Central:
  controller_/hci.Controller
  window_/monitor.Latch? := null
  accept-pending_/monitor.Latch? := null
  timeout-seen_/bool := false
  updates_/advertising-updates.Changes? := null

  constructor .controller_ --acl-length/int=27 --acl-count/int=1
      --early-acl-timeout/Duration?=null --receive-limit/int=65
      --link-limit/int=1 --acl-quota/int?=null --accept-parameter-requests/bool=false:
    super controller_ --acl-length=acl-length --acl-count=acl-count
        --early-acl-timeout=early-acl-timeout
        --receive-limit=receive-limit
        --link-limit=link-limit
        --acl-quota=acl-quota
        --accept-parameter-requests=accept-parameter-requests

  accept advertisement/ByteArray --scan-response/ByteArray=#[] --interval/int=160
      --timeout/Duration=(Duration --s=30) --local-random-address/ByteArray?=null
      --updates/advertising-updates.Changes?=null -> central.Link:
    local := local-random-address and (connection.random-address local-random-address)
    parameters := parameters_ interval (local ? 1 : 0)
    data := data_ advertisement
    response := data_ scan-response
    return with-timeout timeout:
      with-accept-procedure local --updates=updates: | pending/monitor.Latch |
        accept-pending_ = pending
        updates_ = updates
        created := false
        // The engine owns the enable; cleanup settles one this task abandoned.
        enable/hci.Pending? := null
        try:
          // The set may exist once the command is out; cleanup removes it
          // even when this task leaves before the reply.
          creation := controller_.submit 0x2036 parameters
          created = true
          selected/ByteArray? := null
          try:
            selected = creation.wait
          finally: | is-exception exception |
            // A rejected creation leaves no set; classify here so a
            // cancellation arriving with the reply cannot skip it.
            if is-exception and exception.value is hci.CommandError: created = false
          if selected.size != 1: throw "HCI_MALFORMED_RESPONSE"
          checkpoint
          if local:
            controller_.command 0x2035 (#[0] + local)
            checkpoint
          controller_.command 0x2037 data
          checkpoint
          controller_.command 0x2038 response
          checkpoint
          while true:
            if updates and updates.ended and not pending.has-value: throw "HCI_ADVERTISING_UPDATE_ABORTED"
            window_ = monitor.Latch
            timeout-seen_ = false
            // Publish the window before submission: its event may precede
            // Command Complete. A cancelled task skips this classification
            // (its catch rethrows CANCELED after the block) and cleanup
            // settles the enable instead.
            enable = controller_.submit 0x2039 #[1, 1, 0, 100, 0, 0]
            error := catch: enable.wait
            if error:
              if error is hci.CommandError and not window_.has-value and not pending.has-value:
                window_ = null
              else:
                catch: close
              throw error
            checkpoint
            if updates:
              updates.ready
              while not window_.has-value:
                request := updates.next
                if request: apply-advertising-update updates request
                if updates.ended:
                  if not pending.has-value: throw "HCI_ADVERTISING_UPDATE_ABORTED"
                  break
            terminal := wait-window_ pending
            window_ = null
            enable = null
            if terminal[4] == 0: continue.with-accept-procedure pending.get
            checkpoint
        finally: | is-exception _ |
          critical-do --no-respect-deadline:
            error := catch:
              if window_ and enable:
                // A rejected enable without an event opened no window.
                settled := catch: enable.wait
                if settled is hci.CommandError and not window_.has-value and not pending.has-value:
                  window_ = null
              if window_: wait-window_ pending
              if created:
                removal := catch: controller_.command 0x203c #[0]
                // Creation abandoned before its reply may have failed; an
                // unknown set (0x42) then means there is nothing to remove.
                if removal and not (removal is hci.CommandError and removal.status == 0x42):
                  throw removal
            window_ = null
            accept-pending_ = null
            updates_ = null
            if error:
              catch: close
              if not is-exception: throw error

  apply-advertising-update changes/advertising-updates.Changes request/advertising-updates.Request -> none:
    data := data_ request.data
    response := data_ request.response
    error := catch:
      controller_.command-if 0x2037 data: not changes.ended
      // Do not extend a cancelled accept with another update command.
      checkpoint
      if not changes.ended:
        controller_.command-if 0x2038 response: not changes.ended
        checkpoint
    if error:
      if error == "HCI_COMMAND_NOT_SENT" and changes.ended: return
      changes.stop --error=error.stringify
      throw error
    changes.complete request

  wait-window_ pending/monitor.Latch -> ByteArray:
    result/ByteArray? := null
    error := catch:
      with-timeout timeouts.WINDOW: result = window_.get
    // Keep a controller failure primary if the ordinary connection latch
    // already carries it, including while waiting for a missing terminal event.
    if pending.has-value: pending.get
    if error: throw error
    return result

  on-failure error -> none:
    if window_ and not window_.has-value: window_.set error --exception

  handle-controller-event packet/ByteArray -> bool:
    if packet[0] != 4 or packet[1] != 0x3e or packet.size < 4: return false
    if packet[3] == 0x12:
      if not window_ or window_.has-value or packet.size != 9 or packet[5] != 0:
        throw "HCI_UNEXPECTED_ADVERTISING_TERMINATION"
      if packet[4] == 0:
        if not accept-pending_.has-value or timeout-seen_:
          throw "HCI_UNEXPECTED_ADVERTISING_TERMINATION"
        link/central.Link := accept-pending_.get
        if (io.LITTLE-ENDIAN.uint16 packet 6) != link.info.handle:
          throw "HCI_UNEXPECTED_ADVERTISING_TERMINATION"
      else if packet[4] != 0x3c or accept-pending_.has-value:
        throw "HCI_UNEXPECTED_ADVERTISING_TERMINATION"
      // On timeout the connection handle is invalid. The event count is
      // diagnostic and is not used for procedure or connection identity.
      window_.set packet
      if updates_: updates_.wake
      return true
    if packet[3] == 0x0a and window_ and packet.size >= 5 and packet[4] == 0x3c:
      if window_.has-value or timeout-seen_ or accept-pending_.has-value:
        throw "HCI_UNEXPECTED_ADVERTISING_TIMEOUT"
      extended.decode-completion packet --role=1
      timeout-seen_ = true
      return true
    return false

/** Enables enhanced connection and advertising termination events before ownership. */
configure controller/hci.Controller info/hci.Capabilities -> none:
  if info.commands[36] & 0x3e != 0x3e or info.commands[37] & 0x81 != 0x81:
    throw "HCI_BOUNDED_ADVERTISING_UNSUPPORTED"
  extended.configure controller info
  controller.command hci.LE-SET-EVENT-MASK #[0x5f, 2, 2, 0, 0, 0, 0, 0]

parameters_ interval/int own-address-type/int -> ByteArray:
  if not 0x20 <= interval <= 0x4000: throw "INVALID_ARGUMENT"
  bytes := #[0, 0x13, 0, 0, 0, 0, 0, 0, 0, 7, own-address-type, 0,
             0, 0, 0, 0, 0, 0, 0, 0x7f, 1, 0, 1, 0, 0]
  io.LITTLE-ENDIAN.put-uint16 bytes 3 interval
  io.LITTLE-ENDIAN.put-uint16 bytes 6 interval
  return bytes

data_ bytes/ByteArray -> ByteArray:
  if bytes.size > 31: throw "INVALID_ARGUMENT"
  return #[0, 3, 1, bytes.size] + bytes
