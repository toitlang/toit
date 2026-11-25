// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that a host run-image keeps how installed containers run across a
// restart. A host's flash registry does not survive a restart (it is
// deleted after a crash, and the allocations' checksums cover the address
// the registry was mapped at), so run-image backs up every installed image
// in `installed-images/` and reinstalls it at the next start. The backup
// must keep the flags and the data the installer was given: an image
// installed untrusted was reinstalled as a trusted one, and ran with full
// privileges, and run-boot, run-critical and the data were lost.
//
// Also: an untrusted backup is verified again when it is reinstalled; a
// backup without metadata (written by an older build) is reinstalled as
// untrusted, so it is verified and runs sandboxed (a program the verifier
// rejects is not installed, and the others still are); a backup whose
// metadata does not match its image is not reinstalled.

import expect show *
import host.file
import host.pipe

import .util show EnvelopeTest with-test
import .installed-flags-source as source

// Prints whether the program may query its own policy (sandboxed programs
// may not, docs/sandbox-policy.md).
probe-source name/string -> string:
  return """
    main:
      kind := null
      exception := catch: kind = process-policy_ Process.current.id
      print "$name policy: \$(exception ? "denied" : kind)"

    process-policy_ pid/int:
      #primitive.core.process-policy
    """

// With TOIT_VERIFY_TIME=1, every verification prints a "verifier:" line.
VERIFY-TIME ::= "TOIT_VERIFY_TIME"

// The verifier rejects deep sleep in untrusted programs.
REJECTED-SOURCE ::= """
  import esp32
  main:
    esp32.deep-sleep (Duration --ms=10)
  """

main args:
  with-test args: | test/EnvelopeTest |
    test.install --name="installer" --source-path="./installed-flags-source.toit"
    test.extract-to-dir --dir-path=test.tmp-dir

    untrusted := build-image test "untrusted" (probe-source "untrusted")
    booted := build-image test "booted" (probe-source "booted")
    critical := build-image test "critical" (probe-source "critical")
    legacy := build-image test "legacy" (probe-source "legacy")
    rejected := build-image test "rejected" REJECTED-SOURCE

    print "Install untrusted"
    output := boot test {
      VERIFY-TIME: "1",
      source.ACTION: "install",
      source.IMAGE: untrusted,
      source.FLAGS: "untrusted",
    }
    expect (output.contains "verifier: accepted")
    expect (output.contains "untrusted policy: denied")
    untrusted-id := installed-id output
    expect (file.is-file (backup-path test untrusted-id))

    print "Restart untrusted"
    output = restart test {
      VERIFY-TIME: "1",
      source.ACTION: "run",
      source.ID: untrusted-id,
    }
    // Reinstalled from the backup: verified again and sandboxed.
    expect (output.contains "verifier: accepted")
    expect (output.contains "untrusted policy: denied")
    expect-not (output.contains "untrusted policy: 1")
    expect-equals "flags: 4 verified: 1 data: 0" (listed test)[untrusted-id]

    print "Install boot and critical"
    output = boot test {
      source.ACTION: "install",
      source.IMAGE: booted,
      source.FLAGS: "boot",
      source.DATA: "42",
      source.NO-START: "1",
    }
    booted-id := installed-id output
    output = boot test {
      source.ACTION: "install",
      source.IMAGE: critical,
      source.FLAGS: "critical,untrusted",
      source.DATA: "7",
      source.NO-START: "1",
    }
    critical-id := installed-id output

    print "Restart boot and critical"
    delete-registry test
    output = boot test {source.ACTION: "list"}
    images := parse-list output
    expect-equals "flags: 1 verified: 0 data: 42" images[booted-id]
    expect-equals "flags: 6 verified: 1 data: 7" images[critical-id]
    expect-equals "flags: 4 verified: 1 data: 0" images[untrusted-id]
    // The run-boot image was started at boot, the others weren't.
    expect (output.contains "booted policy: 1")
    expect-not (output.contains "critical policy:")
    expect-not (output.contains "untrusted policy:")

    print "Legacy backups"
    // Installed trusted, then the backups are replaced by the image alone,
    // as older builds wrote them.
    output = boot test {
      source.ACTION: "install",
      source.IMAGE: legacy,
      source.NO-START: "1",
    }
    legacy-id := installed-id output
    output = boot test {
      source.ACTION: "install",
      source.IMAGE: rejected,
      source.NO-START: "1",
    }
    rejected-id := installed-id output
    file.write-contents --path=(backup-path test legacy-id) (file.read-contents legacy)
    file.write-contents --path=(backup-path test rejected-id) (file.read-contents rejected)
    output = restart test {
      VERIFY-TIME: "1",
      source.ACTION: "run",
      source.ID: legacy-id,
    }
    // Reinstalled untrusted: verified and sandboxed.
    expect (output.contains "legacy policy: denied")
    expect-not (output.contains "legacy policy: 1")
    // The rejected one is reported and not installed; the backup stays.
    expect (output.contains "VERIFICATION_FAILED")
    expect (output.contains "installed-images/$rejected-id")
    images = listed test
    expect-equals "flags: 4 verified: 1 data: 0" images[legacy-id]
    expect-not (images.contains rejected-id)
    expect (file.is-file (backup-path test rejected-id))
    // The other backups were reinstalled as they were installed.
    expect-equals "flags: 1 verified: 0 data: 42" images[booted-id]
    expect-equals "flags: 4 verified: 1 data: 0" images[untrusted-id]

    print "Corrupted backup"
    // A backup whose image doesn't match its metadata is not reinstalled.
    path := backup-path test untrusted-id
    bytes := file.read-contents path
    bytes[bytes.size - 1] ^= 0xff
    file.write-contents --path=path bytes
    delete-registry test
    output = boot test {source.ACTION: "list"}
    expect (output.contains "installed-images/$untrusted-id")
    images = parse-list output
    expect-not (images.contains untrusted-id)
    expect-equals "flags: 1 verified: 0 data: 42" images[booted-id]

    print "Uninstall"
    // An image that wasn't reinstalled can still be uninstalled: its backup
    // goes away.
    output = boot test {source.ACTION: "uninstall", source.ID: rejected-id}
    expect-not (file.is-file (backup-path test rejected-id))

build-image test/EnvelopeTest name/string source-code/string -> string:
  source-path := "$test.tmp-dir/$(name).toit"
  file.write-contents --path=source-path source-code
  snapshot := "$test.tmp-dir/$(name).snapshot"
  // Compiled for untrusted containers: the image ships its certificate.
  run [test.toit-bin, "compile", "--untrusted", "--snapshot", "--output", snapshot, source-path]
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

boot test/EnvelopeTest env/Map -> string:
  // With the standard error output: the verifier and the system report there.
  boot-sh := "$test.tmp-dir/boot.sh"
  output := pipe.backticks ["bash", "-c", "exec bash \"\$0\" 2>&1", boot-sh] --environment=env
  print output
  return output

/**
Restarts the system: the flash registry doesn't survive, so the installed
  images are reinstalled from their backups.
*/
restart test/EnvelopeTest env/Map -> string:
  delete-registry test
  return boot test env

delete-registry test/EnvelopeTest -> none:
  path := "$test.tmp-dir/flash-registry"
  if file.is-file path: file.delete path

backup-path test/EnvelopeTest id/string -> string:
  return "$test.tmp-dir/ota0/installed-images/$id"

installed-id output/string -> string:
  return (output.split "installed: ")[1][..36]

listed test/EnvelopeTest -> Map:
  return parse-list (boot test {source.ACTION: "list"})

/** Parses the output of the "list" action: a map from id to description. */
parse-list output/string -> Map:
  result := {:}
  (output.split "\n").do: | line/string |
    if not line.starts-with "image: ": continue.do
    result[line[7..43]] = line[44..].trim
  return result
