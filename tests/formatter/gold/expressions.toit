main:
    precedence := ((a + b)) * c
    logical := foo and (bar or gee)
    bits := byte >> 4 & 0xf
    call := consume  (build x y)
    bytes := #[1,2,  3]
    mapping := {one:1,two: 2}
    binary-layout := alpha-identifier-that-is-deliberately-very-long + beta-identifier-that-is-deliberately-very-long + gamma-identifier-that-is-deliberately-very-long
    call-layout := send first-argument-that-is-moderately-long second-argument-that-is-moderately-long third-argument-that-is-moderately-long
    many-arguments := consume arg01 arg02 arg03 arg04 arg05 arg06 arg07 arg08 arg09 arg10 arg11 arg12 arg13 arg14 arg15
    collection-layout := [aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccccccccccccccccc, dddddddddddddddddddddddddddddddddddddddd]

a := 1
b := 2
c := 3
foo := true
bar := false
gee := true
byte := 16
x := 1
y := 2
consume value: return value
build first second: return first + second
