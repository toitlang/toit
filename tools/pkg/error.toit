// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// TODO(florian): use the cli.Ui class for errors and warnings.

error msg/string:
  print "Error: $msg"
  exit 1

warning msg/string:
  print "Warning: $msg"
