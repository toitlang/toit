// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that a host run-image keeps the flags and the data of installed
// containers across a restart. The flash registry of a host doesn't survive
// a crash (the boot script deletes it), so run-image backs up every
// installed image in `installed-images/` and reinstalls it at the next
// start. The backup must keep the run-boot and run-critical flags and the
// data the image was installed with.
//
// Also: a backup of an older build (the image alone) is still reinstalled;
// a backup whose image doesn't match its metadata is not reinstalled, and
// doesn't stop the start; uninstalling an image deletes its backup.

import expect show *
import host.file
import host.pipe

import .util show EnvelopeTest with-test
import .installed-flags-source as source

main args:
  with-test args: | test/EnvelopeTest |
    test.install --name="installer" --source-path="./installed-flags-source.toit"
    test.extract-to-dir --dir-path=test.tmp-dir

    booted := build-image test "booted"
    critical := build-image test "critical"
    with-data := build-image test "with-data"
    legacy := build-image test "legacy"

    print "Install"
    // The install checks that the image is listed with the flags and data.
    booted-id := install test booted --flags="boot"
    critical-id := install test critical --flags="critical"
    data-id := install test with-data --data=42

    print "Restart"
    // The registry is deleted after a crash: the installed images are
    // reinstalled from their backups.
    delete-registry test
    output := boot test {source.ACTION: "list"}
    images := parse-list output
    expect-equals "flags: 1 data: 0" images[booted-id]
    expect-equals "flags: 2 data: 0" images[critical-id]
    expect-equals "flags: 0 data: 42" images[data-id]
    // The run-boot image was started at boot.
    expect (output.contains "booted: running")
    expect-not (output.contains "critical: running")
    expect-not (output.contains "with-data: running")

    print "Reinstall"
    // Installing an image again replaces its backup.
    expect-equals data-id (install test with-data --flags="boot" --data=7)
    delete-registry test
    output = boot test {source.ACTION: "list"}
    expect-equals "flags: 1 data: 7" (parse-list output)[data-id]
    expect (output.contains "with-data: running")

    print "Old backup"
    // Older builds wrote the image alone. Such a backup is reinstalled
    // without flags and data, as before.
    legacy-id := install test legacy --flags="boot" --data=3
    file.write-contents --path=(backup-path test legacy-id) (file.read-contents legacy)
    delete-registry test
    output = boot test {source.ACTION: "list"}
    images = parse-list output
    expect-equals "flags: 0 data: 0" images[legacy-id]
    expect-not (output.contains "legacy: running")
    expect-equals "flags: 1 data: 0" images[booted-id]

    print "Corrupted backup"
    // A backup whose image doesn't match its metadata is reported and not
    // reinstalled. The other images are still reinstalled and started.
    path := backup-path test critical-id
    bytes := file.read-contents path
    bytes[bytes.size - 1] ^= 0xff
    file.write-contents --path=path bytes
    delete-registry test
    output = boot test {source.ACTION: "list"}
    expect (output.contains "installed-images/$critical-id")
    images = parse-list output
    expect-not (images.contains critical-id)
    expect-equals "flags: 1 data: 0" images[booted-id]
    expect-equals "flags: 1 data: 7" images[data-id]
    expect (output.contains "booted: running")

    print "Uninstall"
    // Uninstalling deletes the backup, also of an image that wasn't
    // reinstalled.
    boot test {source.ACTION: "uninstall", source.ID: critical-id}
    expect-not (file.is-file (backup-path test critical-id))
    boot test {source.ACTION: "uninstall", source.ID: booted-id}
    expect-not (file.is-file (backup-path test booted-id))
    delete-registry test
    images = listed test
    expect-not (images.contains critical-id)
    expect-not (images.contains booted-id)
    expect-equals "flags: 1 data: 7" images[data-id]

/** Builds an image that prints "<name>: running". */
build-image test/EnvelopeTest name/string -> string:
  snapshot := "$test.tmp-dir/$(name).snapshot"
  test.compile --path=snapshot --source="""
    main: print "$name: running"
    """
  image := "$test.tmp-dir/$(name).image"
  run [
    test.toit-bin, "tool", "snapshot-to-image",
    test.word-size == 4 ? "-m32" : "-m64",
    "--format", "binary",
    "-o", image,
    snapshot,
  ]
  return image

run command/List -> none:
  exit-code := pipe.run-program command
  if exit-code != 0: throw "Failed: $(command.join " ")"

install test/EnvelopeTest image/string --flags/string="" --data/int=0 -> string:
  env := {
    source.ACTION: "install",
    source.IMAGE: image,
    source.DATA: "$data",
  }
  if flags != "": env[source.FLAGS] = flags
  output := boot test env
  id := (output.split "installed: ")[1][..36]
  expected-flags := 0
  if flags.contains "boot": expected-flags |= 1
  if flags.contains "critical": expected-flags |= 2
  expect-equals "flags: $expected-flags data: $data" (parse-list output)[id]
  return id

/** Runs the boot script and returns its output, with the error output. */
boot test/EnvelopeTest env/Map -> string:
  boot-sh := "$test.tmp-dir/boot.sh"
  output := pipe.backticks ["bash", "-c", "exec bash \"\$0\" 2>&1", boot-sh] --environment=env
  print output
  return output

delete-registry test/EnvelopeTest -> none:
  path := "$test.tmp-dir/flash-registry"
  if file.is-file path: file.delete path

backup-path test/EnvelopeTest id/string -> string:
  return "$test.tmp-dir/ota0/installed-images/$id"

listed test/EnvelopeTest -> Map:
  return parse-list (boot test {source.ACTION: "list"})

/** Parses the output of the "list" action: a map from id to description. */
parse-list output/string -> Map:
  result := {:}
  (output.split "\n").do: | line/string |
    if not line.starts-with "image: ": continue.do
    result[line[7..43]] = line[44..].trim
  return result
