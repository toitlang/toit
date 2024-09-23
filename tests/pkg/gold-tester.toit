// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import fs
import host.directory
import host.file
import host.pipe
import host.os
import system

with-tmp-dir [block]:
  tmp-dir := directory.mkdtemp "/tmp/test-"
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir

class RunResult_:
  stdout/string
  stderr/string
  exit-value/int

  constructor --.stdout --.stderr --.exit-value:

  exit-code -> int:
    if (exit-value & pipe.PROCESS-SIGNALLED_) != 0:
      // Process crashed.
      exit-signal := pipe.exit-signal exit-value
      return -exit-signal
    return pipe.exit-code exit-value

  normalize -> string:
    result := stdout.replace --all "\r" ""
    if result != "" and not result.ends-with "\n":
      result += "\n <Missing newline at end of stdout> \n"
    if stderr != "":
      result += "\nSTDERR---\n" + stderr
      if not stderr.ends-with "\n":
        result += "\n <Missing newline at end of stderr> \n"
    result += "Exit Code: $exit-code\n"
    return result

class GoldTester:
  gold-dir_/string
  working-dir_/string
  toit-exec_/string
  should-update_/bool

  constructor
      --toit-exe/string
      --gold-dir/string
      --working-dir/string
      --should-update/bool:
    toit-exec_ = toit-exe
    gold-dir_ = gold-dir
    working-dir_ = working-dir
    should-update_ = should-update

  gold name/string commands/List:
    commands.do: | command-line/List |
      command := command-line.first
      outputs := []
      if command == "analyze":
        run-result := analyze command-line[1..]
        normalized := run-result.normalize
        command-string := command-line.join " "
        outputs.add "$command-string\n$normalized"

      gold-file := fs.join gold-dir_ "$(name).gold"
      actual := outputs.join "==================\n"
      if should-update_:
        directory.mkdir --recursive gold-dir_
        file.write-content --path=gold-file actual
      else:
        expected-content := (file.read-content gold-file).to-string
        expected-content = expected-content.replace --all "\r" ""
        expect-equals expected-content actual

  analyze args -> RunResult_:
    directory.chdir working-dir_
    full-args := [toit-exec_, "analyze", "--"] + args
    fork-data := pipe.fork
        true
        pipe.PIPE-INHERITED
        pipe.PIPE-CREATED
        pipe.PIPE-CREATED
        toit-exec_
        full-args
    stdout := fork-data[1]
    stderr := fork-data[2]
    child-process := fork-data[3]

    stdout-data := #[]
    stdout-task := task::
      try:
        while chunk := stdout.read:
          stdout-data += chunk
      finally:
        stdout.close

    stderr-data := #[]
    stderr-task := task::
      try:
        while chunk := stderr.read:
          stderr-data += chunk
      finally:
        stderr.close

    exit-value := pipe.wait-for child-process
    stdout-task.cancel
    stderr-task.cancel

    return RunResult_
        --stdout=stdout-data.to-string
        --stderr=stderr-data.to-string
        --exit-value=exit-value


setup-assets dir/string --assets-dir/string:
  stream := directory.DirectoryStream assets-dir
  while name := stream.next:
    if name == "gold": continue
    file.copy --recursive --source=(fs.join assets-dir name) --target=(fs.join dir name)

with-gold-tester args/List [block]:
  toit-exe := args[0]
  source-location := system.program-path
  source-dir := fs.dirname source-location
  source-name := (fs.basename source-location).trim --right "-gold-test.toit"
  assets-dir := fs.join source-dir "assets" source-name
  gold-dir := fs.join assets-dir "gold" source-name

  with-tmp-dir: | tmp-dir |
    setup-assets tmp-dir --assets-dir=assets-dir
    tester := GoldTester
        --toit-exe=toit-exe
        --gold-dir=gold-dir
        --working-dir=tmp-dir
        --should-update=(os.env.get "UPDATE_GOLD") != null
    block.call tester
