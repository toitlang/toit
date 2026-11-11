// Observation (NOT a sandbox breach). Signed-overflow UB in the legacy C++
// integer primitives, reachable only on the TRUSTED execution path.
//
// Run TRUSTED on an ASan+UBSan build this triggers a signed-integer-overflow
// UBSan report in C++ large_integer_add (src/primitive_core.cc:931-932).
// Run UNTRUSTED, the identical program is executed by the proven Rust core
// (verified/core, wrapping arithmetic) with NO undefined behaviour -- so the
// sandbox's verified core actually removes UB that the legacy C++ integer
// primitives still carry. Same effect exists for smi_multiply (line 754,
// `other << 1`, signed left shift of a negative value).
//
//   trusted:   build/asan/sdk/lib/toit/bin/toit.run              trusted-bigint-ub.toit
//   untrusted: build/asan/sdk/lib/toit/bin/toit.run --untrusted  trusted-bigint-ub.toit
main:
  a := 0x7000_0000_0000_0000
  b := 0x7000_0000_0000_0000
  print (a + b)
