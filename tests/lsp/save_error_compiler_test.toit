// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *
import host.file
import writer show Writer

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

save_to_file path content:
  stream := file.Stream.for_write path
  writer := Writer stream
  writer.write content
  stream.close

NO_ERROR_VERSION ::= """
  class A:
    field / A? := null
  """

ERROR_VERSION ::=  """
  class A:
    field / A[] := null
  """

test client/LspClient:
  temp := null
  while not temp or file.is_file temp or file.is_directory temp:
    temp = "/tmp/save_error_test-$(random).toit"

  try:
    print "Using $temp"

    save_to_file temp ""

    print "Opening file in fake client"
    client.send_did_open --path=temp --text=""

    3.repeat:
      print "Sending non-error version to LSP"
      client.send_did_change --path=temp NO_ERROR_VERSION
      expect_equals 0 (client.diagnostics_for --path=temp).size

      print "Saving non-error version and notifying LSP of save."
      save_to_file temp NO_ERROR_VERSION
      client.send_did_save --path=temp
      expect_equals 0 (client.diagnostics_for --path=temp).size

      print "Sending error version to LSP"
      client.send_did_change --path=temp ERROR_VERSION
      expect (client.diagnostics_for --path=temp).size > 0

      print "Changing the file to a version with error"
      save_to_file temp ERROR_VERSION
      client.send_did_save --path=temp
      expect (client.diagnostics_for --path=temp).size > 0

  finally:
    print "Deleting $temp"
    file.delete temp
