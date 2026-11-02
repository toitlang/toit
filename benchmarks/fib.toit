// Provenance: Written for this project.

fib n:
  if n <= 2: return n
  return (fib n - 1) + (fib n - 2)
main:
  start := Time.monotonic-us
  r := fib 40
  print "toit interpreter fib(40) = $r  $(((Time.monotonic-us - start) / 1000)) ms"
