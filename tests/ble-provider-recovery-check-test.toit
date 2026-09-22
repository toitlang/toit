// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .ble-hardware.provider-recovery-check as checker

main:
  ["exit", "pending", "oom"].do: | mode/string |
    data := logs mode
    expect (checker.check data[0] data[1] data[2] --mode=mode)["logs_pass"]
    expect (checker.check (data[0].replace "\n" "\r\n") data[1] data[2] --mode=mode)["logs_pass"]
    variants := [
      data[0].replace "replacement-reads=20" "replacement-reads=19",
      data[0].replace "pid=3" "pid=2",
      data[0].replace "stale-value=invalid" "stale-value=valid",
      data[0] + "EXCEPTION failure\n",
      data[0].replace "[toit] INFO: entering deep sleep without wakeup time\n" "",
      data[0] + "unexpected trailing output\n",
      data[0] + "[toit] INFO: entering deep sleep without wakeup time\n",
      data[0].replace "NUMERIC value=123" "NUMERIC value=9999999",
      data[0].replace "NUMERIC value=123" "NUMERIC value=-1",
    ]
    variants.do: | central/string |
      expect-throw "PROVIDER_RECOVERY_CHECK_FAILED": checker.check central data[1] data[2] --mode=mode
    expect-throw "PROVIDER_RECOVERY_CHECK_FAILED":
      checker.check data[0] (data[1].replace "value=123" "value=124") data[2] --mode=mode
    if mode != "exit":
      expect-throw "PROVIDER_RECOVERY_CHECK_FAILED":
        checker.check (data[0].replace "reads=2 peer-markers=true" "reads=1 peer-markers=true") data[1] data[2] --mode=mode
      expect-throw "PROVIDER_RECOVERY_CHECK_FAILED":
        checker.check (data[0].replace "error=NO_SUCH_PROCESS" "error=DEADLINE_EXCEEDED") data[1] data[2] --mode=mode
    if mode == "oom":
      [
        data[0].replace "Heap report @ out of memory test\n" "",
        data[0].replace "DEAD_CONTAINER exit=1" "DEAD_CONTAINER exit=0",
        data[0].replace "replacement=4" "replacement=3",
        "Heap report @ out of memory test\n" + data[0],
      ].do: | central/string |
        expect-throw "PROVIDER_RECOVERY_CHECK_FAILED": checker.check central data[1] data[2] --mode=mode

logs mode/string -> List:
  pending := mode != "exit"
  central := [
    "[toit] INFO: using SPIRAM for heap metadata and heap",
    "PROVIDER_RECOVERY PROVIDER pid=2",
    "SERVICE_MULTIPEER NUMERIC value=123 fixture-approval=true",
    "SERVICE_MULTIPEER NUMERIC value=456 fixture-approval=true",
    "PROVIDER_RECOVERY BEFORE links=2 encrypted=true",
  ]
  if pending: central.add "PROVIDER_RECOVERY PENDING reads=2 peer-markers=true"
  if mode == "oom":
    central.add "PROVIDER_RECOVERY OOM_ARMED heap-limit=262144"
    central.add "Heap report @ out of memory test"
  if pending: central.add "PROVIDER_RECOVERY READS_FAILED count=2 error=NO_SUCH_PROCESS"
  central.add "PROVIDER_RECOVERY DEAD stale-connections=2"
  if mode == "oom":
    central.add "PROVIDER_RECOVERY DEAD_CONTAINER exit=1"
    central.add "PROVIDER_RECOVERY GROUPS first=3 replacement=4"
  central.add "PROVIDER_RECOVERY PROVIDER pid=3"
  central.add "SERVICE_MULTIPEER NUMERIC value=789 fixture-approval=true"
  central.add "PROVIDER_RECOVERY COMPLETE replacement-reads=20 stale-value=invalid retained=2"
  central.add "[toit] INFO: entering deep sleep without wakeup time\n"
  peers := []
  [[123, 789], [456]].do: | numbers/List |
    lines := []
    numbers.size.repeat: | index/int |
      lines.add "VHCI_PAIRING NUMERIC value=$(numbers[index]) fixture-approval=true"
      lines.add "VHCI_PAIRING ENCRYPTED encrypted=true authenticated=true"
      if pending and index == 0: lines.add "VHCI_PAIRING READ_PENDING value=$(numbers.size == 2 ? 42 : 82)"
      lines.add "VHCI_PAIRING COMPLETE disconnected=true"
      if numbers.size == 2: lines.add "RECOVERY_PEER CYCLE cycle=$index"
    lines.add "RECOVERY_PEER COMPLETE cycles=$(numbers.size)"
    lines.add "[toit] INFO: entering deep sleep without wakeup time\n"
    peers.add (lines.join "\n")
  return [central.join "\n", peers[0], peers[1]]
