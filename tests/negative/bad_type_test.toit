import http as prefix

foo -> extends: return unresolved
foo x -> prefix.implements: return unresolved
bar -> extends.A: return unresolved
bar x -> prefix.implements.A: return unresolved

class A extends extends:
class B extends implements:

class A2 extends prefix.extends.A:
class B2 extends prefix.implements.B:

main:
  foo
  foo 499
