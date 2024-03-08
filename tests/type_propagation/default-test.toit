main:
  foo false
  foo2 false

bar: return true

foo x=bar:
  if x:
    print x

foo2 x=true:
  if x:
    print x
