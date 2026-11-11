// Red-team: hammer the C++ bitmap.blit primitive (allowed for untrusted)
// with adversarial arguments, including slices as dest, aliasing, extreme
// strides, and lookup tables. Run under ASan: any OOB read/write is a
// sandbox escape (the verified core assumes C++ prims conform to prim_default).
// Usage: toit.run --untrusted blit-attack.toit

blit_ dest dps dls src sps sls ppl lut shift mask op:
  #primitive.bitmap.blit: | error | return error

byte-zap_ bytes value:
  #primitive.bitmap.byte-zap: | error | return error

run dest dps dls src sps sls ppl lut shift mask op:
  r := catch: blit_ dest dps dls src sps sls ppl lut shift mask op
  return r

main:
  dest := ByteArray 64
  src := ByteArray 64 --initial=0xAB
  big-lut := ByteArray 256 --initial=1
  strides := [0 - 0x81, 0 - 0x80, -1, 0, 1, 2, 0x7f, 0x80, 0x81, 0x7fffff, 0x800000, 0 - 0x800000, 0x7fffffff, 0 - 0x7fffffff, 0x100000000]
  ppls := [-1, 0, 1, 2, 63, 64, 65, 0x7fffff, 0x800000, 0x7fffffff, 0x100000000]
  ops := [0, 1, 2, 3, 4, 5, 6, -1, 100]
  count := 0
  strides.do: | dps |
    strides.do: | sps |
      ppls.do: | ppl |
        ops.do: | op |
          run dest dps (ppl * dps.abs) src sps (ppl * sps) ppl null 0 0xff op
          run dest dps (ppl * dps.abs) src sps (ppl * sps) ppl big-lut 7 0xffff op
          // aliasing: dest == src
          run dest dps 1 dest sps 1 ppl null 3 0xff op
          // slice as dest
          run dest[1..40] dps 1 src sps 1 ppl null 0 0xff op
          // zero line strides (unbounded-work guard)
          run dest dps 0 src sps 0 ppl null 0 0xff op
          count += 5
  // byte-zap on slices and aliases
  byte-zap_ dest[3..30] 0x55
  byte-zap_ dest 0
  print "done: $count blit calls"
