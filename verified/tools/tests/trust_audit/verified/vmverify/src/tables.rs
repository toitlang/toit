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

//! Fixture: non-ASCII text — in comments (« unsafe »), strings and char
//! literals — never counts and keeps the line numbers right.

pub struct Reader<'a> {
    data: &'a [u8],
}

impl<'a> Reader<'a> {
    pub fn arrow(&self) -> char {
        let s = "→ unsafe ←";
        let c = 'é';
        let d = '→';
        c
    }

    pub fn vec(&self) -> Vec<u8> {
        unsafe { Vec::from_raw_parts(core::ptr::null_mut(), 0, 0) }
    }
}
