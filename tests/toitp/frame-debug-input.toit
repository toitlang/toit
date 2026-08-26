// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Fixture:
  inspect first second:
    local := first
    previous := local++
    print "$previous $local $second"

main:
  (Fixture).inspect 41 42
