// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .semantic-tokens2 show SomeClass
/*      ^~~~~~~~~~~~~~~~
  namespace
*/

import core.string as str
/*          ^~~~~~
  namespace
*/

import core.string as str2
/*                    ^~~~
  namespace
  definition
*/

import .semantic-tokens2 show SomeClass
/*                            ^~~~~~~~~
  class
*/

import .semantic-tokens2 show SomeAbstractClass
/*                            ^~~~~~~~~~~~~~~~~
  class
  abstract
*/

import .semantic-tokens2 show SomeInterface
/*                            ^~~~~~~~~~~~~
  interface
  abstract
*/

import core show List
/*               ^~~~
  class
  abstract, defaultLibrary
*/

class SomeOtherClass:
/*    ^~~~~~~~~~~~~~
  class
  definition
*/

abstract class AnotherAbstractClass:
/*             ^~~~~~~~~~~~~~~~~~~~
  class
  abstract, definition
*/

interface AnotherInterface:
/*        ^~~~~~~~~~~~~~~~
  interface
  abstract, definition
*/

mixin SomeMixin:
/*    ^~~~~~~~~
  class
  definition
*/

monitor SomeMonitor:
/*      ^~~~~~~~~~~
  class
  definition
*/
