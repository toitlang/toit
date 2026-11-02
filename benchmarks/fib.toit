// Provenance: Written for this project.

fib n:
  if n <= 2: return n
  return (fib n - 1) + (fib n - 2)
main:
  print (fib 40)
