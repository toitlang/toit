interface I:
  /** Doc for I.foo */
  foo

class A implements I:
  /** Doc for A.foo */
  foo: return 42

main:
  i/I := A
  i.foo
  /*^
Doc for I.foo
  */

  a := A
  a.foo
  /*^
Doc for A.foo
  */
