// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

always: fail  // So that we don't need to worry if a test succeeds.

throw exception:  // NO-WARN
rethrow exception trace:  // NO-WARN
lookup-failure_ receiver selector-or-selector-offset:
as-check-failure_ receiver id:
run-global-initializer__ id initializer:
program-failure_ bci:
unreachable:

class SmallArray_:
class LargeArray_:
interface ByteArray:
class ByteArray_:
  constructor len:
class List_:
class ListSlice_:
class string:
class String_:
class StringSlice_:
class StringByteSlice_:
class float:
class LargeInteger_:
class False:
class Null_:
class Object:
  stringify:
class SmallInteger_:
class Task_:
class True:
class LazyInitializer_:
class Tombstone_:
class Map:
class Set:
class Box_:
class __Monitor__:
class bool:
class int:
class Array_:
  constructor len:
class CowByteArray_:
class ByteArraySlice_:

interface Interface_:
mixin Mixin_:
class Class_:
class Stack_:
class Exception_:

__entry__main task:
__entry__spawn task:
__entry__task lambda:

primitive-lookup-failure_ module index:
too-few-code-arguments-failure_ is-block expected provided bci:
uninitialized-global-failure_ global-name:

create-array_ x:
create-array_ x y:
create-array_ x y z:
create-array_ x y z u:

create-byte-array_ x:
create-byte-array_ x y:
create-byte-array_ x y z:

create-list-literal-from-array_ array:
create-cow-byte-array_ byte-array:

identical x y:

lambda__ method arguments arg-count:
class Lambda:

simple-interpolate-strings_ array:
interpolate-strings_ array:
assert_ [cond]:
