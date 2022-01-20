// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  operator == other bad:
    unresolved
  operator < other bad:
    unresolved
  operator <= other bad:
    unresolved
  operator >= other bad:
    unresolved
  operator > other bad:
    unresolved
  operator + other bad:
    unresolved
  operator - other bad:
    unresolved
  operator * other bad:
    unresolved
  operator / other bad:
    unresolved
  operator % other bad:
    unresolved
  operator ~ bad:
    unresolved
  operator & other bad:
    unresolved
  operator | other bad:
    unresolved
  operator ^ other bad:
    unresolved
  operator << other bad:
    unresolved
  operator >> other bad:
    unresolved
  operator >>> other bad:
    unresolved

class B:
  operator ==:
    unresolved
  operator <:
    unresolved
  operator <=:
    unresolved
  operator >=:
    unresolved
  operator >:
    unresolved
  operator +:
    unresolved
  operator -:
    unresolved
  operator *:
    unresolved
  operator /:
    unresolved
  operator %:
    unresolved
  operator &:
    unresolved
  operator |:
    unresolved
  operator ^:
    unresolved
  operator <<:
    unresolved
  operator >>:
    unresolved
  operator >>>:
    unresolved

  operator []:
    unresolved

  operator []=:
    unresolved

  operator []= x:
    unresolved

class C:
  operator == other [bad]:
    unresolved
  operator < other [bad]:
    unresolved
  operator <= other [bad]:
    unresolved
  operator >= other [bad]:
    unresolved
  operator > other [bad]:
    unresolved
  operator + other [bad]:
    unresolved
  operator - other [bad]:
    unresolved
  operator * other [bad]:
    unresolved
  operator / other [bad]:
    unresolved
  operator % other [bad]:
    unresolved
  operator ~ [bad]:
    unresolved
  operator & other [bad]:
    unresolved
  operator | other [bad]:
    unresolved
  operator ^ other [bad]:
    unresolved
  operator << other [bad]:
    unresolved
  operator >> other [bad]:
    unresolved
  operator >>> other [bad]:
    unresolved

class D:
  operator == other bad=null:
    unresolved
  operator < other bad=null:
    unresolved
  operator <= other bad=null:
    unresolved
  operator >= other bad=null:
    unresolved
  operator > other bad=null:
    unresolved
  operator + other bad=null:
    unresolved
  operator - other bad=null:
    unresolved
  operator * other bad=null:
    unresolved
  operator / other bad=null:
    unresolved
  operator % other bad=null:
    unresolved
  operator ~ bad=null:
    unresolved
  operator & other bad=null:
    unresolved
  operator | other bad=null:
    unresolved
  operator ^ other bad=null:
    unresolved
  operator << other bad=null:
    unresolved
  operator >> other bad=null:
    unresolved
  operator >>> other bad=null:
    unresolved

class E:
  operator == other --bad:
    unresolved
  operator < other --bad:
    unresolved
  operator <= other --bad:
    unresolved
  operator >= other --bad:
    unresolved
  operator > other --bad:
    unresolved
  operator + other --bad:
    unresolved
  operator - other --bad:
    unresolved
  operator * other --bad:
    unresolved
  operator / other --bad:
    unresolved
  operator % other --bad:
    unresolved
  operator ~ --bad:
    unresolved
  operator & other --bad:
    unresolved
  operator | other --bad:
    unresolved
  operator ^ other --bad:
    unresolved
  operator << other --bad:
    unresolved
  operator >> other --bad:
    unresolved
  operator >>> other --bad:
    unresolved

  operator []= --bad:
    unresolved

class F:
  operator == other [--bad]:
    unresolved
  operator < other [--bad]:
    unresolved
  operator <= other [--bad]:
    unresolved
  operator >= other [--bad]:
    unresolved
  operator > other [--bad]:
    unresolved
  operator + other [--bad]:
    unresolved
  operator - other [--bad]:
    unresolved
  operator * other [--bad]:
    unresolved
  operator / other [--bad]:
    unresolved
  operator % other [--bad]:
    unresolved
  operator ~ [--bad]:
    unresolved
  operator & other [--bad]:
    unresolved
  operator | other [--bad]:
    unresolved
  operator ^ other [--bad]:
    unresolved
  operator << other [--bad]:
    unresolved
  operator >> other [--bad]:
    unresolved
  operator >>> other [--bad]:
    unresolved

main:
