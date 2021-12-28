// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .outline as prefix

class Class:
/*    @ class: Class */
  constructor:
/*@ constructor: Class.constructor */

  constructor x --named_arg  optional=3 [block] --optional_named=null:
/*@ constructor: Class.constructor x --named_arg optional= [block] --optional_named= */

  constructor.named:
/*@ named constructor: Class.named */

  constructor.named x --named_arg  optional=3 [block] --optional_named=null:
/*@ named constructor: Class.named x --named_arg optional= [block] --optional_named= */

  constructor.factory: return Class
/*@ factory: Class.factory */

  constructor.factory x --named_arg  optional=3 [block] --optional_named=null: return Class
/*@ factory: Class.factory x --named_arg optional= [block] --optional_named= */

  method:
/*@ method: Class.method */

  method x --named_arg  optional=3 [block] --optional_named=null:
/*@ method: Class.method x --named_arg optional= [block] --optional_named= */

  static static_method:
/*       @ static method: Class.static_method */

  static static_method x --named_arg  optional=3 [block] --optional_named=null:
/*       @ static method: Class.static_method x --named_arg optional= [block] --optional_named= */

  field := null
/*@ field: Class.field */

  field2 ::= null
/*@ final field: Class.field2 */

  setter= val:
/*@ setter: Class.setter= val */

  static static_field := null
/*       @ static field: Class.static_field */

  static static_final_field ::= null
/*       @ static final field: Class.static_final_field */

  static STATIC_CONSTANT ::= 499
/*       @ static constant: Class.STATIC_CONSTANT */


abstract class B:
/*             @ abstract class: B */
  abstract abstract_method
/*         @ abstract method: B.abstract_method */

  abstract abstract_method x --named_arg [block]
/*         @ abstract method: B.abstract_method x --named_arg [block] */

interface Interface:
/*        @ interface: Interface */
  interface_method
/*@ interface method: Interface.interface_method */

  interface_method x --named_arg [block]
/*@ interface method: Interface.interface_method x --named_arg [block] */

  static static_method2:
/*       @ static method: Interface.static_method2 */

  static static_method2 x --named_arg  optional=3 [block] --optional_named=null:
/*       @ static method: Interface.static_method2 x --named_arg optional= [block] --optional_named= */

global := 499
/*
@ global: global
*/
final_global ::= {:}
/*
@ final global: final_global
*/
CONSTANT ::= 499
/*
@ constant: CONSTANT
*/

global_function:
/*
@ global function: global_function
*/

global_function x --named_arg  optional=3 [block] --optional_named=null:
/*
@ global function: global_function x --named_arg optional= [block] --optional_named=
*/
