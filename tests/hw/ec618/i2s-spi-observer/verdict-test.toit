// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
import expect show *
import host.directory
import host.file
import host.pipe

compiler_/string := ""
fixture_/string := ""

PASS ::= "I2S DUPLEX PASS master=true rate=96000 bits=24 format=0 slots=0 capture_s=10 errors=0\n"
STREAM ::= "SPI console: STREAM stall_ms=0 target=1153944 bytes=1153944 blocks=282 error=0 errors=0 counters=1 phase=0 checked=9231552 duration_us=2010000 start_before=100 start_after=110 end_before=9231650 end_after=9231660\n"
STALL ::= "SPI console: STREAM stall_ms=100 target=1153944 bytes=4092 blocks=1 error=-2 counters=0 duration_us=110000\nSPI console: WIRE windows=1 invalid=1\n"

main args:
  expect-equals 2 args.size
  compiler_ = args[0]
  fixture_ = args[1]
  root := directory.mkdtemp "/tmp/ec618-observer-verdict-"
  path := "$root/capture.log"
  try:
    good := STREAM + PASS
    file.write-contents good --path=path
    expect-equals 0 (check "stream" ["96000", "24", path, "default"])
    rejected: check "stream" ["96000", "24", path, "100"]
    [
      ["bytes=1153944", "bytes=4092"],
      ["blocks=282", "blocks=1"],
      ["error=0", "error=-2"],
      ["errors=0", "errors=1"],
      ["counters=1", "counters=0"],
      ["phase=0", "phase=0 phase=0"],
      ["phase=0", "phase=-1"],
      ["checked=9231552", "checked=9231551"],
      ["duration_us=2010000", "duration_us=100000"],
      ["end_after=9231660", "end_after=500"],
      [PASS, ""],
    ].do: |change/List|
      file.write-contents (good.replace change[0] change[1]) --path=path
      rejected: check "stream" ["96000", "24", path, "default"]
    [STREAM, "assert failed\n", "Rebooting...\n"].do: |extra/string|
      file.write-contents (good + extra) --path=path
      rejected: check "stream" ["96000", "24", path, "default"]
    good = STALL + PASS + "SPI console: DUAL-REPLY OK\n"
    file.write-contents good --path=path
    expect-equals 0 (check "stall" [path])
    rejected: check "stream" ["96000", "24", path, "default"]
    [
      ["error=-2", "error=-5"],
      ["bytes=4092", "bytes=1153944"],
      ["invalid=1", "invalid=0"],
      [PASS, ""],
      ["DUAL-REPLY OK", "Rebooting..."],
    ].do: |change/List|
      file.write-contents (good.replace change[0] change[1]) --path=path
      rejected: check "stall" [path]
    print "Observer truncation, corruption, clock evidence, duplicate, reboot and stall verdict tests PASS"
  finally:
    directory.rmdir --recursive root

rejected [action]:
  expect (action.call != 0)

check kind/string options/List -> int:
  return pipe.run-program ([compiler_, "run", "$fixture_/check-$(kind).toit", "--"] + options)
