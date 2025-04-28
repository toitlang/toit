// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.sha256
import expect show *
import host.file
import .util show EnvelopeTest with-test

main args:
  test-success args
  test-rollback args

test-success args/List:
  2.repeat: | exit-code |
    with-test args: | test/EnvelopeTest |
      update-bits-path := "$test.tmp-dir/update-bits.bin"
      test.build-ota --output=update-bits-path --name="success" --source-path="./boot-upgraded-success.toit"
      test.install --name="update" --source-path="./boot-upgrade-source.toit"
      test.extract-to-dir --dir-path=test.tmp-dir

      output := test.boot-backticks test.tmp-dir --env={
        "TOIT_FIRMWARE_TEST_PATH": update-bits-path,
        "BOOT_TEST_DIR": test.tmp-dir,
        "BOOT-EXIT-CODE": "$exit-code",
      }
      expect-contains output [
        "updating",
        "*** Switching firmware to ota1",  // From the boot script.
        "hello from updated",
        "validation is pending",
        "can rollback",
        "validating",
        "hello from updated",
        "validation is not pending",
        "can not rollback",
        "exiting",
      ]
      if exit-code != 0:
        expect-contains output [
          "*** Firmware crashed",  // From the boot script.
        ]

      expect-not (output.contains "successful rollback")

test-rollback args/List:
  3.repeat: | iteration |
    with-test args: | test/EnvelopeTest |
      update-bits-path := "$test.tmp-dir/update-bits.bin"
      test.build-ota --output=update-bits-path --name="success" --source-path="./boot-upgraded-fail-$(iteration).toit"
      test.install --name="update" --source-path="./boot-upgrade-source.toit"
      test.extract-to-dir --dir-path=test.tmp-dir

      output := test.boot-backticks test.tmp-dir --env={
        "TOIT_FIRMWARE_TEST_PATH": update-bits-path,
      }
      expected-snippets := [
        "updating",
        "*** Switching firmware to ota1",  // From the boot script.
        "hello from updated",
        "validation is pending",
        "can rollback",
      ]
      if iteration == 0:
        expected-snippets += [
          "not validating",
          "*** Validation failed. Rolling back"
        ]
      else if iteration == 1:
        expected-snippets += [
          "not validating and throwing",
          "*** Firmware crashed",
          "*** Validation failed. Rolling back"
        ]
      else if iteration == 2:
        expected-snippets += [
          "not validating and rolling back",
          "*** Rollback requested",
        ]
      else:
        throw "Invalid iteration: $iteration"

      expected-snippets += [
        "successful rollback"
      ]

      expect-contains output expected-snippets

expect-contains str/string needles/List:
  start-pos := 0
  needles.do: | needle/string |
    pos := str.index-of needle start-pos
    if pos == -1:
      print "Expected to find needle: $needle"
      print "In string: $str"
      expect (pos != -1)
    start-pos = pos + needle.size
