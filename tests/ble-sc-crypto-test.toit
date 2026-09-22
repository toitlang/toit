// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.sc-crypto as sc
import encoding.hex as hex
import expect show *
import system

// Core 6.3 Vol 3 Part H, Appendix D.2–D.5. These are public test-vector
// values, not operational keys. Hex strings preserve the printed MSB-first order.
main:
  u := hex.decode "20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6"
  v := hex.decode "55188b3d32f6bb9a900afcfbeed4e72a59cb9ac2f19d7cfb6b4fdd49f47fc5fd"
  x := hex.decode "d5cb8454d177733effffb2ec712baeab"
  y := hex.decode "a6e8e7cc25a75f6e216583f7ff3dc4cf"
  w := hex.decode "ec0234a357c8ad05341010a60a397d9b99796b13b4f866f1868d34f373bfa698"
  a := hex.decode "0056123737bfce"
  b := hex.decode "00a713702dcfc1"
  r := hex.decode "12a3343bb453bb5408da42d20c2d0fc8"
  iocap := #[1, 1, 2]
  expected-mac := hex.decode "2965f176a1084a02fd3f6a20ce636e20"
  expected-ltk := hex.decode "6986791169d7cd23980522b594750a38"
  inputs := [u, v, x, y, w, a, b, r, iocap]
  snapshots := inputs.map: it.copy
  confirm := sc.f4 u v x 0
  expect-equals (hex.decode "f2c916f107a9bd1cf1eda1bea974872d") confirm
  keys := sc.f5 w x y a b
  expect-equals expected-mac keys.mac-key
  expect-equals expected-ltk keys.ltk
  check := sc.f6 keys.mac-key x y r iocap a b
  expect-equals (hex.decode "e3c473989cd0e8c5d26c0b09da958f61") check
  expect (sc.verify-check check check.copy)
  16.repeat: | index/int |
    changed := check.copy
    changed[index] ^= 1
    expect (not (sc.verify-check check changed))
  expect-throw "INVALID_ARGUMENT": sc.verify-check check check[..15]
  expect-equals 0x2f9ed5ba (sc.g2 u v x y)
  expect-equals 938554 ((sc.g2 u v x y) % 1_000_000)
  system.process-stats --gc
  inputs.size.repeat: expect-equals snapshots[it] inputs[it]
  expect-equals expected-ltk keys.ltk
  // Derivations must not share mutable output storage or overwrite older keys.
  another := sc.f5 w x y a b
  keys.mac-key[0] ^= 0xff
  expect-equals expected-mac another.mac-key
  expect-equals expected-ltk keys.ltk
  [0, 15, 17, 31, 33].do: | length/int |
    expect-throw "INVALID_ARGUMENT": sc.f4 (ByteArray length) v x 0
    expect-throw "INVALID_ARGUMENT": sc.f5 (ByteArray length) x y a b
  expect-throw "INVALID_ARGUMENT": sc.f4 u v x 256
  expect-throw "INVALID_ARGUMENT": sc.f4 u v x -1
  expect-throw "INVALID_ARGUMENT": sc.f4 u v #[] 0
  expect-throw "INVALID_ARGUMENT": sc.f5 w x y a[1..] b
  expect-throw "INVALID_ARGUMENT": sc.f5 w x y #[2, 0, 0, 0, 0, 0, 0] b
  expect-throw "INVALID_ARGUMENT": sc.f6 expected-mac x y r #[1, 2] a b
  expect-throw "INVALID_ARGUMENT": sc.g2 u v x #[]
