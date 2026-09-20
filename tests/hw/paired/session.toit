// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *
import uart

/** Board-to-board control. Only the tester may issue the final verdict. */
class Session:
  is-testee/bool := ?
  rx/int
  tx/int
  port/uart.Port := ?
  cases_/int := 0

  constructor --.is-testee/bool --.rx/int --.tx/int
      --completed/int=0 --baud-rate/int=115200:
    cases_ = completed
    port = uart.Port --rx=rx --tx=tx --baud-rate=baud-rate --large-buffers

  /** Reacquires the control UART after a test has temporarily closed it. */
  reopen --baud-rate/int=115200:
    port = uart.Port --rx=rx --tx=tx --baud-rate=baud-rate --large-buffers

  send value:
    data := tison.encode value
    expect data.size <= 32768
    port.out.write #[0x93, 0x7a]
    port.out.little-endian.write-uint16 data.size
    port.out.little-endian.write-uint16 (data.size ^ 0xffff)
    port.out.write data
    port.out.flush

  receive -> any:
    // Sleep transitions can leave partial characters. Check the entire header
    // before accepting a length, so stray bytes cannot request a huge read.
    while true:
      if port.in.read-byte != 0x93: continue
      if port.in.read-byte != 0x7a: continue
      size := port.in.little-endian.read-uint16
      inverse := port.in.little-endian.read-uint16
      if size > 32768 or inverse != (size ^ 0xffff): continue
      return tison.decode (port.in.read-bytes size)

  run-case name/string --ms/int=15000 --resume/bool=false [block]:
    error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      with-timeout --ms=ms:
        if is-testee:
          if not resume: expect-equals ["case", cases_, name] receive
        else:
          print "TEST $name"
          send ["case", cases_, name]
        block.call
        if is-testee:
          send ["complete", cases_]
          expect-equals ["accepted", cases_] receive
        else:
          expect-equals ["complete", cases_] receive
          send ["accepted", cases_]
          print "PASS $name"
    if error:
      print "FAIL $name: $error"
      throw error
    cases_++

  /** Returns the testee's observation to the tester for independent checking. */
  observation value -> any:
    if is-testee:
      send value
      return value
    return receive

  finish:
    with-timeout --ms=15000:
      if is-testee:
        send ["finished", cases_]
        expect-equals ["PASS", cases_] receive
        print "Tester accepted all $cases_ cases"
      else:
        expect-equals ["finished", cases_] receive
        send ["PASS", cases_]
        print "Tester verified all $cases_ cases"
    // Use the ordinary runner marker only after the tester accepts all cases.
    print "All tests done"

  close:
    // Cleanup is never evidence of success.
    port.close
