// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import host.pipe
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
  toit-run_/string
  toit-bin-src_/string
  sdk-dir_/string

  constructor args/List:
    toit-run_ = args[0]
    toit-bin-src_ = args[1]
    sdk-dir_ = args[2]

  backticks --with-test-sdk/bool=true args/List:
    full-command := [toit_run_, toit-bin-src_]
    if with-test-sdk:
      full-command += ["--sdk-dir", sdk-dir_]
    full-command += args
    result := pipe.backticks full-command
    if system.platform == system.PLATFORM-WINDOWS:
      return result.replace --all "\r\n" "\n"
    return result

  run --with-test-sdk/bool=true args/List -> int:
    full-command := [toit_run_, toit-bin-src_]
    if with-test-sdk:
      full-command += ["--sdk-dir", sdk-dir_]
    full-command += args
    return pipe.run-program full-command

  fork --with-test-sdk/bool=true args/List -> ForkResult:
    full-command := [toit_run_, toit-bin-src_]
    if with-test-sdk:
      full-command += ["--sdk-dir", sdk-dir_]
    full-command += args
    fork-data := pipe.fork
        true                // use_path
        // We create a stdin pipe, so that qemu can't interfere with
        // our terminal.
        pipe.PIPE-CREATED   // stdin.
        pipe.PIPE-CREATED   // stdout
        pipe.PIPE-CREATED   // stderr
        full-command.first
        full-command
    stdin := fork-data[0]
    stdout := fork-data[1]
    stderr := fork-data[2]
    child-process := fork-data[3]

    stdin.close

    stdout-string-latch := monitor.Latch
    stdout-task := task --background::
      try:
        bytes := #[]
        catch --trace:
          while chunk := stdout.read:
            bytes += chunk
          stdout-string-latch.set bytes.to-string
      finally:
        stdout.close

    stderr-string-latch := monitor.Latch
    stderr-task := task --background::
      try:
        bytes := #[]
        catch --trace:
          while chunk := stderr.read:
            bytes += chunk
          stderr-string-latch.set bytes.to-string
      finally:
        stderr.close

    exit-value := pipe.wait-for child-process
    exit-signal := pipe.exit-signal exit-value
    exit-code := pipe.exit-code exit-value

    return ForkResult
        --stdout=stdout-string-latch.get
        --stderr=stderr-string-latch.get
        --exit-signal=exit-signal
        --exit-code=exit-code
