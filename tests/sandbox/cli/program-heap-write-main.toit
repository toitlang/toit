// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. Hardening tests of the refusal to write
// the read-only program heap through the primitives that write into an
// existing object (docs/sandbox-guarantee.md, section 2.4: the contract of a
// primitive keeps read-only objects unchanged; proved for the Rust ports,
// an assumption for the C++ primitives). Each attack aims a primitive at an
// object of the program heap: the byte array behind a byte-array literal
// (the literal itself is a copy-on-write wrapper made at run time), a
// copy-on-write wrapper over such bytes that claims to be mutable (so that
// the primitive takes the program-heap bytes as its destination, through
// the Rust ports follow such a wrapper; byte_zap and blit are C++), and a
// string literal. Every attack must fail cleanly and leave the bytes
// unchanged. An immutable copy-on-write wrapper over program-heap bytes
// sends the ports to their C++ primitive, which writes into a fresh copy
// it installs in the wrapper: the program-heap bytes stay unchanged.

import bitmap

// The primitives, called directly (the library wraps them in methods).
put-uint-big-endian_ order bytes width offset value:
  #primitive.core.put-uint-big-endian

put-uint-little-endian_ order bytes width offset value:
  #primitive.core.put-uint-little-endian

put-float-64-little-endian_ order bytes offset value:
  #primitive.core.put-float-64-little-endian

put-float-32-little-endian_ order bytes offset value:
  #primitive.core.put-float-32-little-endian

byte-array-replace_ receiver index source from to:
  #primitive.core.byte-array-replace

byte-array-at-put_ receiver n value:
  #primitive.core.byte-array-at-put

string-write-to-byte-array_ source dest from to dest-index:
  #primitive.core.string-write-to-byte-array

add-finalizer_ object lambda:
  #primitive.core.add-finalizer

remove-finalizer_ object:
  #primitive.core.remove-finalizer

byte-zap_ bytes value:
  #primitive.bitmap.byte-zap

blit_ destination destination-pixel-stride destination-line-stride source source-pixel-stride source-line-stride pixels-per-line lookup-table shift mask operation:
  #primitive.bitmap.blit

timer-arm_ timer us:
  #primitive.timer.arm

timer-delete_ group timer:
  #primitive.timer.delete

events-read-state_ module id:
  #primitive.events.read-state

events-unregister_ module id:
  #primitive.events.unregister-monitor-notifier

backing_ cow/any:
  return cow.backing_

failures := 0

// Runs the attack, prints its error and whether the program-heap bytes
// kept their contents.
attack name/string bytes/ByteArray [block]:
  before := List bytes.size: bytes[it]
  error := catch: block.call
  after := List bytes.size: bytes[it]
  unchanged := before == after
  if error == null or not unchanged: failures++
  print "$name: $error $(unchanged ? "unchanged" : "CHANGED")"

// Runs a write into an immutable copy-on-write wrapper over program-heap
// bytes: the primitive (C++) copies the bytes and writes the copy.
copy-attack name/string [block]:
  cow/any := #[21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36]
  bytes := backing_ cow
  before := List bytes.size: bytes[it]
  error := catch: block.call cow
  after := List bytes.size: bytes[it]
  unchanged := before == after
  copied := not identical (backing_ cow) bytes
  if error != null or not unchanged or not copied: failures++
  print "$name: $error $(unchanged ? "unchanged" : "CHANGED") $(copied ? "copied" : "NOT COPIED")"

main:
  // The program-heap bytes of a literal.
  raw := backing_ #[1, 2, 3, 4, 5, 6, 7, 8]
  // A copy-on-write wrapper over program-heap bytes that claims to be
  // mutable.
  cow/any := #[11, 12, 13, 14, 15, 16, 17, 18]
  cow-raw := backing_ cow
  cow.is-mutable_ = true

  attack "byte_array_at_put raw" raw: byte-array-at-put_ raw 0 99
  attack "byte_array_replace raw" raw: byte-array-replace_ raw 0 #[9, 9] 0 2
  attack "byte_array_replace cow" cow-raw: byte-array-replace_ cow 0 #[9, 9] 0 2
  attack "string_write_to_byte_array raw" raw: string-write-to-byte-array_ "zz" raw 0 2 0
  attack "string_write_to_byte_array cow" cow-raw: string-write-to-byte-array_ "zz" cow 0 2 0
  attack "put_uint_big_endian raw" raw: put-uint-big-endian_ null raw 2 0 0x0505
  attack "put_uint_big_endian cow" cow-raw: put-uint-big-endian_ null cow 2 0 0x0505
  attack "put_uint_little_endian raw" raw: put-uint-little-endian_ null raw 2 0 0x0505
  attack "put_uint_little_endian cow" cow-raw: put-uint-little-endian_ null cow 2 0 0x0505
  attack "put_float_64_little_endian raw" raw: put-float-64-little-endian_ null raw 0 1.5
  attack "put_float_64_little_endian cow" cow-raw: put-float-64-little-endian_ null cow 0 1.5
  attack "put_float_32_little_endian raw" raw: put-float-32-little-endian_ null raw 0 1.5
  attack "put_float_32_little_endian cow" cow-raw: put-float-32-little-endian_ null cow 0 1.5
  attack "byte_zap raw" raw: byte-zap_ raw 3
  attack "byte_zap cow" cow-raw: byte-zap_ cow 3
  attack "blit raw" raw: blit_ raw 1 8 #[1, 1, 1, 1, 1, 1, 1, 1] 1 8 8 null 0 0xff 0
  attack "blit cow" cow-raw: blit_ cow 1 8 #[1, 1, 1, 1, 1, 1, 1, 1] 1 8 8 null 0 0xff 0
  copy-attack "byte_array_replace copy": | c | byte-array-replace_ c 0 #[9, 9] 0 2
  copy-attack "string_write_to_byte_array copy": | c | string-write-to-byte-array_ "zz" c 0 2 0
  copy-attack "put_uint_big_endian copy": | c | put-uint-big-endian_ null c 2 0 0x0505
  copy-attack "put_uint_little_endian copy": | c | put-uint-little-endian_ null c 2 0 0x0505
  copy-attack "put_float_64_little_endian copy": | c | put-float-64-little-endian_ null c 0 1.5
  copy-attack "put_float_32_little_endian copy": | c | put-float-32-little-endian_ null c 0 1.5
  copy-attack "byte_zap copy": | c | byte-zap_ c 3
  // A string literal is no byte array.
  str := "abcdefgh"
  attack "put_uint_big_endian string" raw: put-uint-big-endian_ null str 2 0 0x0505
  // Finalizers: a program-heap object is not registered (the header of a
  // program-heap object is not written).
  attack "add_finalizer string" raw: add-finalizer_ str:: null
  attack "add_finalizer raw" raw: add-finalizer_ raw:: null
  attack "remove_finalizer raw" raw:
    if remove-finalizer_ raw: throw "HAD FINALIZER"
    throw "NOT REGISTERED"
  // A program-heap byte array is no resource proxy.
  attack "timer_arm raw" raw: timer-arm_ raw 1000
  attack "timer_delete raw" raw: timer-delete_ raw raw
  attack "events_read_state raw" raw: events-read-state_ raw raw
  attack "events_unregister raw" raw: events-unregister_ raw raw
  print "$(str == "abcdefgh" ? "string unchanged" : "STRING CHANGED")"
  print "failures: $failures"
