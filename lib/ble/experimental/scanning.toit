// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

import .advertising as advertising
import .connection as connection
import .hci as hci

/** Receives the final HCI event-drop count, including on timeout/cancellation. */
class Statistics:
  dropped-events/int := 0
  /** Reports successful scan disable after scanning was enabled. */
  stopped/bool := false

/**
Scans legacy advertisements until $report returns false or the caller unwinds.

Calls the scoped $report block with each advertising.Report. The $interval and
  $window use 625 microsecond units, matching the existing BLE API. Uses the
  controller's public address unless $local-random-address supplies a static
  random or resolvable private address in HCI byte order. The address is copied
  before setup; it remains fixed during this scan. Scan filter policy is unfiltered.
  The controller must already be initialized, with no conflicting procedure
  that prevents changing its random address. Use the policy overload for timed rotation.

Returns the number of dropped HCI advertising events, each potentially containing
  multiple reports. Slow consumers drop new events after $queue-limit events are
  queued. No task or lambda is created for each report. Use with-timeout around
  this call for a deadline; deadline errors propagate after scan cleanup.

Only one scan may own the controller. All exits disable scanning; if that fails,
  the controller is closed because its scanning state can no longer be trusted.
*/
scan controller/hci.Controller
    --active/bool=false
    --interval/int=0x10
    --window/int=0x10
    --filter-duplicates/bool=true
    --queue-limit/int=32
    --statistics/Statistics?=null
    --local-random-address/ByteArray?=null
    [report] -> int:
  if not 4 <= window <= interval <= 0x4000: throw "INVALID_ARGUMENT"
  local := local-random-address and (connection.random-address local-random-address)
  parameters := ByteArray 7
  parameters[0] = active ? 1 : 0
  io.LITTLE-ENDIAN.put-uint16 parameters 1 interval
  io.LITTLE-ENDIAN.put-uint16 parameters 3 window
  parameters[5] = local ? 1 : 0
  reports := controller.open-reports --limit=queue-limit
  if statistics:
    statistics.dropped-events = 0
    statistics.stopped = false
  enabled := false
  try:
    if local: controller.command 0x2005 local
    controller.command 0x200b parameters
    controller.command 0x200c #[1, filter-duplicates ? 1 : 0]
    enabled = true
    running := true
    while running:
      packet := reports.take
      advertising.reports-do packet: | decoded/advertising.Report |
        if running: running = report.call decoded
    return reports.dropped
  finally:
    try:
      if enabled:
        stopped := false
        try:
          // Cleanup must survive the caller's cancellation/expired deadline.
          // The command engine supplies a fresh, bounded command deadline.
          critical-do --no-respect-deadline:
            controller.command 0x200c #[0, 0]
          stopped = true
          if statistics: statistics.stopped = true
        finally:
          if not stopped: controller.close
    finally:
      if statistics: statistics.dropped-events = reports.dropped
      controller.close-reports reports

/**
Scans with a scoped provider address policy and optional timed rotation.

Calls $next-address before setup and at each rotation deadline. It must return
  an owned static random or resolvable private address in HCI byte order, or null
  for public addressing when rotation is disabled. Addresses are validated and
  copied. A rotation interval must be positive and no greater than one hour.

Rotation pauses scanning to change its address. The same report queue and drop
  counter survive that pause; queued reports may originate before the change.
  Controller duplicate filtering restarts with each scan enable. The $report
  block must return promptly: the existing calling task checks the timer between
  HCI events, without an extra task or lambda for each report. Command latency,
  scheduling and callback time prevent a hard realtime guarantee.
*/
scan controller/hci.Controller
    --active/bool=false
    --interval/int=0x10
    --window/int=0x10
    --filter-duplicates/bool=true
    --queue-limit/int=32
    --statistics/Statistics?=null
    --rotation-interval/Duration?=null
    [report] [--next-address] -> int:
  if not 4 <= window <= interval <= 0x4000: throw "INVALID_ARGUMENT"
  rotation := rotation-interval and rotation-interval.in-us
  if rotation and not 1 <= rotation <= 3_600_000_000: throw "INVALID_ARGUMENT"
  generated-at := Time.monotonic-us
  local := next-address.call
  local = local and (connection.random-address local)
  if rotation and not local: throw "INVALID_ARGUMENT"
  parameters := ByteArray 7
  parameters[0] = active ? 1 : 0
  io.LITTLE-ENDIAN.put-uint16 parameters 1 interval
  io.LITTLE-ENDIAN.put-uint16 parameters 3 window
  parameters[5] = local ? 1 : 0
  reports := controller.open-reports --limit=queue-limit
  if statistics:
    statistics.dropped-events = 0
    statistics.stopped = false
  enabled := false
  try:
    if local: controller.command 0x2005 local
    controller.command 0x200b parameters
    controller.command 0x200c #[1, filter-duplicates ? 1 : 0]
    enabled = true
    running := true
    while running:
      if rotation and Time.monotonic-us >= generated-at + rotation:
        generated-at = Time.monotonic-us
        next := next-address.call
        if not next: throw "INVALID_ARGUMENT"
        local = connection.random-address next
        controller.command 0x200c #[0, 0]
        enabled = false
        if statistics: statistics.stopped = true
        controller.command 0x2005 local
        if statistics: statistics.stopped = false
        controller.command 0x200c #[1, filter-duplicates ? 1 : 0]
        enabled = true
      packet := null
      if rotation:
        remaining := generated-at + rotation - Time.monotonic-us
        if remaining <= 0: continue
        error := catch:
          with-timeout --us=remaining: packet = reports.take
        if error:
          if error == DEADLINE-EXCEEDED-ERROR and Time.monotonic-us >= generated-at + rotation:
            continue
          throw error
      else:
        packet = reports.take
      advertising.reports-do packet: | decoded/advertising.Report |
        if running: running = report.call decoded
    return reports.dropped
  finally:
    try:
      if enabled:
        stopped := false
        try:
          // Cleanup must survive the caller's cancellation/expired deadline.
          // The command engine supplies a fresh, bounded command deadline.
          critical-do --no-respect-deadline:
            controller.command 0x200c #[0, 0]
          stopped = true
          if statistics: statistics.stopped = true
        finally:
          if not stopped: controller.close
    finally:
      if statistics: statistics.dropped-events = reports.dropped
      controller.close-reports reports
