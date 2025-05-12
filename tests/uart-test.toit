// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import uart
import host.pipe
import host.directory
import log
import monitor
import expect show *

main:
  logger := log.default // .with_level log.INFO_LEVEL
  tmp-dir := directory.mkdtemp "/tmp/uart_test"
  try:
    with-socat tmp-dir --logger=logger: |tty0 tty1| run-test tty0 tty1
  finally:
    directory.rmdir --recursive tmp-dir

start-socat tty0/string tty1/string -> pipe.Process:
  user/string := pipe.backticks "bash" "-c" "echo \$USER"
  user = user.trim

  address1 := "pty,raw,echo=0,user-late=$user,mode=600,link=$tty0"
  address2 := "pty,raw,echo=0,user-late=$user,mode=600,link=$tty1"

  process := pipe.fork
      --use-path
      --create-stdin
      "socat"  // Program.
      ["socat", "-d", "-d", address1, address2]  // Args.

  return process

with-socat tmp-dir/string [block] --logger/log.Logger:
  tty0 := "$tmp-dir/tty0"
  tty1 := "$tmp-dir/tty1"

  socat-process := start-socat tty0 tty1
  print "started"

  socat-is-running := monitor.Latch
  stdout-bytes := #[]
  stderr-bytes := #[]
  task::
    stdout-reader := socat-process.stdout.in
    while chunk := stdout-reader.read:
      print "got stdout chunk: $chunk.to-string"
      logger.debug chunk.to-string.trim
      stdout-bytes += chunk
  task::
    stderr-reader := socat-process.stderr.in
    while chunk := stderr-reader.read:
      str := chunk.to-string.trim
      print "got stderr chunk: $chunk.to-string"
      logger.debug str
      stderr-bytes += chunk
      full-str := stderr-bytes.to-string
      if full-str.contains "starting data transfer loop":
        socat-is-running.set true

  catch:
    with-timeout --ms=1_000:
      socat-is-running.get

  try:
    block.call tty0 tty1
  finally: | is-exception _ |
    logger.info "killing socat"
    pipe.kill_ socat-process.pid 15
    socat-process.wait
    if is-exception:
      print stdout-bytes.to-string
      print stderr-bytes.to-string

run-test tty0/string tty1/string:
  port1 := uart.Port tty0 --baud-rate=9600
  port2 := uart.Port tty1 --baud-rate=9600

  expect-equals 9600 port1.baud-rate
  expect-equals 9600 port2.baud-rate

  2.repeat:
    // With socat the baud rates are only simulated, but we do exercise different code
    // paths for the '--flush'.
    write-done/monitor.Gate := monitor.Gate
    rate := ?
    if it == 0: rate = 9600
    else: rate = 115200

    port1.baud-rate = rate
    port2.baud-rate = rate
    expect-equals rate port1.baud-rate
    expect-equals rate port2.baud-rate

    reader1 := port1.in
    writer1 := port1.out

    reader2 := port2.in
    writer2 := port2.out

    str := "foobar"
    writer1.write str
    reader2.ensure-buffered str.size
    expect-equals str reader2.read-string

    bytes := ByteArray 100_000: it
    task::
      writer1.write bytes

    received := #[]
    while true:
      received += reader2.read
      if received.size == bytes.size: break
    expect-equals bytes received

    // Do it again, but this time wait for it to be transmitted.
    task::
      written := 0
      while written < bytes.size:
        written += port1.out.try-write bytes[written ..] --flush
      // Use a gate, as the port could be closed before the --wait is done otherwise
      write-done.unlock

    received = #[]
    while true:
      received += reader2.read
      if received.size == bytes.size: break
    expect-equals bytes received
    write-done.enter

  port1.close
  port2.close
