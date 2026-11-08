// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
Dumps a snapshot in the flat format read by the executable bytecode
  specification in `verified/spec`.

Usage: spec_dump <snapshot> <output>
*/

import host.file
import .snapshot

main args/List:
  if args.size != 2:
    print "Usage: spec_dump <snapshot> <output>"
    exit 1
  bundle := SnapshotBundle.from-file args[0]
  program := bundle.decode
  dump := (SpecDump program).dump
  file.write-contents --path=args[1] dump
