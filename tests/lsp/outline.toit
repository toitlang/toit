// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .outline as prefix

class Class:
/*    @ class: Class */
  constructor:
/*@ constructor: Class.constructor */

  constructor x --named_arg  optional=3 [block] --optional_named=null:
/*@ constructor: Class.constructor x --named-arg optional= [block] --optional-named= */

  constructor.named:
/*@ named constructor: Class.named */

  constructor.named x --named_arg  optional=3 [block] --optional_named=null:
/*@ named constructor: Class.named x --named-arg optional= [block] --optional-named= */

  constructor.factory: return Class
/*@ factory: Class.factory */

  constructor.factory x --named_arg  optional=3 [block] --optional_named=null: return Class
/*@ factory: Class.factory x --named-arg optional= [block] --optional-named= */

  method:
/*@ method: Class.method */

  method x --named_arg  optional=3 [block] --optional_named=null:
/*@ method: Class.method x --named-arg optional= [block] --optional-named= */

  static static_method:
/*       @ static method: Class.static-method */

  static static_method x --named_arg  optional=3 [block] --optional_named=null:
/*       @ static method: Class.static-method x --named-arg optional= [block] --optional-named= */

  field := null
/*@ field: Class.field */

  field2 ::= null
/*@ final field: Class.field2 */

  setter= val:
/*@ setter: Class.setter= val */

  static static_field := null
/*       @ static field: Class.static-field */

  static static_final_field ::= null
/*       @ static final field: Class.static-final-field */

  static STATIC_CONSTANT ::= 499
/*       @ static constant: Class.STATIC-CONSTANT */


abstract class B:
/*             @ abstract class: B */
  abstract abstract_method
/*         @ abstract method: B.abstract-method */

  abstract abstract_method x --named_arg [block]
/*         @ abstract method: B.abstract-method x --named-arg [block] */

interface Interface:
/*        @ interface: Interface */
  interface_method
/*@ interface method: Interface.interface-method */

  interface_method x --named_arg [block]
/*@ interface method: Interface.interface-method x --named-arg [block] */

  static static_method2:
/*       @ static method: Interface.static-method2 */

  static static_method2 x --named_arg  optional=3 [block] --optional_named=null:
/*       @ static method: Interface.static-method2 x --named-arg optional= [block] --optional-named= */

global := 499
/*
@ global: global
*/
final_global ::= {:}
/*
@ final global: final-global
*/
CONSTANT ::= 499
/*
@ constant: CONSTANT
*/

global_function:
/*
@ global function: global-function
*/

global_function x --named_arg  optional=3 [block] --optional_named=null:
/*
@ global function: global-function x --named-arg optional= [block] --optional-named=
*/
