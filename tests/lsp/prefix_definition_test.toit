// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// This should not lead to a crash.
class A implements pre.foo:
/*                     ^~~
  []
*/

global := 499

// This should not lead to a crash either
class B implements glob.foo:
/*                      ^~~
  []
*/

class Klass:
/*    @ Klass */

interface Inter:
/*        @ Inter */

class D extends Klass.x:
/*              ^
  [Klass]
*/

class E implements Inter.y:
/*                 ^
  [Inter]
*/

class F extends Klass.:
/*              ^
  + [Klass]
*/

class G implements Inter.:
/*                 ^
  [Inter]
*/
