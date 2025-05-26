// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// TODO(florian): use the CLI package's test code.

import cli show *
import cli.ui show *
import encoding.json

class TestExit:

interface TestPrinter:
  set-test-ui_ test-ui/TestUi_?

class TestHumanPrinter extends HumanPrinter implements TestPrinter:
  test-ui_/TestUi_? := null

  print_ str/string:
    if not test-ui_.quiet_: super str
    test-ui_.add-stdout str

  set-test-ui_ test-ui/TestUi_:
    test-ui_ = test-ui

class TestJsonPrinter extends JsonPrinter implements TestPrinter:
  test-ui_/TestUi? := null

  print_ str/string:
    if not test-ui_.quiet_: super str
    test-ui_.add-stderr str

  emit-structured --kind/int data:
    test-ui_.stdout += json.stringify data

  set-test-ui_ test-ui/TestUi:
    test-ui_ = test-ui

interface TestUi_:
  add-stdout str/string -> none
  add-stderr str/string -> none
  quiet_ -> bool

class TestUi extends Ui implements TestUi_:
  stdout/string := ""
  stderr/string := ""
  quiet_/bool
  json_/bool

  constructor --level/int=Ui.NORMAL-LEVEL --quiet/bool=true --json/bool=false:
    quiet_ = quiet
    json_ = json
    printer := create-printer_ --json=json
    super --printer=printer --level=level
    (printer as TestPrinter).set-test-ui_ this

  add-stdout str/string -> none:
    stdout += "$str\n"

  add-stderr str/string -> none:
    stderr += "$str\n"

  static create-printer_ --json/bool -> Printer:
    if json: return TestJsonPrinter
    return TestHumanPrinter

  abort:
    throw TestExit

class TestMessagesUi extends Ui implements TestUi_:
  stdout-messages/List := []
  stderr-messages/List := []

  constructor:
    printer := TestHumanPrinter
    super --printer=printer
    (printer as TestPrinter).set-test-ui_ this

  quiet_ -> bool: return false

  add-stdout str/string -> none:
    stdout-messages.add str

  add-stderr str/string -> none:
    stderr-messages.add str

class TestCli implements Cli:
  name/string
  ui/TestUi

  constructor --.name/string="test" --quiet/bool=true:
    ui=(TestUi --quiet=quiet)

  cache -> Cache:
    unreachable

  config -> Config:
    unreachable

  with --name=null --cache=null --config=null --ui=null:
    unreachable
