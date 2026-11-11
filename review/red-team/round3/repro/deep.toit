foo x/int -> int:
  return 1 + (foo x + 1)
main:
  foo 0
