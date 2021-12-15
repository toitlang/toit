// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
