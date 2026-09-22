# Copyright (C) 2026 Toit contributors.
BEGIN { started=0; collections=0; collection_done=0; cold=0; resource_rounds=0; resource_done=0; central_rounds=0; central_failures=0; central_workers=0; central_done=0; active=0; complete=0; slept=0; bad=0 }
/EXCEPTION|ASSERTION_FAILED|Guru Meditation|DEADLINE_EXCEEDED/ { bad=1 }
/^DEVICE_SERVICE_CLEANUP_PRESSURE START/ {
  if (($0 != "DEVICE_SERVICE_CLEANUP_PRESSURE START heap=65536 slots=4096 word-bytes=4" &&
       $0 != "DEVICE_SERVICE_CLEANUP_PRESSURE START heap=65536 slots=2048 word-bytes=8") || started) bad=1
  if (hardware && $5 != "word-bytes=4") bad=1
  started++
}
/^COLLECTION_SHRINK_PRESSURE / {
  expected=(collections == 0 ? "false" : "true")
  split($3, failures, "="); split($4, successes, "=")
  if (!started || collection_done || collections > 1 || NF != 5 || $2 != "map=" expected || $5 != "intact=true") bad=1
  if (failures[2] <= 0 || successes[2] <= 0 || failures[2] + successes[2] != 48) bad=1
  collections++
}
/^DEVICE_SERVICE_CLEANUP_PRESSURE COLLECTIONS_COMPLETE/ {
  if ($0 != "DEVICE_SERVICE_CLEANUP_PRESSURE COLLECTIONS_COMPLETE cases=96" || collections != 2 || collection_done) bad=1
  collection_done++
}
/^RESOURCE_CLOSE_PRESSURE / {
  if (!collection_done || cold || resource_done) bad=1
  if ($0 != "RESOURCE_CLOSE_PRESSURE error=OUT_OF_MEMORY closed=false callbacks=0 registered=1" &&
      $0 != "RESOURCE_CLOSE_PRESSURE error=ALLOCATION_FAILED closed=false callbacks=0 registered=1" &&
      $0 != "RESOURCE_CLOSE_PRESSURE error=null closed=true callbacks=1 registered=0") bad=1
  cold++
}
/^RESOURCE_CLOSE_SHRINK / {
  expected=(resource_rounds < 48 ? "false" : "true")
  if (!cold || resource_done || resource_rounds >= 96 || NF != 6 || $2 != "separate-clients=" expected || $3 != "slack=" (resource_rounds % 48)) bad=1
  if (($4 != "retried=true" && $4 != "retried=false") || $5 != "callbacks=1" || $6 != "remaining=0") bad=1
  resource_rounds++
}
/^DEVICE_SERVICE_CLEANUP_PRESSURE RESOURCES_COMPLETE/ {
  if ($0 != "DEVICE_SERVICE_CLEANUP_PRESSURE RESOURCES_COMPLETE cases=97" || resource_rounds != 96 || resource_done) bad=1
  resource_done++
}
/^CENTRAL_START_PRESSURE slack=/ {
  if (!resource_done || central_done || central_rounds >= 96 || NF != 6 || $2 != "slack=" central_rounds) bad=1
  if ($3 == "failed=true") central_failures++
  else if ($3 == "failed=false") central_workers++
  else bad=1
  if (($4 != "retried=0" && $4 != "retried=1") || $5 != "resources=0" || $6 != "released=true") bad=1
  central_rounds++
}
/^CENTRAL_START_PRESSURE COMPLETE/ {
  if ($0 != "CENTRAL_START_PRESSURE COMPLETE failures=" central_failures " workers=" central_workers || central_rounds != 96 || central_failures == 0 || central_workers == 0 || central_done) bad=1
  central_done++
}
/^CENTRAL_START_PRESSURE ACTIVE/ {
  if ($0 != "CENTRAL_START_PRESSURE ACTIVE survivor=true replacement=true opens=1 closes=1" || !central_done || active) bad=1
  active++
}
/^DEVICE_SERVICE_CLEANUP_PRESSURE COMPLETE/ {
  if ($0 != "DEVICE_SERVICE_CLEANUP_PRESSURE COMPLETE cases=290 survivor=true replacement=true" || !active || complete) bad=1
  complete++
}
/entering deep sleep without wakeup time/ { if (complete != 1) bad=1; slept++ }
END {
  if (bad || started != 1 || complete != 1 || (hardware && slept != 1)) exit 1
  print "DEVICE_SERVICE_CLEANUP_PRESSURE VERIFIED cases=290"
}
