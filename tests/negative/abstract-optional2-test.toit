// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Ensure that we handle abstract top-level methods with optional parameters.
*/

gee:
abstract foo x y=gee --named1=gee --named2=2
abstract bar x/int="str"
abstract foobar x y=this.gee
