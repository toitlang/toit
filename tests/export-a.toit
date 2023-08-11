// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The explicit 'show foo' disambiguates the export clause.
import .export-b
import .export-c show foo

export foo
