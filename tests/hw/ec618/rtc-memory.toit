// Tests RTC memory persistence across deep sleep on EC618.
// On first boot, writes a value. On subsequent boots, verifies it.
// Use with: toit tool firmware container install --trigger=boot rtc rtc-memory.snapshot
// Then cause a reboot via deep-sleep.

import ec618
import system.storage

KEY ::= "rtc-counter"

main:
  bucket := storage.Bucket.open --ram "test/rtc"
  try:
    counter := (bucket.get KEY) or #[0]
    value := counter[0]
    print "RTC counter = $value"

    // Increment and store.
    bucket[KEY] = #[(value + 1) & 0xff]
    print "Storing $((value + 1) & 0xff), sleeping 3s..."

    // Deep sleep for 3 seconds, then reboot.
    ec618.deep-sleep (Duration --s=3)
  finally:
    bucket.close
