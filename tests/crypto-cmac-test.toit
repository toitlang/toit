// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can be
// found in the tests/LICENSE file.

import crypto.cmac show cmac
import encoding.hex as hex
import expect show *

main:
  key := hex.decode "2b7e151628aed2a6abf7158809cf4f3c"
  verify_ key "" "bb1d6929e95937287fa37d129b756746"
  verify_ key
      "6bc1bee22e409f96e93d7e117393172a"
      "070a16b46b4d4144f79bdd9dd04a287c"
  verify_ key
      "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411"
      "dfa66747de9ae63030ca32611497c827"
  verify_ key
      "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
      "51f0bebf7e3b9d92fc49741779363cfe"

verify_ -> none
    key/ByteArray
    message/string
    expected/string:
  expect-equals (hex.decode expected) (cmac --key=key (hex.decode message))
