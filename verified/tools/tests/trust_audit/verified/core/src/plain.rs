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

//! A file without a verus! block: plain_rust_file.

use std::fmt;

pub fn plain(x: u8) -> u8 {
    x
}

pub struct Plain;

unrecognized_item_here;

#[cfg(verus_keep_ghost)]
pub fn plain_with_verus_cfg() {
}

