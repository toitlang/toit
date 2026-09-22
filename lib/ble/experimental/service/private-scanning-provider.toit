// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import ..privacy as privacy
import ..hci as hci
import ..scanning as scanner
import .scanning-provider as scanning

/**
Provides scanning and non-connectable advertising with timed private addresses.

Owns a copy of the deployment's IRK; persistence and distribution remain the
  creator's responsibility. The default rotation interval is fifteen minutes.
  The one-hour maximum follows Core Vol 3, Part C, 10.7.4 for an Observer.

Uses the existing exclusive session worker and bounded report queues. Address
  changes briefly pause scanning or advertising; controller scan duplicate
  filtering restarts after each pause. This class does not make identifying
  advertising data private or implement connectable advertising privacy.
*/
abstract class Provider extends scanning.Provider:
  irk_/ByteArray
  interval_/Duration
  previous_/ByteArray? := null

  constructor irk/ByteArray --rotation-interval/Duration=(Duration --s=900):
    if irk.size != 16 or not 1 <= rotation-interval.in-us <= 3_600_000_000:
      throw "INVALID_ARGUMENT"
    irk_ = irk.copy
    interval_ = rotation-interval
    super

  address-rotation-interval -> Duration?: return interval_
  scan-address-rotation-interval -> Duration?: return interval_
  scan-local-random-address -> ByteArray?: return local-random-address

  run-scan controller/hci.Controller
      --active/bool --interval/int --window/int --filter-duplicates/bool
      --statistics/scanner.Statistics [report] -> int:
    return scanner.scan controller report
        --active=active
        --interval=interval
        --window=window
        --filter-duplicates=filter-duplicates
        --statistics=statistics
        --rotation-interval=scan-address-rotation-interval
        --next-address=: scan-local-random-address

  local-random-address -> ByteArray?:
    while true:
      address := privacy.generate irk_
      if address == previous_: continue
      previous_ = address.copy
      return address
