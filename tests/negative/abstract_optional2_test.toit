// Copyright (C) 2021 Toitware ApS. All rights reserved.

/**
Ensure that we handle abstract top-level methods with optional parameters.
*/

gee:
abstract foo x y=gee --named1=gee --named2=2
abstract bar x/int="str"
abstract foobar x y=this.gee
