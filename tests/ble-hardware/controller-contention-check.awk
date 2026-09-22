# Copyright (C) 2026 Toit contributors.
# Run separately for each complete board capture.
BEGIN { rounds[0]=0; rounds[1]=0; workers=0; complete=0; slept=0; recovered=0; bad=0 }
/EXCEPTION|Guru Meditation|Controller disable failed|Controller deinit failed/ { bad=1 }
/^CONTROLLER_CONTENTION CYCLE / {
  split($3, id, "=")
  if (id[1] != "worker" || id[2] !~ /^[01]$/) { bad=1; next }
  worker=id[2]+0
  expected="CONTROLLER_CONTENTION CYCLE worker=" worker " round=" rounds[worker] " retained=true closed=true"
  if (force_exit && rounds[worker] == 19)
    expected="CONTROLLER_CONTENTION CYCLE worker=" worker " round=19 retained=true closed=false forced-exit=true"
  if ($0 != expected || rounds[worker] >= 20 || ended[worker] || complete) bad=1
  rounds[worker]++
}
/^CONTROLLER_CONTENTION WORKER / {
  split($3, id, "="); split($5, busy, "=")
  if (id[1] != "worker" || id[2] !~ /^[01]$/) { bad=1; next }
  worker=id[2]+0
  if (NF != 5 || $4 != "rounds=20" || rounds[worker] != 20 || ended[worker] || complete) bad=1
  if (busy[1] != "busy" || busy[2] !~ /^[0-9]+$/ || busy[2]+0 < 1) bad=1
  ended[worker]=1
  workers++
}
/^CONTROLLER_CONTENTION COMPLETE/ {
  if ($0 != "CONTROLLER_CONTENTION COMPLETE workers=2 rounds=20" || workers != 2) bad=1
  if (recovered != (force_exit ? 1 : 0)) bad=1
  complete++
}
/^CONTROLLER_CONTENTION RECOVERED/ {
  if (!force_exit || $0 != "CONTROLLER_CONTENTION RECOVERED child-exit=true" || workers != 2 || complete) bad=1
  recovered++
}
/entering deep sleep without wakeup time/ { slept++ }
END {
  if (bad || rounds[0] != 20 || rounds[1] != 20 || workers != 2 || complete != 1 || slept != 1) exit 1
  print "CONTROLLER_CONTENTION VERIFIED lifetimes=40 workers=2"
}
