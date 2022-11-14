// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

class Bignum:
  bignum_ := ?

  constructor data/ByteArray:
    bignum_ = bignum_init_ data

  constructor.from_string data/string:
    bignum_ = bignum_init_from_string_ data

  constructor.from_bignum bignum/any:
    bignum_ = bignum

  bytes -> ByteArray:
    return bignum_bytes_ bignum_

  stringify -> string:
    return bignum_string_ bignum_

  operator + other/Bignum:
    return Bignum.from_bignum (bignum_add_ bignum_ other.bignum_)

  operator - other/Bignum:
    return Bignum.from_bignum (bignum_subtract_ bignum_ other.bignum_)

  operator * other/Bignum:
    return Bignum.from_bignum (bignum_multiply_ bignum_ other.bignum_)

  operator / other/Bignum:
    return Bignum.from_bignum (bignum_divide_ bignum_ other.bignum_)

  operator % other/Bignum:
    return Bignum.from_bignum (bignum_mod_ bignum_ other.bignum_)
  
  operator == other/Bignum:
    return bignum_equal_ bignum_ other.bignum_

mod_exp A/Bignum E/Bignum N/Bignum -> Bignum:
  return Bignum.from_bignum (bignum_exp_mod_ A.bignum_ E.bignum_ N.bignum_)

bignum_init_ data:
  #primitive.bignum.init

bignum_init_from_string_ string:
  #primitive.bignum.init_from_string

bignum_bytes_ bignum:
  #primitive.bignum.bytes

bignum_string_ bignum:
  #primitive.bignum.string

bignum_equal_ A B:
  #primitive.bignum.equal

bignum_add_ A B:
  #primitive.bignum.add

bignum_subtract_ A B:
  #primitive.bignum.subtract

bignum_multiply_ A B:
  #primitive.bignum.multiply

bignum_divide_ A B:
  #primitive.bignum.divide

bignum_mod_ A B:
  #primitive.bignum.mod

bignum_exp_mod_ A E N:
  #primitive.bignum.exp_mod
