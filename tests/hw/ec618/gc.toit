// Tests garbage collection on EC618.
// Allocates and drops lots of garbage to exercise the GC.

main:
  test-allocate-strings
  test-allocate-byte-arrays
  test-allocate-lists
  test-nested-allocations
  print "ALL GC TESTS PASSED"

test-allocate-strings:
  // Allocate many strings and let them be collected.
  10000.repeat: | i |
    s := "string number $i with some padding to make it larger"
    if i % 1000 == 0:
      print "  strings: allocated $i"

test-allocate-byte-arrays:
  // Allocate byte arrays of various sizes.
  1000.repeat: | i |
    size := (i * 13) % 1000 + 1
    ba := ByteArray size: it & 0xff
    // Touch the last byte to ensure it's really allocated.
    if ba[size - 1] != (size - 1) & 0xff: throw "byte array corruption"
  print "  byte arrays: OK"

test-allocate-lists:
  // Allocate lists and maps.
  1000.repeat: | i |
    list := List 100: it * i
    map := {:}
    10.repeat: | j | map["key-$j"] = j * i
    if list.size != 100: throw "list size wrong"
    if map.size != 10: throw "map size wrong"
  print "  lists/maps: OK"

test-nested-allocations:
  // Build nested structures and verify them.
  root := []
  100.repeat: | i |
    child := {
      "index": i,
      "data": ByteArray 50: it,
      "name": "child-$i",
    }
    root.add child
  if root.size != 100: throw "nested list size wrong"
  root.do: | child |
    if child["data"].size != 50: throw "child data size wrong"
  print "  nested: OK"
