// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .outline as prefix

class Class:
/*    @ class: Class */

  constructor:
/*@ constructor: Class.constructor */

  constructor x --named-arg  optional=3 [block] --optional-named=null:
/*@ constructor: Class.constructor x --named-arg optional= [block] --optional-named= */

  constructor.named:
/*@ named constructor: Class.named */

  constructor.named x --named-arg  optional=3 [block] --optional-named=null:
/*@ named constructor: Class.named x --named-arg optional= [block] --optional-named= */

  constructor.factory: return Class
/*@ factory: Class.factory */

  constructor.factory x --named-arg  optional=3 [block] --optional-named=null: return Class
/*@ factory: Class.factory x --named-arg optional= [block] --optional-named= */

  method:
/*@ method: Class.method */

  method x --named-arg  optional=3 [block] --optional-named=null:
/*@ method: Class.method x --named-arg optional= [block] --optional-named= */

  static static-method:
/*       @ static method: Class.static-method */

  static static-method x --named-arg  optional=3 [block] --optional-named=null:
/*       @ static method: Class.static-method x --named-arg optional= [block] --optional-named= */

  field := null
/*@ field: Class.field */

  field2 ::= null
/*@ final field: Class.field2 */

  setter= val:
/*@ setter: Class.setter= val */

  static static-field := null
/*       @ static field: Class.static-field */

  static static-final-field ::= null
/*       @ static final field: Class.static-final-field */

  static STATIC-CONSTANT ::= 499
/*       @ static constant: Class.STATIC-CONSTANT */


abstract class B:
/*             @ abstract class: B */

  abstract abstract-method
/*         @ abstract method: B.abstract-method */

  abstract abstract-method x --named-arg [block]
/*         @ abstract method: B.abstract-method x --named-arg [block] */

interface Interface:
/*        @ interface: Interface */

  interface-method
/*@ interface method: Interface.interface-method */

  constructor:
/*@ constructor: Interface.constructor */
    return InterfaceImpl

  constructor.named:
/*@ named constructor: Interface.named */
    return InterfaceImpl


  interface-method x --named-arg [block]
/*@ interface method: Interface.interface-method x --named-arg [block] */

  static static-method2:
/*       @ static method: Interface.static-method2 */

  static static-method2 x --named-arg  optional=3 [block] --optional-named=null:
/*       @ static method: Interface.static-method2 x --named-arg optional= [block] --optional-named= */

class InterfaceImpl implements Interface:
/*    @ class: InterfaceImpl */

  interface-method:
/*@ interface method: InterfaceImpl.interface-method */

  interface-method x --named-arg [block]:
/*@ interface method: InterfaceImpl.interface-method x --named-arg [block] */

mixin Mix1:
/*    @ mixin: Mix1 */

  static static-method:
/*       @ static method: Mix1.static-method */


global := 499
/*
@ global: global
*/
final-global ::= {:}
/*
@ final global: final-global
*/
CONSTANT ::= 499
/*
@ constant: CONSTANT
*/

global-function:
/*
@ global function: global-function
*/

global-function x --named-arg  optional=3 [block] --optional-named=null:
/*
@ global function: global-function x --named-arg optional= [block] --optional-named=
*/
