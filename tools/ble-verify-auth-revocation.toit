// Copyright (C) 2026 Toit contributors.
// This library is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License, version 2.1 only.
// See LICENSE in the repository root.

import host.file

// Checks fixture assertions only; firmware provenance and capture termination
// must be verified separately. A campaign pass does not close reliability gates.
main arguments/List:
  if arguments.size != 1: throw "Usage: ble-verify-auth-revocation.toit CAMPAIGN-DIRECTORY"
  directory/string := arguments[0]
  central := read-log "$directory/central.log"
  require-once central "REVOKE_PAIR COMPLETE authenticated-candidates=2"
  require-once central "REVOKE_TWO CLIENT first-reads=101 survivor-reads=202 retained=true reconnect-denied=true"
  require-once central "REVOKE_TWO COMPLETE child-exit=0 controller-opens=1 sessions=3 disconnections=3 encryptions=2 storage-reopened=true private=false authenticated=true"
  2.repeat: | peer/int |
    lines := read-log "$directory/peer$(peer).log"
    number := comparison central "REVOKE_PAIR NUMERIC peer=$peer value="
    if number != (comparison lines "REVOKE_AUTH NUMERIC peer=$peer value="):
      throw "NUMERIC_COMPARISON_MISMATCH peer=$peer"
    2.repeat: | phase/int |
      require-once lines "REVOKE_AUTH ENCRYPTED peer=$peer phase=$phase authenticated=true"
    require-once lines "REVOKE_AUTH COMPLETE peer=$peer"
    if peer == 0:
      require-once lines "REVOKE_AUTH DENIED peer=0 error=HCI_LINK_DISCONNECTED encrypted=false"
    print "NUMERIC_MATCH peer=$peer value=$number"
  print "AUTH_REVOCATION_ASSERTIONS_PASS"

read-log path/string -> List:
  bytes := file.read-contents path
  // ROM boot output may contain non-UTF-8 bytes. Fixture markers are ASCII.
  text := (ByteArray bytes.size: bytes[it] < 128 ? bytes[it] : '?').to-string
  lines := text.split "\n"
  lines = lines.map: it.trim
  lines.do: | line/string |
    if line.starts-with "EXCEPTION" or line == "DEADLINE_EXCEEDED":
      throw "FIXTURE_EXCEPTION $path"
  require-once lines "[toit] INFO: entering deep sleep without wakeup time"
  return lines

require-once lines/List expected/string -> none:
  count := 0
  lines.do: if it == expected: count++
  if count != 1: throw "EXPECTED_ONE_RECORD count=$count record=$expected"

comparison lines/List prefix/string -> int:
  number/int? := null
  lines.do: | line/string |
    if not (line.starts-with prefix): continue.do
    if number != null: throw "DUPLICATE_NUMERIC_COMPARISON"
    suffix := line[prefix.size..]
    fields := suffix.split " "
    if fields.size != 2 or fields[1] != "fixture-approval=true": throw "INVALID_NUMERIC_RECORD"
    number = int.parse fields[0]
    if not 0 <= number < 1_000_000: throw "INVALID_NUMERIC_VALUE"
  if number == null: throw "MISSING_NUMERIC_COMPARISON $prefix"
  return number
