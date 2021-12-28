class A:
  fooX: return 499

bar -> A: return confuse null

foo:
  return bar.fooX

confuse x -> any: return x

main:
  print foo
