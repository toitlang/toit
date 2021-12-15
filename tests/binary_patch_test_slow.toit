// Copyright (C) 2018 Toitware ApS. All rights reserved.

import reader show *
import bytes
import expect show *
import monitor show *
import reader_writer show *
import crypto.sha256 show *

import ..system.lib.patch show *
import ..system.tools.binary_diff show *

main:
  test
    "Now is the time for all good men to come to the aid of the party"
    "Now is the time for all good men to come to the aid of the party"

  test
    "Now is the time for all good men to come to the aid of the party"
    "Now is the time for all good men to come to the aid of the party1234"

  test
    "Now is the time for all Good men to come to the aid of the party"
    "Now is the time for all good men to come to the aid of the party"

  test
    "Now Is The Time For All Good Men To Come To The Aid Of The Party"
    "Now is the time for all good men to come to the aid of the party"

  test
    "The quick brown fox jumps over the lazy dog."
    "Now is the time for all good men to come to the aid of the party"

  orig ::= """\
     There are plenty of people in Avonlea and out of it, who can attend
     closely to their neighbor’s business by dint of neglecting their own;
     but Mrs. Rachel Lynde was one of those capable creatures who can manage
     their own concerns and those of other folks into the bargain. She was a
     notable housewife; her work was always done and well done; she “ran” the
     Sewing Circle, helped run the Sunday-school, and was the strongest prop
     of the Church Aid Society and Foreign Missions Auxiliary. Yet with all
     this Mrs. Rachel found abundant time to sit for hours at her kitchen
     window, knitting “cotton warp” quilts--she had knitted sixteen of them,
     as Avonlea housekeepers were wont to tell in awed voices--and keeping
     a sharp eye on the main road that crossed the hollow and wound up
     the steep red hill beyond. Since Avonlea occupied a little triangular
     peninsula jutting out into the Gulf of St. Lawrence with water on two
     sides of it, anybody who went out of it or into it had to pass over that
     hill road and so run the unseen gauntlet of Mrs. Rachel’s all-seeing
     eye"""

  reformatted ::= """\
     There are plenty of people in Avonlea and out of it, who can attend
     closely to their neighbour’s business by dint of neglecting their
     own; but Mrs. Rachel Lynde was one of those capable creatures who can
     manage their own concerns and those of other folks into the bargain.
     She was a notable housewife; her work was always done and well done;
     she "ran" the Sewing Circle, helped run the Sunday school, and was
     the strongest prop of the Church Aid Society and Foreign Missions
     Auxiliary.  Yet with all this Mrs. Rachel found abundant time to
     sit for hours at her kitchen window, knitting "cotton warp" quilts -
     she had knitted sixteen of them, as Avonlea housekeepers were wont
     to tell in awed voices - and keeping a sharp eye on the main road
     that crossed the hollow and wound up the steep red hill beyond.
     Since Avonlea occupied a little triangular peninsula jutting out
     into the Gulf of St. Lawrence with water on two sides of it, anybody
     who went out of it or into it had to pass over that hill road and
     so run the unseen gauntlet of Mrs. Rachel's all-seeing eye.."""

  test orig reformatted
  test orig reformatted + reformatted
  test orig + reformatted reformatted + reformatted
  test orig + orig reformatted + orig

test old/string new/string -> none:
  expect old.size & 3 == 0
  expect new.size & 3 == 0
  old_bytes := ByteArray old.size
  old_bytes.replace 0 old
  new_bytes := ByteArray new.size
  new_bytes.replace 0 new

  old_data := OldData old_bytes
  old_gappy_data := OldData old_bytes 8 16  // Don't use bytes 8-15.

  test2 old_data old_bytes new_bytes --fast=true
  test2 old_gappy_data old_bytes new_bytes --fast=true

  if platform != "FreeRTOS":
    test2 old_data old_bytes new_bytes --fast=false
    test2 old_gappy_data old_bytes new_bytes --fast=false

test2 old_data/OldData old_bytes/ByteArray new_bytes/ByteArray --fast/bool -> none:
  buffer := bytes.Buffer
  new_checksum_block
    new_bytes
    buffer
    sha256 new_bytes
  diff
    old_data
    new_bytes
    buffer
    --fast=fast
    --with_header=true
    --with_footer=true
  print "$(fast ? "Fast" : "Slow") $new_bytes.size -> $buffer.size"

  expected_new_checksum := sha256 new_bytes

  reader_writer := ReaderWriter
  task::
    reader_writer.write buffer.bytes
    reader_writer.close
  patcher := Patcher
    BufferedReader reader_writer.reader
    old_bytes
  rebuilt := bytes.Buffer
  observer := Observer rebuilt
  patcher.patch observer

  observer.metadata_hash.size.repeat: expect_equals expected_new_checksum[it] observer.metadata_hash[it]

  patcher.check_result expected_new_checksum
  expect_equals observer.expected_size rebuilt.size
  expect_equals new_bytes rebuilt.bytes

class Observer implements PatchObserver:
  rebuilt := ?
  expected_size/int? := null
  metadata_hash/ByteArray? := null

  constructor .rebuilt:

  on_write data/ByteArray from/int=0 to/int=data.size -> none:
    rebuilt.write data from to

  on_size size/int -> none:
    expected_size = size

  on_new_checksum hash/ByteArray -> none:
    metadata_hash = hash

  on_checkpoint patch_position/int -> none:
