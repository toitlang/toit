// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

	/* with tabs */
  	/* with tabs */
main:
	expect true
  	expect true
	expect true
 	expect true
  	expect true
   	expect true
    	expect true
     	expect true
      	expect true
       	expect true
	unresolved	unresolved2

	"0123456789112345678921234567893123456789412345678951234567896123456789712345678981234567899123456789A123456789B123456789C123456789D1234567891E23456789F23456789" + unresolved
	"0123456789112345678921234567893123456789412345678951234567896"	 +		 "123456789712345678981234567899123456789A123456789B123456789C123456789D1234567891E23456789F23456789" + unresolved
	"0123456789112345	678921234567893123456789412345678951234567896"	 +	unresolved
	"Error is not allowed to be off: 0123456789112345678921234567893123456789412345678951234567896123456789712345678981234567899123456789A123456789B123456789C123456789D1234567891E23456789F23456789" +	unresolved

foo:
  "0123456789112345678921234567893123456789412345678951234567896123456789712345678981234567899123456789A123456789B123456789C123456789D1234567891E23456789F23456789" + unresolved
  "0123456789112345678921234567893123456789412345678951234567896"	 +		 "123456789712345678981234567899123456789A123456789B123456789C123456789D1234567891E23456789F23456789" + unresolved
  "0123456789112345	6789	21234567893123456789412345678951234567896"	 +	unresolved
  "Error is not allowed to be off: 0123456789112345678921234567893123456789412345678951234567896123456789712345678981234567899123456789A123456789B123456789C123456789D1234567891E23456789F23456789" +	unresolved
