// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import monitor
import ..advertising as advertising
import ..hci as hci
import ..scanning as scanning
import ..transport as transport
import .api as api
import .provider as rpc
import .advertising-provider as advertising-provider
import ..timeouts as timeouts

/**
The experimental BLE service provider for advertising and legacy scanning.

$Provider adds scanning to `advertising-provider`: a $ScanSession owns the
  controller for its duration and queues reports for the client, within
  bounds. It is the small image for deployments without GATT; a deployment
  subclasses it and supplies $Provider.open-transport. `central-provider`
  builds on it.
*/

/** Provides legacy scanning with bounded queues without importing ATT, GATT or SMP. */
abstract class Provider extends advertising-provider.Provider:
  constructor:
    super

  /** Opens the exclusively owned controller transport in the serving task. */
  abstract open-transport -> transport.Transport

  /**
  Selects a static random or resolvable private address for one scan session.

  Returns six HCI-order bytes or null for the public default. The scanner
    validates and copies the result before setup. Trusted provider code owns
    the identity policy; no address is supplied through application RPC.
  */
  scan-local-random-address -> ByteArray?:
    return privacy-irk ? local-random-address : null

  /** Rotates the scanning address this often, or never for null (the default without privacy). */
  scan-address-rotation-interval -> Duration?: return address-rotation-interval

  /**
  Runs the scan in the session worker using the provider's address policy.

  The scoped $report block queues reports promptly.
  */
  run-scan controller/hci.Controller
      --active/bool --interval/int --window/int --filter-duplicates/bool
      --statistics/scanning.Statistics [report] -> int:
    rotation := scan-address-rotation-interval
    if rotation:
      return scanning.scan controller report
          --active=active
          --interval=interval
          --window=window
          --filter-duplicates=filter-duplicates
          --statistics=statistics
          --rotation-interval=rotation
          --next-address=: scan-local-random-address
    return scanning.scan controller report
        --active=active
        --interval=interval
        --window=window
        --filter-duplicates=filter-duplicates
        --statistics=statistics
        --local-random-address=scan-local-random-address

  capabilities -> List: return [api.CAP-ADVERTISING | api.CAP-SCAN | api.CAP-CONTINUOUS-SCAN, 60_000_000, 0, 0, 1]

  create-session client/int -> rpc.Session:
    throw "GATT_UNSUPPORTED_SERVICE_OPERATION"

  create-scan client/int arguments/List -> rpc.Session:
    if arguments.size != 6 and arguments.size != 7: throw "INVALID_ARGUMENT"
    duration/int? := arguments[0]
    active/bool := arguments[1]
    interval/int := arguments[2]
    window/int := arguments[3]
    duplicates/bool := arguments[4]
    uuid/ByteArray? := arguments[5]
    limited/bool := arguments.size == 7 ? arguments[6] : false
    if (duration != null and not 1 <= duration <= 60_000_000) or not 4 <= window <= interval <= 0x4000:
      throw "INVALID_ARGUMENT"
    if uuid and uuid.size != 2 and uuid.size != 4 and uuid.size != 16: throw "INVALID_ARGUMENT"
    return ScanSession this client duration active interval window duplicates uuid limited

class ScanSession extends rpc.Session:
  reports_/Reports_ ::= Reports_
  transport_/transport.Transport? := null
  controller_/hci.Controller? := null
  worker_/Task? := null
  ended_/monitor.Latch ::= monitor.Latch
  released_/bool := false
  cleanup-error_ := null
  scan-error_ := null
  statistics_/scanning.Statistics ::= scanning.Statistics

  constructor provider/Provider client/int duration/int? active/bool interval/int window/int duplicates/bool uuid/ByteArray? limited/bool:
    filter := uuid and uuid.copy
    super provider client
    worker_ = task --background::
      error := null
      try:
        error = catch:
          transport_ = provider.open-transport
          controller_ = hci.Controller transport_
          provider.controller-ready transport_ controller_ (hci.initialize controller_)
          deadline := duration and (Time.monotonic-us + duration)
          elapsed := catch:
            with-timeout (duration and (Duration --us=duration)):
              provider.run-scan controller_ --active=active --interval=interval --window=window
                  --filter-duplicates=duplicates
                  --statistics=statistics_
                  (: | report/advertising.Report |
                    if (not limited or report.limited-discoverable) and (not filter or (report.has-service filter)):
                      reports_.add report
                    true)
          if elapsed:
            if not deadline or elapsed != DEADLINE-EXCEEDED-ERROR or Time.monotonic-us < deadline or not statistics_.stopped:
              throw elapsed
      finally:
        critical-do --no-respect-deadline:
          cleanup-error_ = catch:
            if controller_: controller_.close
            else if transport_: transport_.close
          join-error := catch:
            if controller_: controller_.wait-closed
          cleanup-error_ = cleanup-error_ or join-error or (controller_ and controller_.close-error)
          released_ = cleanup-error_ == null
          failure := error or cleanup-error_
          scan-error_ = failure
          reports_.finish (failure and failure.stringify)
          ended_.set true

  is-released -> bool: return is-closed and ended_.has-value and released_

  invoke index/int arguments/List -> any:
    if not arguments.is-empty: throw "INVALID_ARGUMENT"
    if index == api.SCAN-NEXT: return reports_.take
    if index == api.SCAN-STOP:
      if worker_ and not ended_.has-value: worker_.cancel
      critical-do --no-respect-deadline:
        with-timeout timeouts.WORKER: ended_.get
      if cleanup-error_: throw cleanup-error_.stringify
      if scan-error_: throw scan-error_.stringify
      return [statistics_.dropped-events, reports_.dropped, reports_.remaining]
    return super index arguments

  on-closed -> none:
    super
    if worker_: worker_.cancel

monitor Reports_:
  queue_/Deque ::= Deque
  done_/bool := false
  error_ := null
  dropped/int := 0

  add report/advertising.Report -> none:
    if done_: return
    if queue_.size >= 32:
      dropped++
      return
    queue_.add [report.event-type, report.address-type, report.address.copy, report.data.copy, report.rssi]

  finish error -> none:
    done_ = true
    error_ = error

  remaining -> int: return queue_.size

  take -> List?:
    await: done_ or not queue_.is-empty
    if error_: throw error_
    if not queue_.is-empty: return queue_.remove-first
    return null
