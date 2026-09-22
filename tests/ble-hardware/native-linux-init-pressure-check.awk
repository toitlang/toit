# Copyright (C) 2026 Toit contributors.
BEGIN { rounds=0; failures=0; opened=0; complete=0; bad=0 }
/EXCEPTION|HCI_TRANSPORT_ERROR/ { bad=1 }
/^LINUX_INIT_PRESSURE ROUND / {
  split($3, trial, "="); split($4, error, "="); split($5, descriptors, "=")
  if (NF != 5 || $3 != "trial=" rounds || error[1] != "error" || complete) bad=1
  if (descriptors[1] != "descriptors" || descriptors[2] !~ /^[0-9]+$/ || descriptors[2]+0 < 1) bad=1
  if (rounds == 0) baseline=descriptors[2]
  if (descriptors[2] != baseline) bad=1
  if (error[2] == "OUT_OF_MEMORY" || error[2] == "ALLOCATION_FAILED") failures++
  else if (error[2] == "null") opened++
  else bad=1
  rounds++
}
/^LINUX_INIT_PRESSURE COMPLETE/ {
  if ($0 != "LINUX_INIT_PRESSURE COMPLETE failures=" failures " opened=" opened " descriptors=" baseline || rounds != 16) bad=1
  complete++
}
END {
  if (bad || rounds != 16 || complete != 1 || failures == 0 || opened == 0) exit 1
  print "LINUX_INIT_PRESSURE VERIFIED rounds=16 failures=" failures " opened=" opened " descriptors=" baseline
}
