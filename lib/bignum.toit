// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.hex
import io show BIG-ENDIAN

BIGNUM-ADD_ ::= 0
BIGNUM-SUB_ ::= 1
BIGNUM-MUL_ ::= 2
BIGNUM-DIV_ ::= 3
BIGNUM-MOD_ ::= 4

/**
An arbitrary-precision integer type.
# Note
Operations are not constant-time, so this library is not suitable for many
  cryptographic tasks.
# Note
Even on host machines you may get out-of-memory errors for very large numbers.
  The underlying MbedTLS library is compiled with a maximum number of base-256
  digits, often 10_000.
*/
class Bignum:
  negative_/bool := ?
  limbs_/ByteArray := ?

  constructor.with-bytes .negative_/bool .limbs_/ByteArray:

  constructor.hex data/string:
    if data[0] == '-':
      negative_ = true
      data = data[1..]
    else:
      negative_ = false
    limbs_ = hex.decode data

  static int-to-array_ i/int -> ByteArray:
    result := ByteArray 8
    BIG-ENDIAN.put-int64 result 0 i
    return result

  trans-other_ other/any -> Bignum:
    if other is int:
      other = Bignum.with-bytes
          other < 0
          int-to-array_ other.abs
    else if other is not Bignum:
      throw "WRONG_OBJECT_TYPE"
    return other

  basic-operator_ operation/int other/any:
    other = trans-other_ other
    result :=  bignum-operator_ operation negative_ limbs_ other.negative_ other.limbs_
    return Bignum.with-bytes result[0] result[1]

  operator + other -> Bignum:
    return basic-operator_ BIGNUM-ADD_ other

  operator - other -> Bignum:
    return basic-operator_ BIGNUM-SUB_ other

  operator * other -> Bignum:
    return basic-operator_ BIGNUM-MUL_ other

  operator / other -> Bignum:
    return basic-operator_ BIGNUM-DIV_ other

  operator % other -> Bignum:
    return basic-operator_ BIGNUM-MOD_ other

  operator == other -> bool:
    other = trans-other_ other

    if negative_ != other.negative_:
      return false

    m := min limbs_.size other.limbs_.size
    cut1 := limbs_.size - m
    cut2 := other.limbs_.size - m
    // Check common bytes for equality.
    if limbs_[cut1..] != other.limbs_[cut2..]:
      return false
    // Check leading bytes for zero.
    cut1.repeat: if limbs_[it] != 0: return false
    cut2.repeat: if other.limbs_[it] != 0: return false
    return true

  stringify -> string:
    s := negative_ ? "-0x" : "0x"
    s += hex.encode limbs_
    return s

mod-exp A/Bignum B/Bignum C/Bignum -> Bignum:
  result := bignum-exp-mod_ A.negative_ A.limbs_ B.negative_ B.limbs_ C.negative_ C.limbs_
  return Bignum.with-bytes result[0] result[1]

bignum-operator_ operator-id a-sign a-limbs b-sign b-limbs:
  #primitive.bignum.binary-operator

bignum-exp-mod_ a-sign a-limbs b-sign b-limbs c-sign c-limbs:
  #primitive.bignum.exp-mod
