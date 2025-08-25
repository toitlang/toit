// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/TESTS_LICENSE file.

import expect show *

import host.file
import host.directory
import system

NO_CHANGE_TIME_ ::= (1 << 30) - 2

file-update-time path/string --access/Time?=null --modification/Time?=null:
  atime_s/int := ?
  atime_ns/int := ?
  if access:
    atime_s = access.s-since-epoch
    atime_ns = access.ns-part
  else:
    atime_s = 0
    atime_ns = NO-CHANGE-TIME_

  mtime_s/int := ?
  mtime_ns/int := ?
  if modification:
    mtime_s = modification.s-since-epoch
    mtime_ns = modification.ns-part
  else:
    mtime_s = 0
    mtime_ns = NO-CHANGE-TIME_

  update-times_ path atime_s atime_ns mtime_s mtime_ns

update-times_ path/string atime_s/int atime_ns/int mtime_s/int mtime_ns/int -> none:
  #primitive.file.update-times

with-tmp-dir [block]:
  dir := directory.mkdtemp "/tmp/test"
  try:
    block.call dir
  finally:
    directory.rmdir --recursive --force dir

TIME-SLACK ::= Duration --ms=3
expect-in-between-time a/Time b/Time c/Time:
  // We have seen cases where the mtime is before the "before"
  // time. Since the resolution of filesystems isn't guaranteed
  // anyway, just give some slack.
  slack := Duration --ms=3
  expect a - slack <= b <= c + slack

FS-SLACK ::= system.platform == system.PLATFORM-WINDOWS
    ? Duration --ns=200  // Windows FILETIME is in 100ns increments.
    : Duration.ZERO
expect-fs-equals a/Time b/Time:
  expect (a.to b).abs < FS-SLACK

main:
  with-tmp-dir: | dir/string |
   e := catch --trace:
    test-file := "$dir/test.txt"
    test test-file
      --create=: file.write-contents --path=it "foo"
      --update-access=: file.read-contents it
      --update-modification=: file.write-contents --path=it "bar"

    test-dir := "$dir/test"
    test test-dir
      --create=:
        directory.mkdir it
      --update-access=:
        dir-stream := directory.DirectoryStream it
        while dir-stream.next: null
        dir-stream.close
      --update-modification=:
        file.write-contents --path="$it/inner" "bar"

test test-path/string
    [--create]
    [--update-access]
    [--update-modification]:
  expect-throw "FILE_NOT_FOUND": file-update-time test-path --access=Time.now

  before := Time.now
  create.call test-path
  stat-result := file.stat test-path
  atime := stat-result[file.ST-ATIME]
  mtime := stat-result[file.ST-MTIME]
  ctime := stat-result[file.ST-CTIME]
  sleep --ms=10
  after := Time.now
  expect-in-between-time before atime after
  expect-in-between-time before mtime after
  expect-in-between-time before ctime after
  update-time := Time.now

  // Update the atime.
  // With mount-option "relatime" (most commonly used nowadays), the
  // atime should be guaranteed to be greater than mtime now.
  update-access.call test-path
  stat-result = file.stat test-path
  atime = stat-result[file.ST-ATIME]
  mtime = stat-result[file.ST-MTIME]
  expect atime >= mtime

  // Update the access time.
  file-update-time test-path --access=update-time
  stat-result = file.stat test-path
  atime = stat-result[file.ST-ATIME]
  unchanged-mtime := stat-result[file.ST-MTIME]
  expect-fs-equals update-time atime
  expect-fs-equals mtime unchanged-mtime

  before = Time.now
  update-modification.call test-path
  after = Time.now
  stat-result = file.stat test-path
  atime = stat-result[file.ST-ATIME]
  mtime = stat-result[file.ST-MTIME]
  expect-in-between-time before atime after
  expect-in-between-time before mtime after

  // Update the modification time.
  update-time2 := Time.now
  file-update-time test-path --modification=update-time2
  stat-result = file.stat test-path
  atime = stat-result[file.ST-ATIME]
  mtime = stat-result[file.ST-MTIME]
  expect-fs-equals update-time atime
  expect-fs-equals update-time2 mtime

  // Update both times.
  update-time = Time.now
  update-time2 = Time.now

  file-update-time test-path --access=update-time --modification=update-time2
  stat-result = file.stat test-path
  atime = stat-result[file.ST-ATIME]
  mtime = stat-result[file.ST-MTIME]
  expect-fs-equals update-time atime
  expect-fs-equals update-time2 mtime
