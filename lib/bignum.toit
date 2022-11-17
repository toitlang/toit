// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.hex

BIGNUM_ADD_ ::= 0
BIGNUM_SUB_ ::= 1
BIGNUM_MUL_ ::= 2
BIGNUM_DIV_ ::= 3
BIGNUM_MOD_ ::= 4

class Bignum:
  sign_/bool := ?
  limbs_/ByteArray := ?

  constructor .sign_/bool .limbs_/ByteArray:

  constructor.from_string data/string:
    if data[0] == '-':
      sign_ = true
      data = data[1..]
    else:
      sign_ = false
    
    if data.size & 0x1 !=0:
      data = "0" + data
    
    limbs_ = hex.decode data

  int_to_arry_ i/int -> ByteArray:
    return #[(i >>  0) & 0xff, (i >>  8) & 0xff,
             (i >> 16) & 0xff, (i >> 24) & 0xff]
  
  trans_other_ other/any -> Bignum:
    if other is int:
      other = Bignum
          other < 0
          int_to_arry_ other.abs
    else if other is not Bignum:
      throw "$(other.type) is not supported"
    
    return other

  basic_operator_ operation/int sign/bool limbs/ByteArray other/any:
    other = trans_other_ other
    result :=  bignum_operator_ operation sign limbs other.sign_ other.limbs_
    return Bignum result[0] result[1]

  operator + other -> Bignum:
    return basic_operator_ BIGNUM_ADD_ sign_ limbs_ other

  operator - other -> Bignum:
    return basic_operator_ BIGNUM_SUB_ sign_ limbs_ other

  operator * other -> Bignum:
    return basic_operator_ BIGNUM_MUL_ sign_ limbs_ other

  operator / other -> Bignum:
    return basic_operator_ BIGNUM_DIV_ sign_ limbs_ other

  operator % other -> Bignum:
    return basic_operator_ BIGNUM_MOD_ sign_ limbs_ other
  
  operator == other -> bool:
    other = trans_other_ other
    
    if sign_ != other.sign_:
      return false

    return limbs_ == other.limbs_
  
  stringify -> string:
    s := sign_ ? "-" : "" 
    s += hex.encode limbs_
    return s

mod_exp A/Bignum B/Bignum C/Bignum -> Bignum:
  result := bignum_exp_mod_ A.sign_ A.limbs_ B.sign_ B.limbs_ C.sign_ C.limbs_
  return Bignum result[0] result[1]

bignum_operator_ operator_id a_sign a_limbs b_sign b_limbs:
  #primitive.bignum.operator

bignum_exp_mod_ a_sign a_limbs b_sign b_limbs c_sign c_limbs:
  #primitive.bignum.exp_mod
