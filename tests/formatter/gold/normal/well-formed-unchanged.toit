class Foo:
  x ::= 1
  bar:
    a := x
    return a + 1

main:
  print (Foo).bar
  print 2
