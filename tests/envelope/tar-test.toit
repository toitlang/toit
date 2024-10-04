// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.file
import uuid
import .util show EnvelopeTest with-test

main args:
  with-test args: | test/EnvelopeTest |
    test.install --name="hello" --source="""
      main: print "hello world!"
      """
    test.install --name="no-boot" --no-boot --source="""
      main: print "no-boot"
      """
    test.extract-to-dir --dir-path=test.tmp-dir

    // The startup image and the no-boot image should be stored with their uuid.
    ota0 := "$test.tmp-dir/ota0/"
    ["startup-images", "bundled-images"].do: | image-dir/string|
      dir-stream := directory.DirectoryStream "$ota0/$image-dir"
      file-name := dir-stream.next
      // The files should be stored with their uuids.
      uuid.Uuid.parse file-name
      expect-null dir-stream.next
      dir-stream.close

    expect (file.is-file "$ota0/bits.bin")
    expect (file.is-file "$ota0/validated")
