// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.pipe

// Tests a system program that has applications compiled into it. The
// applications have package locks of their own, which map the same prefix
// to different versions of a package. The system program starts each of
// them in a container of its own. With --native, the program is compiled
// to a native executable.

main args:
  input := args[0]
  compiler := args[1]
  runner := args[2]
  system := args[3]
  is-native := args.size > 4 and args[4] == "--native"

  tmp-dir := directory.mkdtemp "/tmp/toit-combined-test-"
  try:
    program := is-native ? "$tmp-dir/system" : "$tmp-dir/system.snapshot"
    arguments := [compiler, "--combine", "$input/a/a.toit", "--combine", "$input/b/b.toit"]
    if is-native:
      arguments.add-all ["--native", "-o", program]
    else:
      arguments.add-all ["-w", program]
    arguments.add system
    output := pipe.backticks arguments
    expect-equals "" output.trim
    // The program runs on its own, without another system program. The
    // combined programs run at the same time, so their output can be in any
    // order. Lines end with "\r\n" on Windows.
    command := is-native ? [program, "x", "y"] : [runner, program, "x", "y"]
    lines := ((pipe.backticks command).trim.split "\n").map: it.trim
    lines.sort --in-place
    expect-equals ["a: [x, y] foo version a", "b: foo version b"] lines
  finally:
    directory.rmdir --recursive tmp-dir
