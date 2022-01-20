// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

monitor A extends B:

interface I extends A:

class B extends I:
  constructor:
    unresolved

class C extends __Monitor__:
  constructor:
    unresolved

class D extends E implements F G H B C:
  constructor:
    unresolved

class Cycle1 extends Cycle3:
class Cycle2 extends Cycle1:
class Cycle3 extends Cycle1:

interface ICycle1 extends ICycle3:
interface ICycle2 extends ICycle1:
interface ICycle3 extends ICycle2:

class CCycle1 implements ICycle1:

interface ICycle4 implements ICycle4:

interface ICycle5 extends ICycle6:
interface ICycle6 implements ICycle5:

interface ICycle7 implements ICycle8:
interface ICycle8 implements ICycle7:

main:
  unresolved
