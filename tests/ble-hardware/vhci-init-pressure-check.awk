# Copyright (C) 2026 Toit contributors.
BEGIN { attempts=0; recovered=0; complete=0; slept=0; bad=0; oom=0; opened=0 }
/EXCEPTION|Guru Meditation|Controller disable failed|Controller deinit failed/ { bad=1 }
/^INIT_PRESSURE ATTEMPT / {
  split($3, trial, "="); split($4, filled, "="); split($5, error, "=")
  if (NF != 5 || trial[1] != "trial" || trial[2]+0 != attempts || recovered != attempts || complete) bad=1
  if (filled[1] != "filled" || filled[2]+0 < 17 || filled[2]+0 > 2048 || error[1] != "error") bad=1
  if (error[2] == "OUT_OF_MEMORY" || error[2] == "ALLOCATION_FAILED") oom++
  else if (error[2] == "null") opened++
  else if (error[2] != "MALLOC_FAILED") bad=1
  attempts++
}
/^INIT_PRESSURE RECOVERED / {
  if ($0 != "INIT_PRESSURE RECOVERED trial=" recovered || attempts != recovered+1 || complete) bad=1
  recovered++
}
/^INIT_PRESSURE COMPLETE/ {
  if ($0 != "INIT_PRESSURE COMPLETE trials=16" || recovered != 16) bad=1
  complete++
}
/entering deep sleep without wakeup time/ { if (complete != 1) bad=1; slept++ }
END {
  if (bad || attempts != 16 || recovered != 16 || complete != 1 || slept != 1 || oom == 0 || opened == 0) exit 1
  print "INIT_PRESSURE VERIFIED recoveries=16 oom=" oom " opened=" opened
}
