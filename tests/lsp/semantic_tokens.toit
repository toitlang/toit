// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .semantic_tokens2 show SomeClass
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

import .semantic_tokens2 show SomeClass
/*                            ^~~~~~~~~
  class
*/

import .semantic_tokens2 show SomeAbstractClass
/*                            ^~~~~~~~~~~~~~~~~
  class
  abstract
*/

import .semantic_tokens2 show SomeInterface
/*                            ^~~~~~~~~~~~~
  interface
  abstract
*/

import core show List
/*               ^~~~
  class
  abstract, defaultLibrary
*/
