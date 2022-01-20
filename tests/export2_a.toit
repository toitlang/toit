// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The explicit 'show foo' disambiguates the export clause.
import .export2_b
import .export2_c show foo

export *
