// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.hex
import encoding.json
import host.file
import io

// Offline evidence only: the caller supplies the actual host process exit code.
// Adapter restoration must be verified separately before declaring a radio pass.
main args/List:
  require_ (3 <= args.size <= 5) "Usage: ble-reconnect-check HOST_LOG BOARD_LOG HOST_EXIT_CODE [CYCLES [WARMUP]]"
  result := check (file.read-contents args[0]).to-string (file.read-contents args[1]).to-string
      --host-exit-code=(int.parse args[2])
      --cycles=(args.size > 3 ? (int.parse args[3]) : 1000)
      --warmup=(args.size > 4 ? (int.parse args[4]) : 3)
  print (json.encode result).to-string

/** Validates complete numbered reconnect logs without accessing hardware. */
check host/string board/string --host-exit-code/int --cycles/int=1000 --warmup/int=3 -> Map:
  require_ (1 <= cycles <= 10000 and 1 <= warmup <= 100) "Invalid cycle counts"
  require_ (host-exit-code == 0) "Host did not exit successfully"
  h := Records_ host --host
  host-min/int? := null
  host-max := 0
  descriptors/int? := null
  cycles.repeat: | index/int |
    row := h.take "RECONNECT " ["cycle", "descriptors", "live"]
    require_ (row[0] == index + 1) "Host cycle sequence mismatch"
    if descriptors == null: descriptors = row[1]
    require_ (row[1] == descriptors) "Descriptor count changed"
    host-min = host-min == null ? row[2] : (min host-min row[2])
    host-max = max host-max row[2]
  end := h.take "RECONNECT_COMPLETE " ["cycles", "warmup", "echoes", "baseline", "minimum", "maximum", "descriptors"]
  h.finish
  total := cycles + warmup
  require_ (end[0] == cycles and end[1] == warmup and end[2] == total * 10) "Host terminal counts mismatch"
  baseline/int := end[3]
  require_ (baseline > 0 and descriptors > 0 and end[6] == descriptors) "Invalid host baseline"
  host-min = min host-min baseline
  host-max = max host-max baseline
  require_ (end[4] == host-min and end[5] == host-max) "Host memory summary mismatch"
  require_ (host-max <= baseline + 4096) "Host memory allowance exceeded"
  peer := check-peripheral board --cycles=cycles --warmup=warmup
  peer["host_baseline"] = baseline
  peer["host_maximum"] = host-max
  peer["adapter_restoration_verified"] = false
  return peer

/** Validates the peripheral's numbered exchanges and memory summaries. */
check-peripheral board/string --cycles/int --warmup/int -> Map:
  require_ (1 <= cycles <= 10000 and 1 <= warmup <= 100) "Invalid cycle counts"
  b := Records_ board --no-host
  total := cycles + warmup
  board-baseline := 0
  board-max := 0
  minimum-free/int? := null
  minimum-largest/int? := null
  previous-gcs := 0
  total.repeat: | cycle/int |
    10.repeat: | index/int |
      row := b.take "GATT_SERVER ECHO " ["count", "data"]
      sequence := ByteArray 4
      io.LITTLE-ENDIAN.put-uint32 sequence 0 (cycle * 10 + index)
      expected := (hex.encode sequence) + "546f6974484349"
      require_ (row[0] == index + 1 and row[1] == expected) "Board payload sequence mismatch"
    handlers := b.take "GATT_SERVER HANDLERS " ["reads", "validated", "heartbeats", "hci-during-read"]
    require_ (handlers[0] >= 2 and handlers[1] == 10 and handlers[2] > 0 and handlers[3] > 0) "Board handler progress mismatch"
    complete := b.take "GATT_SERVER COMPLETE " ["count", "full-gcs", "retained"]
    require_ (complete[0] == 10 and complete[1] >= 1 and complete[2] == 1) "Board exchange/GC completion mismatch"
    sample := b.take "VHCI_RECONNECT " ["cycle", "allocated", "free", "largest", "compacting-gcs"]
    require_ (sample[0] == cycle) "Board cycle sequence mismatch"
    require_ (sample[4] >= previous-gcs) "Board GC counter went backward"
    previous-gcs = sample[4]
    if cycle == warmup - 1: board-baseline = sample[1]
    if cycle >= warmup:
      board-max = max board-max sample[1]
      minimum-free = minimum-free == null ? sample[2] : (min minimum-free sample[2])
      minimum-largest = minimum-largest == null ? sample[3] : (min minimum-largest sample[3])
  board-end := b.take "VHCI_RECONNECT COMPLETE " ["cycles", "warmup", "baseline", "maximum"]
  b.finish
  require_ (board-end[0] == cycles and board-end[1] == warmup) "Board terminal counts mismatch"
  require_ (board-baseline > 0 and board-end[2] == board-baseline) "Board baseline mismatch"
  require_ (board-end[3] == board-max) "Board maximum mismatch"
  require_ (board-max <= board-baseline + 4096) "Board memory allowance exceeded"
  return {
    "logs_pass": true,
    "cycles": cycles,
    "warmup": warmup,
    "echoes": total * 10,
    "board_baseline": board-baseline,
    "board_maximum": board-max,
    "board_minimum_free": minimum-free,
    "board_minimum_largest_free": minimum-largest,
  }

/** Validates two board logs; logger exit codes are not firmware exit codes. */
check-boards central/string peripheral/string --cycles/int=1000 --warmup/int=3 -> Map:
  result := check-peripheral peripheral --cycles=cycles --warmup=warmup
  records := Records_ central --host --central
  minimum/int? := null
  maximum := 0
  minimum-free/int? := null
  minimum-largest/int? := null
  previous-gcs := 0
  cycles.repeat: | index/int |
    row := records.take "VHCI_RECONNECT_CENTRAL " ["cycle", "live", "free", "largest", "compacting-gcs"]
    require_ (row[0] == index + 1) "Central cycle sequence mismatch"
    require_ (row[1] > 0 and row[2] > 0 and 0 < row[3] <= row[2]) "Invalid central memory sample"
    require_ (row[4] >= previous-gcs) "Central GC counter went backward"
    previous-gcs = row[4]
    minimum = minimum == null ? row[1] : (min minimum row[1])
    maximum = max maximum row[1]
    minimum-free = minimum-free == null ? row[2] : (min minimum-free row[2])
    minimum-largest = minimum-largest == null ? row[3] : (min minimum-largest row[3])
  end := records.take "VHCI_RECONNECT_CENTRAL COMPLETE " ["cycles", "warmup", "echoes", "baseline", "minimum", "maximum"]
  records.finish
  require_ (end[0] == cycles and end[1] == warmup and end[2] == (cycles + warmup) * 10) "Central terminal counts mismatch"
  require_ (end[3] > 0) "Invalid central baseline"
  minimum = min minimum end[3]
  maximum = max maximum end[3]
  require_ (end[4] == minimum and end[5] == maximum) "Central memory summary mismatch"
  require_ (maximum <= end[3] + 4096) "Central memory allowance exceeded"
  [central, peripheral].do: | log/string |
    normalized := log.replace "\r\n" "\n"
    normalized = normalized.trim
    footer := "\n\nInterrupt received, shutting down gracefully...\nError: context canceled"
    if normalized.ends-with footer: normalized = normalized[..normalized.size - footer.size]
    lines := normalized.split "\n"
    endings := lines.filter: it == "[toit] INFO: entering deep sleep without wakeup time"
    require_ (endings.size == 1) "Missing or duplicate normal sleep"
    require_ (normalized.ends-with "[toit] INFO: entering deep sleep without wakeup time") "Output after normal sleep"
  result["central_baseline"] = end[3]
  result["central_maximum"] = maximum
  result["central_minimum_free"] = minimum-free
  result["central_minimum_largest_free"] = minimum-largest
  return result

class Records_:
  lines_/List := []
  index_/int := 0

  constructor text/string --host/bool --central/bool=false:
    ["EXCEPTION", "Guru Meditation", "Backtrace:"].do: | marker/string |
      require_ (not (text.contains marker)) "Runtime failure in logs"
    (text.split "\n").do: | line/string |
      if line.ends-with "\r": line = line[..line.size - 1]
      selected := central ? (line.starts-with "VHCI_RECONNECT") : host
          ? (line.starts-with "RECONNECT")
          : (line.starts-with "VHCI_RECONNECT" or line.starts-with "GATT_SERVER ECHO" or
              line.starts-with "GATT_SERVER HANDLERS" or line.starts-with "GATT_SERVER COMPLETE")
      if selected: lines_.add line

  take prefix/string keys/List -> List:
    require_ (index_ < lines_.size) "Missing completion or data record"
    line/string := lines_[index_++]
    require_ (line.starts-with prefix) "Record order mismatch"
    fields := (line[prefix.size..]).split " "
    require_ (fields.size == keys.size) "Record field count mismatch"
    return List keys.size: | index/int |
      name := "$(keys[index])="
      field/string := fields[index]
      require_ (field.starts-with name) "Record field mismatch"
      value := field[name.size..]
      if keys[index] == "data": continue.List value
      require_ (not value.is-empty) "Empty numeric field"
      value.size.repeat: require_ (0x30 <= value[it] <= 0x39) "Invalid numeric field"
      int.parse value

  finish -> none:
    require_ (index_ == lines_.size) "Unexpected or duplicate record"

require_ condition/bool message/string -> none:
  if not condition: throw "RECONNECT_CHECK: $message"
