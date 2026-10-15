// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import host.file

main args/List:
  if args.size != 4: throw "Usage: provider-recovery-check MODE CENTRAL_LOG FIRST_LOG SECOND_LOG"
  result := check (file.read-contents args[1]).to-string-non-throwing
      (file.read-contents args[2]).to-string-non-throwing
      (file.read-contents args[3]).to-string-non-throwing
      --mode=args[0]
  print (json.encode result).to-string

/** Checks complete fixture logs; flash and capture exits require separate evidence. */
check central/string first/string second/string --mode/string -> Map:
  require_ (mode == "exit" or mode == "pending" or mode == "oom")
  pending := mode != "exit"
  oom := mode == "oom"
  c := Records_ central --central
  require_ (central.contains "[toit] INFO: using SPIRAM for heap metadata and heap")
  old := c.number "PROVIDER_RECOVERY PROVIDER pid="
  a := c.number "SERVICE_MULTIPEER NUMERIC value=" --suffix=" fixture-approval=true"
  b := c.number "SERVICE_MULTIPEER NUMERIC value=" --suffix=" fixture-approval=true"
  c.take "PROVIDER_RECOVERY BEFORE links=2 encrypted=true"
  if pending: c.take "PROVIDER_RECOVERY PENDING reads=2 peer-markers=true"
  if oom:
    c.take "PROVIDER_RECOVERY OOM_ARMED heap-limit=262144"
    require_ (c.heap-reports > 0)
  else:
    require_ (c.heap-reports == 0)
  if pending: c.take "PROVIDER_RECOVERY READS_FAILED count=2 error=NO_SUCH_PROCESS"
  c.take "PROVIDER_RECOVERY DEAD stale-connections=2"
  if oom:
    c.take "PROVIDER_RECOVERY DEAD_CONTAINER exit=1"
    groups := c.next.split " "
    require_ (groups.size == 4 and groups[0] == "PROVIDER_RECOVERY" and groups[1] == "GROUPS")
    x := field_ groups[2] "first="
    y := field_ groups[3] "replacement="
    require_ (x > 0 and y > 0 and x != y)
  fresh := c.number "PROVIDER_RECOVERY PROVIDER pid="
  require_ (old > 0 and fresh > 0 and old != fresh)
  replacement := c.number "SERVICE_MULTIPEER NUMERIC value=" --suffix=" fixture-approval=true"
  [a, b, replacement].do: require_ (0 <= it <= 999999)
  c.take "PROVIDER_RECOVERY COMPLETE replacement-reads=20 stale-value=invalid retained=2"
  c.finish
  peer_ first [a, replacement] 42 pending
  peer_ second [b] 82 pending
  return {"logs_pass": true, "mode": mode, "replacement_reads": 20, "retained": 2,
      "comparison_numbers": [a, b, replacement], "provider_pids": [old, fresh]}

peer_ log/string numbers/List value/int pending/bool:
  rows := Records_ log
  require_ (rows.heap-reports == 0)
  numbers.size.repeat: | index/int |
    rows.take "VHCI_PAIRING NUMERIC value=$(numbers[index]) fixture-approval=true"
    rows.take "VHCI_PAIRING ENCRYPTED encrypted=true authenticated=true"
    if pending and index == 0: rows.take "VHCI_PAIRING READ_PENDING value=$value"
    rows.take "VHCI_PAIRING COMPLETE disconnected=true"
    if numbers.size == 2: rows.take "RECOVERY_PEER CYCLE cycle=$index"
  rows.take "RECOVERY_PEER COMPLETE cycles=$(numbers.size)"
  rows.finish

class Records_:
  lines_/List := []
  index_/int := 0
  heap-reports/int := 0

  constructor log/string --central/bool=false:
    ["EXCEPTION", "Backtrace:", "Guru Meditation"].do: require_ (not (log.contains it))
    normalized := (log.replace "\r\n" "\n").trim
    footer := "\n\nInterrupt received, shutting down gracefully...\nError: context canceled"
    if normalized.ends-with footer: normalized = normalized[..normalized.size - footer.size]
    all := normalized.split "\n"
    require_ ((all.filter: it == "[toit] INFO: entering deep sleep without wakeup time").size == 1)
    require_ (all.last == "[toit] INFO: entering deep sleep without wakeup time")
    all.do: | line/string |
      if line.starts-with "Heap report @ out of memory":
        // OOM reports must occur after arming and before waiter completion.
        require_ (central and not lines_.is-empty and lines_.last == "PROVIDER_RECOVERY OOM_ARMED heap-limit=262144")
        heap-reports++
      if central:
        if line.starts-with "PROVIDER_RECOVERY " or line.starts-with "SERVICE_MULTIPEER NUMERIC ": lines_.add line
      else:
        if line.starts-with "VHCI_PAIRING NUMERIC " or line.starts-with "VHCI_PAIRING ENCRYPTED " or
            line.starts-with "VHCI_PAIRING COMPLETE " or line.starts-with "VHCI_PAIRING READ_PENDING " or
            line.starts-with "RECOVERY_PEER ":
          lines_.add line

  next -> string:
    require_ (index_ < lines_.size)
    return lines_[index_++]
  take expected/string:
    require_ (next == expected)
  number prefix/string --suffix/string="" -> int:
    line := next
    require_ (line.starts-with prefix and line.ends-with suffix)
    return decimal_ line[prefix.size..line.size - suffix.size]
  finish: require_ (index_ == lines_.size)

field_ text/string prefix/string -> int:
  require_ (text.starts-with prefix)
  return decimal_ text[prefix.size..]

decimal_ text/string -> int:
  require_ (not text.is-empty)
  text.size.repeat: require_ (0x30 <= text[it] <= 0x39)
  return int.parse text

require_ condition/bool:
  if not condition: throw "PROVIDER_RECOVERY_CHECK_FAILED"
