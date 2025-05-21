// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The imported file has the filename 'Bad-Case-Import-Other.toit' which
// is acceptable on Windows and macOS, but not on Linux.
import .bad-case-import-other as other
import .bad-case-dir.other as dir

main:
  other.foo
  dir.foo
  unresolved
