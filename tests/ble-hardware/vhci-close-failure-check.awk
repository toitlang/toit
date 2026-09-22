# Copyright (C) 2026 Toit contributors.
# Check one complete capture; use -v disabled=1 for normal firmware.
BEGIN { step=0; slept=0; bad=0 }
/EXCEPTION|Guru Meditation|assert failed/ { bad=1 }
/Controller (disable|deinit) failed/ {
  expected=(step == 0 ? "disable" : "deinit")
  if (disabled || (step != 0 && step != 3) ||
      $0 !~ ("ToitVHCI: Controller " expected " failed: 259$")) bad=1
  step++
}
/^VHCI_CLOSE_FAILURE / {
  if (disabled) {
    if (step != 0 || $0 != "VHCI_CLOSE_FAILURE DISABLED actions=2") bad=1
  } else if (step == 1 || step == 4) {
    mode=(step == 1 ? "false" : "true")
    if ($0 != "VHCI_CLOSE_FAILURE ERROR deinit=" mode " error=HARDWARE_ERROR retained=true joined=true") bad=1
  } else if (step == 2 || step == 5) {
    mode=(step == 2 ? "false" : "true")
    if ($0 != "VHCI_CLOSE_FAILURE RECOVERED deinit=" mode " identity=true") bad=1
  } else if (step == 6) {
    if ($0 != "VHCI_CLOSE_FAILURE COMPLETE failures=2 recovered=2") bad=1
  } else bad=1
  step++
}
/entering deep sleep without wakeup time/ {
  if (step != (disabled ? 1 : 7)) bad=1
  slept++
}
END {
  if (bad || step != (disabled ? 1 : 7) || slept != 1) exit 1
  print "VHCI_CLOSE_FAILURE VERIFIED disabled=" (disabled ? "true" : "false")
}
