// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import host.pipe
import io
import monitor
import system

with-tmp-dir [block]:
  tmp-dir := directory.mkdtemp "/tmp/test-"
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir

class ForkResult:
  stdout/string
  stderr/string
  exit-signal/int?
  exit-code/int

  constructor
      --.stdout
      --.stderr
      --.exit-signal
      --.exit-code:

class ToitExecutable:
  toit-exe_/string

  constructor args/List:
    toit-exe_ = args[0]

  backticks args/List:
    full-command := [toit-exe_] + args
    result := pipe.backticks full-command
    if system.platform == system.PLATFORM-WINDOWS:
      return result.replace --all "\r\n" "\n"
    return result

  run args/List -> int:
    full-command := [toit-exe_] + args
    return pipe.run-program full-command

  fork args/List -> ForkResult:
    full-command := [toit-exe_] + args
    process := pipe.fork
        --use-path
        --create-stdout
        --create-stderr
        full-command.first
        full-command

    stdout-string-latch := monitor.Latch
    stdout-task := task --background::
      try:
        bytes := process.stdout.in.read-all
        stdout-string-latch.set bytes.to-string-non-throwing
      finally:
        process.stdout.close

    stderr-string-latch := monitor.Latch
    stderr-task := task --background::
      try:
        bytes := process.stderr.in.read-all
        stderr-string-latch.set bytes.to-string-non-throwing
      finally:
        process.stderr.close

    exit-value := process.wait
    exit-signal := pipe.exit-signal exit-value
    exit-code := pipe.exit-code exit-value

    return ForkResult
        --stdout=stdout-string-latch.get
        --stderr=stderr-string-latch.get
        --exit-signal=exit-signal
        --exit-code=exit-code
