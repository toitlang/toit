// tests/debugger/targets/call_in_loop.toit
//
// Unlike count_to.toit (whose loop body lowers to smi intrinsics with no Toit
// call frame), this target's loop body invokes a real Toit method (`helper`),
// so it exercises the difference between `dbg:over` (skip the callee frame) and
// `dbg:step` (descend into it).
main:
  result := run-loop 3
  print "result=$result"

helper x/int -> int:
  return x + 1

run-loop n/int -> int:
  acc := 0
  for i := 0; i < n; i++:
    acc += helper i
  return acc
