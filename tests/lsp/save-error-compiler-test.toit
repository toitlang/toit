// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import host.file
import host.directory
import io

main args:
  run-client-test args: test it

save-to-file path content:
  stream := file.Stream.for-write path
  writer := io.Writer.adapt stream
  writer.write content
  stream.close

NO-ERROR-VERSION ::= """
  class A:
    field / A? := null
  """

ERROR-VERSION ::=  """
  class A:
    field / A[] := null
  """

test client/LspClient:
  tmp-dir := directory.mkdtemp "/tmp/save-error-test-"
  temp := "$tmp-dir/test.toit"

  try:
    print "Using $temp"

    save-to-file temp ""

    print "Opening file in fake client"
    client.send-did-open --path=temp --text=""

    3.repeat:
      print "Sending non-error version to LSP"
      client.send-did-change --path=temp NO-ERROR-VERSION
      expect-equals 0 (client.diagnostics-for --path=temp).size

      print "Saving non-error version and notifying LSP of save."
      save-to-file temp NO-ERROR-VERSION
      client.send-did-save --path=temp
      expect-equals 0 (client.diagnostics-for --path=temp).size

      print "Sending error version to LSP"
      client.send-did-change --path=temp ERROR-VERSION
      expect (client.diagnostics-for --path=temp).size > 0

      print "Changing the file to a version with error"
      save-to-file temp ERROR-VERSION
      client.send-did-save --path=temp
      expect (client.diagnostics-for --path=temp).size > 0

  finally:
    print "Deleting $tmp-dir"
    directory.rmdir --recursive tmp-dir
