// Red-team: signed left-shift of a negative value in the C++ smi_multiply
// primitive (src/primitive_core.cc:754, `other << 1`). Reachable from an
// untrusted format-2 container: the verified Rust `ints` port delegates the
// overflowing smi*smi case to the C++ primitive, which left-shifts the
// (possibly negative) second operand. Undefined behaviour in C++; on a build
// with -fno-sanitize-recover=undefined the VM process aborts.
// Run: toit.run --untrusted smi-mul-ub.toit   (on an ASan+UBSan build)

mul a b:
  return a * b

main:
  neg := 0 - 0x7fff_ffff          // -2147483647, the negative second operand
  receivers := [0x1_0000_0000, 0x7fff_ffff, 0x4000_0000, 0x3fff_ffff_ffff_ffff,
                0x2000_0000_0000_0000, 0x1234_5678_9abc]
  1000.repeat:
    receivers.do: | r |
      catch: mul r neg
      catch: mul neg r
    // heap churn so the large-integer allocation path varies
    ByteArray 4096
  print "smi-mul-ub done"
