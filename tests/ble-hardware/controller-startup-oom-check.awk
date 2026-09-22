# Copyright (C) 2026 Toit contributors.
BEGIN { started=0; owned=0; dead=0; recovered=0; complete=0; slept=0; oom=0; stack_oom=0; bad=0 }
/Guru Meditation|Controller disable failed|Controller deinit failed|EXPECTED_STARTUP_OOM|PRESSURE_NOT_REACHED|EXPECTED_CHILD_FAILURE|REOPEN_DIRTY|UNEXPECTED_CONTROLLER_CLOSE|DEADLINE_EXCEEDED/ { bad=1 }
/^STARTUP_OOM START / {
  if ($0 != "STARTUP_OOM START cycles=12" || started) bad=1
  started++
}
/^STARTUP_OOM OWNED / {
  if (!started || complete || owned != recovered || dead != recovered ||
      $0 != "STARTUP_OOM OWNED cycle=" recovered " heap=65536") bad=1
  owned++
  oom=0
  stack_oom=0
}
/[Oo]ut of memory/ { if (owned == recovered+1 && dead == recovered) oom++ }
/out of memory in .*stack grow/ { if (owned == recovered+1 && dead == recovered) stack_oom++ }
/^STARTUP_OOM DEAD / {
  if (complete || owned != recovered+1 || dead != recovered || !oom || !stack_oom ||
      $0 != "STARTUP_OOM DEAD cycle=" recovered " exit=1") bad=1
  dead++
}
/^STARTUP_OOM RECOVERED / {
  split($3, cycle, "="); split($4, free, "="); split($5, largest, "=")
  if (NF != 5 || complete || dead != recovered+1 || owned != dead ||
      cycle[1] != "cycle" || cycle[2]+0 != recovered || free[1] != "free" ||
      largest[1] != "largest" || free[2]+0 <= 0 || largest[2]+0 <= 0 ||
      largest[2]+0 > free[2]+0) bad=1
  recovered++
}
/^STARTUP_OOM COMPLETE/ {
  if ($0 != "STARTUP_OOM COMPLETE cycles=12" || recovered != 12) bad=1
  complete++
}
/entering deep sleep without wakeup time/ { if (complete != 1) bad=1; slept++ }
END {
  if (bad || started != 1 || owned != 12 || dead != 12 || recovered != 12 || complete != 1 || slept != 1) exit 1
  print "STARTUP_OOM VERIFIED deaths=12 recoveries=12"
}
