// tests/debugger/targets/count_to.toit
main:
  result := count-to 5
  print "result=$result"

count-to n/int -> int:
  sum := 0
  for i := 0; i < n; i++:
    sum += i
  return sum
