main:
  // A wide list uses a small number of packed rows.
  list := [aaaaaaaaaaa, bbbbbbbbbbb, ccccccccccc, ddddddddddd, eeeeeeeeeee, fffffffffff, ggggggggggg, hhhhhhhh]

  // Sets use the same packed-row heuristic.
  set := {aaaaaaaaaaa, bbbbbbbbbbb, ccccccccccc, ddddddddddd, eeeeeeeeeee, fffffffffff, ggggggggggg, hhhhhhhh}

  // Map literal: each key/value pair on its own line.
  map := {kkkkkkkkkkk: vvvvvvvvvvv, kkkkkkkkkk2: vvvvvvvvvv2, kkkkkkkkkk3: vvvvvvvvvv3, kkkkkkkkkk4: vvvvvvvvvv4}

  // A dense byte array avoids one line per byte.
  bytes := #[0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb]

  // return-wrapped.
  return [aaaaaaaaaaa, bbbbbbbbbbb, ccccccccccc, ddddddddddd, eeeeeeeeeee, fffffffffff, ggggggggggg, hhhhhhhh]

aaaaaaaaaaa := 0
bbbbbbbbbbb := 0
ccccccccccc := 0
ddddddddddd := 0
eeeeeeeeeee := 0
fffffffffff := 0
ggggggggggg := 0
hhhhhhhh := 0
kkkkkkkkkkk := 0
kkkkkkkkkk2 := 0
kkkkkkkkkk3 := 0
kkkkkkkkkk4 := 0
vvvvvvvvvvv := 0
vvvvvvvvvv2 := 0
vvvvvvvvvv3 := 0
vvvvvvvvvv4 := 0
