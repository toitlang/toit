// Copyright (C) 2026 Toit contributors.

// The containers that OTA tests install in flash (with FLAG-RUN-BOOT)
// before the firmware update: u-ticker (untrusted, format 2 with its
// certificate) and t-ticker (trusted; compiled in format 1 or 2). Each
// prints a few ticks with its name, so the console shows whether it runs
// on the firmware it finds itself on after the update.

tick name/string -> none:
  3.repeat: | i |
    print "TICKER $name tick $i"
    sleep --ms=300
  print "TICKER $name done"
