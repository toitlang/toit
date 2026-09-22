# Validates complete device output; the observer exit status is checked separately.
BEGIN { rounds = 0; failures = 0 }
function fail(message) {
  print "FAIL: " message > "/dev/stderr"
  invalid = 1
  exit 1
}
/EXCEPTION|ASSERTION_FAILED|PRESSURE_NOT_REACHED/ { fail("fixture failure") }
/^DEVICE_RX_CLOSE_PRESSURE START/ {
  if (started || $0 != "DEVICE_RX_CLOSE_PRESSURE START heap=65536 handles=16 packets=32 ballast=64")
    fail("unexpected start")
  started = 1
}
/^RX_CLOSE_PRESSURE ROUND/ {
  if (!started || summary || $3 != "trial=" rounds) fail("round sequence")
  if ($4 == "error=ALLOCATION_FAILED" || $4 == "error=OUT_OF_MEMORY") failures++
  else if ($4 != "error=null") fail("unexpected close error")
  rounds++
}
/^RX_CLOSE_PRESSURE COMPLETE/ {
  if (summary || rounds != 64 || $3 != "rounds=64" || $4 != "failures=" (failures + 0))
    fail("summary mismatch")
  summary = 1
}
/^DEVICE_RX_CLOSE_PRESSURE COMPLETE/ {
  if (!summary || complete) fail("unexpected completion")
  complete = 1
}
/entering deep sleep without wakeup time/ {
  if (!complete) fail("sleep before completion")
  slept = 1
}
END {
  if (invalid) exit 1
  if (!complete || !slept) fail("incomplete run")
  print "PASS: 64 cleanup rounds; caught close allocation failures=" (failures + 0)
}
