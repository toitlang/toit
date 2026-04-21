main:
  // Multi-line list with >=2 elements: stays broken.
  items := [
    first_thing,
    second_thing,
    third_thing,
  ]
  // Multi-line map with >=2 entries: stays broken.
  config := {
    KEY1: value_a,
    KEY2: value_b,
  }
  // Single-element list: collapses.
  singleton := [
    only_one,
  ]
  // Flat source stays flat.
  pair := [a, b]
  // Nested multi-line multi-element collection: the outer expression
  // would otherwise fit flat, but the inner list's layout is preserved.
  wrapped := [
    [
      inner_a,
      inner_b,
    ],
  ]

first_thing := 0
second_thing := 0
third_thing := 0
only_one := 0
a := 0
b := 0
inner_a := 0
inner_b := 0
value_a := 0
value_b := 0
KEY1 := 0
KEY2 := 0
