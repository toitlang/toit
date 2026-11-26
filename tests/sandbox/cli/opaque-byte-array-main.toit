// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. The byte arrays the verified core's heap
// model treats as opaque: one a transferring send neutered (its bytes went
// to the receiver: raw bytes at a null address, length 0) and a resource
// proxy (an external byte array tagged with a resource type). The Rust
// ports of byte_array_is_raw_bytes, byte_array_length, byte_array_at and
// byte_array_at_put read their tag and length as the C++ did, the blob
// primitives take a neutered array as the empty blob and refuse a proxy as
// the C++ decoders do; none falls back to the C++.

import rpc
import rpc.broker show RpcBroker

PROCEDURE-KEEP/int ::= 500

byte-array-is-raw-bytes_ bytes:
  #primitive.core.byte-array-is-raw-bytes

byte-array-length_ bytes:
  #primitive.core.byte-array-length

byte-array-at_ bytes index:
  #primitive.core.byte-array-at

byte-array-at-put_ bytes index value:
  #primitive.core.byte-array-at-put

blob-index-of_ bytes byte from to:
  #primitive.core.blob-index-of

blob-equals_ a b:
  #primitive.core.blob-equals

string-rune-count_ bytes:
  #primitive.core.string-rune-count

size-of-json-number_ bytes offset:
  #primitive.core.size-of-json-number

compare-simple-json-string_ bytes offset found:
  #primitive.core.compare-simple-json-string

timer-init_:
  #primitive.timer.init

probe name/string bytes:
  raw := catch: byte-array-is-raw-bytes_ bytes
  raw = raw or (byte-array-is-raw-bytes_ bytes)
  length := catch: byte-array-length_ bytes
  length = length or (byte-array-length_ bytes)
  at := catch: byte-array-at_ bytes 0
  put := catch: byte-array-at-put_ bytes 0 7
  index := catch: blob-index-of_ bytes 0 0 0
  index = index or (blob-index-of_ bytes 0 0 0)
  equals := catch: blob-equals_ bytes #[]
  equals = equals or (blob-equals_ bytes #[])
  print "$name: raw=$raw length=$length at=$at put=$put index-of=$index equals-empty=$equals"
  runes := catch: string-rune-count_ bytes
  runes = runes or (string-rune-count_ bytes)
  number := catch: size-of-json-number_ bytes 0
  json := catch: compare-simple-json-string_ bytes 0 "x"
  json = json or (compare-simple-json-string_ bytes 0 "x")
  print "$name: runes=$runes json-number=$number json-string=$json"

main:
  broker := RpcBroker
  broker.install
  broker.register-procedure PROCEDURE-KEEP:: | bytes | null
  // Large byte arrays have an external backing store the process owns; a
  // send transfers it and neuters the sender's array.
  big := ByteArray 100000
  rpc.invoke Process.current.id PROCEDURE-KEEP big
  probe "neutered" big
  proxy := timer-init_
  probe "proxy" proxy
  print "done"
