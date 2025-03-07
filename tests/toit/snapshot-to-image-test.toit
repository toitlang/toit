// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.ubjson
import host.directory
import host.file
import host.pipe
import system

import .utils

main args:
  toit-exe := ToitExecutable args

  with-tmp-dir: | tmp-dir/string |
    src-path := "$tmp-dir/hello.toit"
    file.write-content --path=src-path """
      main: print "hello world"
      """

    hello-snapshot := "$tmp-dir/hello.snapshot"
    toit-exe.backticks ["compile", "-o", hello-snapshot, "--snapshot", src-path]

    hello32-image := "$tmp-dir/hello32.image"
    hello64-image := "$tmp-dir/hello64.image"
    ubjson-output := "$tmp-dir/hello.ubjson"
    toit-exe.backticks [
      "tool", "snapshot-to-image",
      "-o", hello32-image,
      "-m32",
      "--format=binary",
      hello-snapshot
    ]
    toit-exe.backticks [
      "tool", "snapshot-to-image",
      "-o",
      hello64-image,
      "-m64",
      "--format=binary",
      hello-snapshot
    ]
    toit-exe.backticks [
      "tool", "snapshot-to-image",
      "-o", ubjson-output,
      "-m32", "-m64",
      "--format=ubjson",
      hello-snapshot
    ]

    hello32-content := file.read-contents hello32-image
    hello64-content := file.read-contents hello64-image
    ubjson-content := file.read-contents ubjson-output
    decoded := ubjson.decode ubjson-content

    images := decoded["images"]
    ubjson-image32/ByteArray := ?
    ubjson-image64/ByteArray := ?
    if images[0]["flags"].contains "-m32":
      ubjson-image32 = images[0]["bytes"]
      ubjson-image64 = images[1]["bytes"]
    else:
      ubjson-image32 = images[1]["bytes"]
      ubjson-image64 = images[0]["bytes"]
    expect-equals ubjson-image32 hello32-content
    expect-equals ubjson-image64 hello64-content
