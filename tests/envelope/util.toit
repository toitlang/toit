// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import fs
import host.file
import host.directory
import host.pipe
import host.os
import system
import tar

with-test arguments/List [block]:
  test := EnvelopeTest arguments
  try:
    block.call test
  finally:
    test.close

class EnvelopeTest:
  original-envelope/string
  toit-bin/string
  envelope/string
  tmp-dir/string

  constructor arguments/List:
    toit-bin = arguments[0]
    original-envelope = arguments[1]

    tmp-dir = directory.mkdtemp "/tmp/envelope-test-"
    envelope = "$tmp-dir/firmware.envelope"
    file.copy --source=original-envelope --target=envelope

  close -> none:
    directory.rmdir --recursive tmp-dir

  compile --path/string --source/string -> none:
    tmp-toit-path := "$tmp-dir/__tmp__.toit"
    file.write-content --path=tmp-toit-path source
    compile --path=path --source-path=tmp-toit-path

  compile --path/string --source-path/string -> none:
    if fs.is-relative source-path:
      // Make the path relative to the test.
      source-path = fs.join (fs.dirname system.program-path) source-path

    run-program_ [toit-bin, "compile", "--snapshot", "--output", path, source-path]

  install --name/string --snapshot-path/string --boot/bool=true --assets/Map?=null -> none:
    cmd := [toit-bin, "tool", "firmware", "-e", envelope, "container", "install", name, snapshot-path]
    if boot:
      cmd.add-all ["--trigger", "boot"]
    if assets:
      tmp-assets-path := "$tmp-dir/__tmp__.assets"
      run-program_ [toit-bin, "tool", "assets", "create", "--assets", tmp-assets-path]
      assets.do: | name value |
        tmp-asset-path := "$tmp-dir/$(name).asset"
        file.write-content --path=tmp-asset-path value
        run-program_ [toit-bin, "tool", "assets", "add", "--assets", tmp-assets-path, name, tmp-asset-path]
      cmd.add-all ["--assets", tmp-assets-path]
    run-program_ cmd

  install --name/string --source/string --boot/bool=true -> none:
    tmp-source-path := "$tmp-dir/__tmp__.toit"
    file.write-content --path=tmp-source-path source
    install --name=name --source-path=tmp-source-path --boot=boot

  install --name/string --source-path/string --boot/bool=true --assets/Map?=null -> none:
    tmp-snapshot-path := "$tmp-dir/__tmp__.snapshot"
    compile --path=tmp-snapshot-path --source-path=source-path
    install --name=name --snapshot-path=tmp-snapshot-path --boot=boot --assets=assets

  extract --path/string --format/string="binary" -> none:
    run-program_ [toit-bin, "tool", "firmware", "-e", envelope, "extract", "--format", format, "-o", path]

  extract-to-dir --dir-path/string -> none:
    directory.mkdir --recursive dir-path
    tmp-extracted := "$tmp-dir/__extracted__"
    extract --path=tmp-extracted --format="tar"
    run-program_ ["tar", "x", "-f", tmp-extracted, "-C", dir-path]

  build-ota --name/string --source/string --output/string -> none:
    tmp-source-path := "$tmp-dir/__tmp__.toit"
    file.write-content --path=tmp-source-path source
    build-ota --name=name --source-path=tmp-source-path --output=output

  build-ota --name/string --source-path/string --output/string -> none:
    with-test [toit-bin, original-envelope]: | test-other/EnvelopeTest |
      test-other.install --name=name --source-path=source-path
      test-other.extract --path=output

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

  boot dir/string --env/Map?=null -> string:
    bash := "bash"
    path := "$dir/boot.sh"
    if system.platform == system.PLATFORM-WINDOWS:
      // Running on Windows is tricky...
      // - We want Git's bash and not any other. The path to the git-bash must
      //   be in Windows format.
      // - We provide a shell script as argument. That script must be in Unix
      //   (cygwin) format.
      // Example: `C:/Program Files/Git/usr/bin/bash.exe /tmp/envelope-test-...`.
      path = (backticks_ ["cygpath", "-u", path] --env=null).trim
      program-files-path := os.env.get "ProgramFiles"
      if not program-files-path:
        // This is brittle, as Windows localizes the name of the folder.
        program-files-path = "C:/Program Files"
      bash = "$program-files-path/Git/usr/bin/bash.exe"
    return backticks_ --env=env [bash, path]

  run-program_ args/List --env/Map?=null --allow-fail/bool=false -> int:
    exit-code := pipe.run-program args --environment=env
    if not allow-fail and exit-code != 0:
      throw "Failed to run $(args.join " ") with env $env: $exit-code"
    return exit-code

  backticks_ args/List --env/Map? -> string:
    return pipe.backticks args --environment=env
