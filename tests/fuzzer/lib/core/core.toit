// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

always: fail  // So that we don't need to worry if a test succeeds.

throw exception:
rethrow exception trace:
lookup_failure_ receiver selector_or_selector_offset:
as_check_failure_ receiver id:
run_global_initializer_ id initializer:
program_failure_ bci:
unreachable:

class SmallArray_:
class LargeArray_:
interface ByteArray:
class ByteArray_:
  constructor len:
class List_:
class string:
class String_:
class StringSlice_:
class float:
class LargeInteger_:
class False_:
class Null_:
class Object:
class SmallInteger_:
class Task_:
class True_:
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
class Class_:
class Stack_:

__entry__:
__hatch_entry__:
primitive_lookup_failure_ module index:
allocation_failure_ class_name:
too_few_code_arguments_failure_ is_block expected provided bci:
stack_overflow_:
out_of_memory_:
watchdog_:
task_entry_ code:
uninitialized_global_failure_ global_name:

create_array_ x:
create_array_ x y:
create_array_ x y z:
create_array_ x y z u:

create_byte_array_ x:
create_byte_array_ x y:
create_byte_array_ x y z:

create_list_literal_from_array_ array:
create_cow_byte_array_ byte_array:

identical x y:

lambda_ method arguments arg_count:
class Lambda:

simple_interpolate_strings_ array:
interpolate_strings_ array:
assert_ [cond]:
