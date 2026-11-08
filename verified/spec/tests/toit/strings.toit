// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  s := "Hello, World"
  print s.size
  print s.to-ascii-upper
  print s.to-ascii-lower
  print (s.index-of "World")
  print s[0..5]
  print (s.replace "World" "Toit")
  print (s.split ", ")
  print ("  padded  ".trim)
  print ("a-b-c".split "-")
  print (["x", "y", "z"].join ":")
  print "interpolation: $(1 + 2) $s"
  print (s.starts-with "Hello")
  print (s.ends-with "x")
  print ("abc" < "abd")
  print ("abc".compare-to "ab")
  print "unicode: æøå €"
  print "æøå".size
  r := ""
  "æøå".do --runes: r += "<$it>"
  print r
  print (string.from-rune 0x1F600)
  print "$(%5d 42)|$(%-5s "ab")|$(%x 255)|$(%08.3f 3.14159)"
  print 12345.stringify
  print (-987).stringify
  print (int.parse "12_345")
  print (int.parse "-77")
  print (int.parse "ff" --radix=16)
  print (255.to-string --radix=2)
  print "abc".hash-code
  print ("abc" == "ab" + "c")
  sb := []
  10.repeat: sb.add "$it"
  print (sb.join "")
  print ("x" * 5)
  print "tab\tquote\"backslash\\"
  bytes := "hello".to-byte-array
  print bytes
  print bytes.to-string
  print (s.copy 7)
  print (s.pad --left 15 '*')
