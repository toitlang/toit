class A:
  x := 1
  y := "foo"
  foo [b]: return b.call x
GLOBAL ::= [1, 2.5, "str", #[1, 2, 3], 0x1234_5678_9abc_def0]
lazy := { "a": 1, "b": [3, 4] }
main:
  a := A
  l := :: it + 1
  print (a.foo: it + (l.call 2))
  print GLOBAL
  print lazy
  try:
    throw "x"
  finally:
    print "fin"
