// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io.stdio
import system.storage
import .storage-common show verify-persistent

BUCKET ::= "toit-rp2040-test/interruption"
CONTROL ::= "toit-rp2040-test/interruption-control"

main:
  while true:
    print "storage-interruption: READY"
    command := stdio.stdin.read-byte
    if command == 'v':
      expected := stdio.stdin.read-byte
      bucket := storage.Bucket.open --flash BUCKET
      try:
        if expected == 0:
          expect-equals null (bucket.get "value")
        else:
          expect-equals (ByteArray 4097 --initial=expected) bucket["value"]
          bucket.remove "value"
      finally:
        bucket.close
      storage.Region.delete --flash CONTROL
      verify-persistent
      print "storage-interruption: PASS value=$expected and unrelated data intact"
    else:
      expect (command >= '1' and command <= '6')
      bucket := storage.Bucket.open --flash BUCKET
      try:
        bucket["value"] = ByteArray 4097 --initial=17
        control := storage.Region.open --flash CONTROL --capacity=256
        try:
          control.erase
          bytes := ByteArray 16
          bytes.replace 0 "TOIT-RP2040-CUT"
          bytes[15] = command - '0'
          control.write --at=0 bytes
        finally:
          control.close
        // The test-only backend interrupts this replacement at the chosen
        // page/header/erase boundary. An ordinary image must fail this test.
        if command >= '5':
          bucket.remove "value"
        else:
          bucket["value"] = ByteArray 4097 --initial=34
        throw "Storage fault injection did not run"
      finally:
        bucket.close
