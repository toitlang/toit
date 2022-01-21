// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test discovered by fuzzing the compiler.
// The compiler would crash if the toitdoc started with a tab.

/**	tab to the left
*/
foo:

/**
	tab to the left.
*/
bar:

/**
- entry

	tab to the left
*/
main:
