# Copyright (C) 2026 Toit contributors.
BEGIN {
  split("write command execute cccd cccd-execute", modes, " ")
  mode=1; rounds=0; failures=0; successes=0; started=0; complete=0; slept=0; bad=0
}
/EXCEPTION|ASSERTION_FAILED|Guru Meditation/ { bad=1 }
/^DEVICE_WRITE_PRESSURE START/ {
  if ($0 != "DEVICE_WRITE_PRESSURE START heap=65536" || started) bad=1
  started++
}
/^WRITE_PRESSURE ROUND / {
  if (!started || complete || mode > 5 || NF != 5 || $3 != "mode=" modes[mode] || $4 != "trial=" rounds) bad=1
  if ($5 == "error=OUT_OF_MEMORY" || $5 == "error=ALLOCATION_FAILED") failures++
  else if ($5 == "error=null") successes++
  else bad=1
  rounds++
}
/^WRITE_PRESSURE COMPLETE / {
  if (mode > 5 || rounds != 64 || failures == 0 || successes == 0 || complete) bad=1
  if ($0 != "WRITE_PRESSURE COMPLETE mode=" modes[mode] " failures=" failures " successes=" successes) bad=1
  mode++; rounds=0; failures=0; successes=0
}
/^DEVICE_WRITE_PRESSURE COMPLETE/ {
  if ($0 != "DEVICE_WRITE_PRESSURE COMPLETE rounds=320" || mode != 6) bad=1
  complete++
}
/entering deep sleep without wakeup time/ { if (complete != 1) bad=1; slept++ }
END {
  if (bad || started != 1 || complete != 1 || slept != 1 || mode != 6) exit 1
  print "DEVICE_WRITE_PRESSURE VERIFIED modes=5 rounds=320"
}
