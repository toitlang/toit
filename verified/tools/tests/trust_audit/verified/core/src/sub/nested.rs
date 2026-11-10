// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

//! A file in a subdirectory (walk order: after the files of src/).

use vstd::prelude::*;

verus! {

use vstd::seq::*;
unknown_inside_verus;

pub fn nested(x: u8) -> (r: u8)
    ensures r == x,
{
    x
}

proof fn nested_theorem()
    ensures 1 + 1 == 2,
{
}

pub closed spec fn closed_nested() -> bool {
    true
}


} // verus!
