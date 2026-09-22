// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor
import ..advertising-set as advertising
import ..connection as connection
import ..hci as hci
import ..transport as transport
import .api as api
import .provider as rpc

/** Provides non-connectable legacy advertising without ATT, GATT or SMP. */
abstract class Provider extends rpc.Provider:
  constructor: super

  abstract open-transport -> transport.Transport

  /** Selects an owned static random or resolvable private address, or public addressing. */
  local-random-address -> ByteArray?: return null

  /** Supplies a provider-owned address rotation interval, or disables timed rotation. */
  address-rotation-interval -> Duration?: return null

  capabilities -> List: return [api.CAP-ADVERTISING, 0, 0, 0, 1]

  create-session client/int -> rpc.Session:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  create-advertising client/int arguments/List -> rpc.Session:
    if arguments.size != 4: throw "INVALID_ARGUMENT"
    data/ByteArray := arguments[0]
    response/ByteArray := arguments[1]
    interval/int := arguments[2]
    scannable/bool := arguments[3]
    if not scannable and not response.is-empty: throw "INVALID_ARGUMENT"
    // Encode owned packets before spawning a task or acquiring the controller.
    generated-at := Time.monotonic-us
    local := local-random-address
    local = local and (connection.random-address local)
    rotation := address-rotation-interval
    if rotation and (not local or rotation.in-us <= 0): throw "INVALID_ARGUMENT"
    parameters := advertising.parameters --interval=interval --type=(scannable ? 2 : 3)
        --own-address-type=(local ? 1 : 0)
    payload := advertising.data data
    scan-response := advertising.data response
    return AdvertisingSession this client parameters payload scan-response local rotation generated-at

class AdvertisingSession extends rpc.Session:
  ready_/monitor.Latch ::= monitor.Latch
  changes_/Changes_ ::= Changes_
  ended_/monitor.Latch ::= monitor.Latch
  worker_/Task? := null
  released_/bool := false
  error_ := null
  scannable_/bool

  constructor provider/Provider client/int parameters/ByteArray data/ByteArray response/ByteArray
      local/ByteArray? rotation/Duration? generated-at/int:
    scannable_ = parameters[4] == 2
    super provider client
    worker_ = task --background::
      radio/transport.Transport? := null
      controller/hci.Controller? := null
      enabled := false
      failure := null
      cleanup-error := null
      try:
        failure = catch:
          radio = provider.open-transport
          controller = hci.Controller radio
          hci.initialize controller
          if local: controller.command 0x2005 local
          controller.command 0x2006 parameters
          controller.command 0x2008 data
          controller.command 0x2009 response
          controller.command 0x200a #[1]
          enabled = true
          ready_.set true
          while not changes_.stopped:
            request/Update_? := null
            expired := false
            if rotation:
              remaining := generated-at + rotation.in-us - Time.monotonic-us
              error := "DEADLINE_EXCEEDED"
              if remaining > 0:
                error = catch:
                  with-timeout --us=remaining: request = changes_.next
              if error and error != "DEADLINE_EXCEEDED": throw error
              expired = error == "DEADLINE_EXCEEDED"
            else:
              request = changes_.next
            if changes_.stopped: break
            if request:
              with-timeout --ms=3_000:
                controller.command 0x2008 request.data
                if not changes_.stopped: controller.command 0x2009 request.response
              if changes_.stopped: break
              changes_.complete request
            else if expired:
              generated-at = Time.monotonic-us
              next := provider.local-random-address
              if not next: throw "INVALID_ARGUMENT"
              local = connection.random-address next
              // This exclusive session cannot create a connection. Stop before
              // changing the address and keep the existing worker's lifetime.
              controller.command 0x200a #[0]
              enabled = false
              if changes_.stopped: break
              controller.command 0x2005 local
              if changes_.stopped: break
              controller.command 0x200a #[1]
              enabled = true
      finally:
        critical-do --no-respect-deadline:
          if controller:
            if enabled:
              cleanup-error = catch: controller.command 0x200a #[0]
            close-error := catch: controller.close
            join-error := catch: controller.wait-closed
            close-error = close-error or join-error
            released_ = close-error == null and controller.close-error == null
            cleanup-error = cleanup-error or close-error or controller.close-error
          else:
            cleanup-error = catch:
              if radio: radio.close
            released_ = cleanup-error == null
          error_ = failure or cleanup-error
          changes_.fail (error_ ? error_.stringify : "BLE_ADVERTISING_CLOSED")
          if not ready_.has-value: ready_.set false
          ended_.set true

  is-released -> bool: return is-closed and ended_.has-value and released_

  invoke index/int arguments/List -> any:
    if index == api.ADVERTISING-UPDATE:
      if arguments.size != 2: throw "INVALID_ARGUMENT"
      data/ByteArray := arguments[0]
      response/ByteArray := arguments[1]
      if not scannable_ and not response.is-empty: throw "INVALID_ARGUMENT"
      request := Update_ (advertising.data data) (advertising.data response)
      if not ready_.has-value or ended_.has-value: throw "BLE_ADVERTISING_CLOSED"
      changes_.post request
      completed := false
      try:
        request.done.get
        completed = true
        return null
      finally:
        if not completed:
          changes_.stop
          if worker_: worker_.cancel
    if not arguments.is-empty: throw "INVALID_ARGUMENT"
    if index == api.ADVERTISING-READY:
      if not ready_.get: throw (error_ ? error_.stringify : "BLE_ADVERTISING_CLOSED")
      return null
    if index == api.ADVERTISING-STOP:
      changes_.stop
      // A stop before readiness must abort pending initialization commands,
      // rather than continue toward enabling advertising for an absent caller.
      if worker_ and not ready_.has-value: worker_.cancel
      critical-do --no-respect-deadline:
        with-timeout --ms=5_000: ended_.get
      if error_: throw error_.stringify
      return null
    return super index arguments

  on-closed -> none:
    super
    if worker_ and not ended_.has-value: worker_.cancel

class Update_:
  data/ByteArray
  response/ByteArray
  done/monitor.Latch ::= monitor.Latch
  constructor .data .response:

// One request, including while its commands run. The advertising worker owns
// updates, address rotation and shutdown; RPC callers never command the radio.
monitor Changes_:
  request_/Update_? := null
  stopped/bool := false

  post request/Update_ -> none:
    if stopped: throw "BLE_ADVERTISING_CLOSED"
    if request_: throw "BLE_ADVERTISING_UPDATE_BUSY"
    request_ = request

  next -> Update_?:
    await: stopped or request_ != null
    return stopped ? null : request_

  complete request/Update_ -> none:
    if request_ != request: throw "BLE_ADVERTISING_UPDATE_MISMATCH"
    critical-do:
      request.done.set true
      request_ = null

  stop -> none: stopped = true

  fail error/string -> none:
    stopped = true
    request := request_
    request_ = null
    if request: request.done.set error --exception
