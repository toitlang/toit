import encoding.tison
import encoding.hex

main:
  m := {:}
  20.repeat: m["k$it"] = it
  values := [
    0, 1, -1, 0x3fff_ffff, -1073741824, 0x7fff_ffff_ffff_ffff, int.MIN,
    1.5, -0.0, float.NAN, float.INFINITY,
    null, true, false,
    "", "hello", "x" * 200, "ünïcödé",
    #[], #[1, 2, 3], (ByteArray 300: it),
    [], [1, [2, [3, [4, [5]]]]], ["a", 1, 2.0, null, #[7]],
    {:}, {"a": 1, "b": [1, 2], "c": {"d": null}}, {1: 2, 3: 4},
    (List 100: it), m,
  ]
  values.do:
    print (hex.encode (tison.encode it))
