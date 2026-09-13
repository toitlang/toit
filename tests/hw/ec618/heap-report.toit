// Tests heap reporting on EC618.

import system

main:
  print "--- heap report start ---"
  system.serial-print-heap-report "test-marker"
  print "--- heap report end ---"
  print "HEAP REPORT TEST DONE"
