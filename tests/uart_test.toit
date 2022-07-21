// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import uart_linux
import host.pipe
import host.directory
import log
import monitor
import reader
import writer
import expect show *

main:
  logger := log.default // .with_level log.INFO_LEVEL
  tmp_dir := directory.mkdtemp "/tmp/uart_test"
  try:
    with_socat tmp_dir --logger=logger: |tty0 tty1| run_test tty0 tty1
  finally:
    directory.rmdir --recursive tmp_dir

start_socat tty0/string tty1/string:
  user/string := pipe.backticks "bash" "-c" "echo \$USER"
  user = user.trim

  address1 := "pty,raw,echo=0,user-late=$user,mode=600,link=$tty0"
  address2 := "pty,raw,echo=0,user-late=$user,mode=600,link=$tty1"

  fork_data := pipe.fork
      true  // use_path.
      pipe.PIPE_INHERITED  // stdin.
      pipe.PIPE_CREATED  // stdout.
      pipe.PIPE_CREATED  // stderr.
      "socat"  // Program.
      ["socat", "-d", "-d", address1, address2]  // Args.

  return fork_data

with_socat tmp_dir/string [block] --logger/log.Logger:
  tty0 := "$tmp_dir/tty0"
  tty1 := "$tmp_dir/tty1"

  fork_data := start_socat tty0 tty1
  print "started"

  socat_is_running := monitor.Latch
  stdout_bytes := #[]
  stderr_bytes := #[]
  task::
    stdout /pipe.OpenPipe := fork_data[1]
    while chunk := stdout.read:
      print "got stdout chunk: $chunk.to_string"
      logger.debug chunk.to_string.trim
      stdout_bytes += chunk
  task::
    stderr /pipe.OpenPipe := fork_data[2]
    while chunk := stderr.read:
      str := chunk.to_string.trim
      print "got stderr chunk: $chunk.to_string"
      logger.debug str
      stderr_bytes += chunk
      full_str := stderr_bytes.to_string
      if full_str.contains "starting data transfer loop":
        socat_is_running.set true

  catch:
    with_timeout --ms=1_000:
      socat_is_running.get

  try:
    block.call tty0 tty1
  finally: | is_exception _ |
    pid := fork_data[3]
    logger.info "killing socat"
    pipe.kill_ pid 15
    pipe.wait_for pid
    if is_exception:
      print stdout_bytes.to_string
      print stderr_bytes.to_string

run_test tty0/string tty1/string:
  port1 := uart_linux.Port tty0 --baud_rate=9600
  port2 := uart_linux.Port tty1 --baud_rate=9600

  expect_equals 9600 port1.baud_rate
  expect_equals 9600 port2.baud_rate

  2.repeat:
    // With socat the baud rates are only simulated, but we do exercise different code
    // paths for the '--wait'.
    rate := ?
    if it == 0: rate = 9600
    else: rate = 115200

    port1.baud_rate = rate
    port2.baud_rate = rate
    expect_equals rate port1.baud_rate
    expect_equals rate port2.baud_rate

    reader1 := reader.BufferedReader port1
    writer1 := writer.Writer port1

    reader2 := reader.BufferedReader port2
    writer2 := writer.Writer port2

    str := "foobar"
    writer1.write str
    reader2.ensure str.size
    expect_equals str reader2.read_string

    bytes := ByteArray 100_000: it
    task::
      writer1.write bytes

    received := #[]
    while true:
      received += reader2.read
      if received.size == bytes.size: break
    expect_equals bytes received

    // Do it again, but this time wait for it to be transmitted.
    task::
      written := 0
      while written < bytes.size:
        written += port1.write bytes[written ..] --wait

    received = #[]
    while true:
      received += reader2.read
      if received.size == bytes.size: break
    expect_equals bytes received

  port1.close
  port2.close
