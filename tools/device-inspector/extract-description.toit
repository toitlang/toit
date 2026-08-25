// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import fs
import host.file

import .description as inspector-description
import .extract-runtime-layout as runtime-layout-extractor

main args/List:
  if args.size != 3:
    print "Usage: extract-description GDB FIRMWARE.elf OUTPUT.json"
    throw "INVALID_ARGUMENTS"
  extract-description args[0] args[1] args[2]

extract-description gdb/string elf-path/string output/string -> none:
  layout := runtime-layout-extractor.extract-runtime-layout-data gdb elf-path
  elf := file.read-contents elf-path
  result := inspector-description.create layout elf (fs.basename elf-path)
  file.write-contents --path=output ((json.encode result) + #[10])
