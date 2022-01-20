// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .import_cache3  // Contains 'bar'.

// Important that we have an `export *`.
// This makes the compiler cache lookup-results.
export *
