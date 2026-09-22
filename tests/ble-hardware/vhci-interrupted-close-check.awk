# Copyright (C) 2026 Toit contributors.
BEGIN { rounds=0; complete=0; slept=0; bad=0 }
/EXCEPTION|ASSERTION_FAILED|Guru Meditation|Controller disable failed|Controller deinit failed/ { bad=1 }
/^INTERRUPTED_CLOSE ROUND/ {
  if ($0 != "INTERRUPTED_CLOSE ROUND round=" rounds " reopened=true" || complete) bad=1
  rounds++
}
/^INTERRUPTED_CLOSE COMPLETE/ {
  if ($0 != "INTERRUPTED_CLOSE COMPLETE rounds=20 deadlines=10 cancellations=10" || rounds != 20) bad=1
  complete++
}
/entering deep sleep without wakeup time/ {
  if (complete != 1) bad=1
  slept++
}
END {
  if (bad || rounds != 20 || complete != 1 || slept != 1) exit 1
  print "INTERRUPTED_CLOSE VERIFIED rounds=20"
}
