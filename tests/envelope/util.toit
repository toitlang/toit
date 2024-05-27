// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import fs
import host.file
import host.directory
import host.pipe
import system
import tar

with-test arguments/List [block]:
  test := EnvelopeTest arguments
  try:
    block.call test
  finally:
    test.close

class EnvelopeTest:
  toit-bin/string
  envelope/string
  tmp-dir/string

  constructor arguments/List:
    toit-bin = arguments[0]
    original-envelope := arguments[1]

    tmp-dir = directory.mkdtemp "/tmp/envelope-test-"
    envelope = "$tmp-dir/firmware.envelope"
    file.copy --source=original-envelope --target=envelope

  close:
    directory.rmdir --recursive tmp-dir

  compile --path/string --source/string:
    tmp-toit-path := "$tmp-dir/__tmp__.toit"
    file.write-content --path=tmp-toit-path source
    compile --path=path --source-path=tmp-toit-path

  compile --path/string --source-path/string:
    if fs.is-relative source-path:
      // Make the path relative to the test.
      source-path = fs.join (fs.dirname system.program-path) source-path

    run-program_ [toit-bin, "compile", "--snapshot", "--output", path, source-path]

  install --name/string --snapshot-path/string --boot/bool=true:
    cmd := [toit-bin, "tool", "firmware", "-e", envelope, "container", "install", name, snapshot-path]
    if boot:
      cmd.add-all ["--trigger", "boot"]
    run-program_ cmd

  install --name/string --source/string --boot/bool=true:
    tmp-snapshot-path := "$tmp-dir/__tmp__.snapshot"
    compile --path=tmp-snapshot-path --source=source
    install --name=name --snapshot-path=tmp-snapshot-path --boot=boot

  install --name/string --source-path/string --boot/bool=true:
    tmp-snapshot-path := "$tmp-dir/__tmp__.snapshot"
    compile --path=tmp-snapshot-path --source-path=source-path
    install --name=name --snapshot-path=tmp-snapshot-path --boot=boot

  extract --path/string --format/string="binary":
    run-program_ [toit-bin, "tool", "firmware", "-e", envelope, "extract", "--format", format, "-o", path]

  extract-to-dir --dir-path/string:
    directory.mkdir --recursive dir-path
    tmp-extracted := "$tmp-dir/__extracted__"
    extract --path=tmp-extracted --format="tar"
    // TODO(florian): this doesn't work on Windows.
    run-program_ ["tar", "x", "-f", tmp-extracted, "-C", dir-path]
    // TODO(florian): currently the run-image is not marked as executable inside the tar.
    file.chmod "$dir-path/run-image" 0b111_000_000

  backticks ota-active/string --env/Map?=null -> string:
    return backticks --env=env --ota-active=ota-active --ota-inactive="$tmp-dir/__inactive__"

  backticks --ota-active/string --ota-inactive/string --create-inactive/bool=true --env/Map?=null -> string:
    directory.mkdir --recursive ota-inactive
    // TODO(florian): this doesn't work on Windows. Would require an .exe suffix.
    exe := "$ota-active/run-image"
    return backticks_ [exe, ota-active, ota-inactive] --env=env

  run ota-active/string --env/Map?=null --allow-fail/bool=false -> int:
    return run --env=env --ota-active=ota-active --ota-inactive="$tmp-dir/__inactive__" --allow-fail=allow-fail

  run --ota-active/string --ota-inactive/string --create-inactive/bool=true --env/Map?=null --allow-fail/bool=false -> int:
    directory.mkdir --recursive ota-inactive
    // TODO(florian): this doesn't work on Windows. Would require an .exe suffix.
    exe := "$ota-active/run-image"
    return run-program_ [exe, ota-active, ota-inactive] --env=env --allow-fail=allow-fail

  run-program_ args/List --env/Map?=null --allow-fail/bool=false -> int:
    exit-code := pipe.run-program args --environment=env
    if not allow-fail and exit-code != 0:
      throw "Failed to run $(args.join " ") with env $env: $exit-code"
    return exit-code

  backticks_ args/List --env/Map? -> string:
    return pipe.backticks args --environment=env
