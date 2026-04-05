// Tests deep sleep on EC618.
// The device should print the message, sleep 5 seconds, then reboot.

import ec618

main:
  print "Going to deep sleep for 5 seconds..."
  ec618.deep-sleep (Duration --s=5)
  // Should not reach here.
  print "ERROR: deep-sleep returned!"
