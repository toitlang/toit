// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.hex
import encoding.json
import host.file
import io

// Offline evidence only. Adapter restoration remains a separate acceptance gate.
main args/List:
  require_ (3 <= args.size <= 7) "Usage: soak-check HOST_LOG BOARD_LOG HOST_EXIT_CODE [COUNT [HOST_EVERY [BOARD_EVERY [MINIMUM_SECONDS]]]]"
  result := check (file.read-contents args[0]).to-string (file.read-contents args[1]).to-string
      --host-exit-code=(int.parse args[2])
      --count=(args.size > 3 ? (int.parse args[3]) : 864000)
      --host-every=(args.size > 4 ? (int.parse args[4]) : 1000)
      --board-every=(args.size > 5 ? (int.parse args[5]) : 1000)
      --minimum-seconds=(args.size > 6 ? (int.parse args[6]) : 86400)
  print (json.encode result).to-string

/** Validates complete numbered soak logs, using host elapsed time for duration. */
check host/string board/string --host-exit-code/int --count/int=864000
    --host-every/int=1000 --board-every/int=1000 --minimum-seconds/int=86400 -> Map:
  require_ (10 <= count <= 1000000 and host-every > 0 and board-every > 0 and minimum-seconds >= 0) "Invalid expected limits"
  require_ (host-exit-code == 0) "Host exit was not successful"
  host-end := endpoint_ host count host-every --host
  board-end := endpoint_ board count board-every --no-host
  host-elapsed := number_ host-end "elapsed-us"
  require_ (host-elapsed >= minimum-seconds * 1000000) "Host duration too short"
  require_ ((number_ board-end "validated") == count and (number_ board-end "reads") == 2) "Board handler count mismatch"
  return {
    "log_checks_pass": true,
    "count": count,
    "host_elapsed_us": host-elapsed,
    "board_elapsed_us": number_ board-end "elapsed-us",
    "duration_24h": host-elapsed >= 86400000000,
    "adapter_restoration_verified": false,
  }

endpoint_ text/string count/int every/int --host/bool -> Map:
  ["ASSERTION_FAILED", "EXCEPTION", "Guru Meditation", "Backtrace:"].do: | marker/string |
    require_ (not (text.contains marker)) "Runtime failure in logs"
  progress-prefix := host ? "ECHO " : "BLE_SERVICE_APP ECHO "
  terminal-prefix := host ? "ECHO_COMPLETE " : "BLE_SERVICE_APP COMPLETE "
  stats-prefix := host ? "process-stats=" : "BLE_SERVICE_APP process-stats="
  key := host ? "sequence" : "count"
  offset := host ? 0 : 1
  next := 0
  previous := -1
  progress-done := false
  stats-seen := false
  provider-seen := false
  terminal/Map? := null
  (text.split "\n").do: | line/string |
    if line.ends-with "\r": line = line[..line.size - 1]
    if line.starts-with progress-prefix:
      require_ (not terminal and not progress-done) "Progress after completion or duplicate progress"
      row := fields_ line[progress-prefix.size..]
      require_ ((number_ row key) - offset == next) "Progress sequence mismatch"
      bytes := ByteArray 4
      io.LITTLE-ENDIAN.put-uint32 bytes 0 next
      require_ ((row.get "data") == (hex.encode bytes) + "546f6974484349") "Payload mismatch"
      elapsed := number_ row "elapsed-us"
      require_ (elapsed >= previous) "Elapsed counter went backward"
      previous = elapsed
      if next == count - 1: progress-done = true
      else: next = min (next + every) (count - 1)
    else if line.starts-with terminal-prefix:
      require_ (not terminal and progress-done) "Missing progress, early or duplicate terminal"
      terminal = fields_ line[terminal-prefix.size..]
      require_ ((number_ terminal "count") == count) "Terminal count mismatch"
      require_ ((number_ terminal "full-gcs") >= count / 10) "Missing full-GC evidence"
      require_ ((number_ terminal "retained") == (min 20 ((count + 49) / 50))) "Retention count mismatch"
      require_ ((number_ terminal "elapsed-us") >= previous) "Terminal elapsed counter went backward"
    else if line.starts-with stats-prefix:
      require_ (terminal != null and not stats-seen) "Early or duplicate process counters"
      stats := json.decode line[stats-prefix.size..].to-byte-array
      require_ (stats is List and stats.size == 11) "Invalid process counters"
      stats.do: require_ (it is int and it >= 0) "Invalid process counter value"
      require_ (stats[10] > 0) "Missing compacting-GC evidence"
      stats-seen = true
    else if not host and line.starts-with "LOCAL_COMMAND_PROVIDER COMPLETE":
      require_ (line == "LOCAL_COMMAND_PROVIDER COMPLETE" and terminal != null and stats-seen and not provider-seen) "Invalid provider completion"
      provider-seen = true
  require_ (terminal != null and stats-seen) "Missing terminal record or process counters"
  require_ (host or provider-seen) "Provider cleanup not complete"
  return terminal

fields_ text/string -> Map:
  result := {:}
  (text.split " ").do: | field/string |
    parts := field.split "="
    require_ (parts.size == 2 and not parts[0].is-empty and not parts[1].is-empty) "Invalid record field"
    require_ (not (result.contains parts[0])) "Duplicate record field"
    result[parts[0]] = parts[1]
  return result

number_ fields/Map name/string -> int:
  text := fields.get name
  require_ (text is string and not text.is-empty) "Missing numeric field"
  text.size.repeat: require_ (0x30 <= text[it] <= 0x39) "Invalid numeric field"
  return int.parse text

require_ condition/bool message/string -> none:
  if not condition: throw "SOAK_CHECK: $message"
