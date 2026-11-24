// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Compiled against a copy of the SDK's library whose StringSlice_ does not
// check that its boundaries are character boundaries (run-cut-slice.cmake),
// and run as an untrusted container: a program brings its own library, and
// the loader checks the builtin classes' shapes, not their code. The
// concatenation copies the cut bytes into a string that is not valid UTF-8
// (the loader checks the program's string literals, nothing checks the
// strings a program makes). Its last byte is the lead byte of a three-byte
// sequence. Until wave 10 the C++ string_at (the Rust port declines such a
// string) read the terminator and the byte after the string, the first
// byte of the next heap object, and returned some of its bits
// (verified/cxx/annotated/README.md, "Findings", wave 10).

main:
  s := "aaaaaa€"
  cut := StringSlice_ (s as String_) 0 7
  t := cut + ""
  print "size=$t.size at=$t[6]"
  u := "$cut$cut"
  print "size=$u.size at=$u[13]"
