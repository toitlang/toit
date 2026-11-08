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

//! `double_to_shortest` from `src/dtoa.cc`. The shortest round-trip digits
//! come from Rust's formatter (same digits as dragonbox: shortest, then
//! closest); the layout follows dtoa.cc.

/// `x` must be finite and non-zero.
pub fn shortest(x: f64) -> String {
    let sci = format!("{:e}", x.abs());  // e.g. "1.2345e-7"
    let (mant, exp) = sci.split_once('e').unwrap();
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let digit_count = digits.len() as i32;
    let adjusted_exponent: i32 = exp.parse().unwrap();
    let exponent = adjusted_exponent - (digit_count - 1);
    let mut out = String::new();
    if x.is_sign_negative() {
        out.push('-');
    }
    if (-6..21).contains(&adjusted_exponent) {
        if exponent >= 0 {
            out.push_str(&digits);
            for _ in 0..exponent {
                out.push('0');
            }
            out.push_str(".0");
        } else if adjusted_exponent >= 0 {
            let point = (adjusted_exponent + 1) as usize;
            out.push_str(&digits[..point]);
            out.push('.');
            out.push_str(&digits[point..]);
        } else {
            out.push_str("0.");
            for _ in 0..(-adjusted_exponent - 1) {
                out.push('0');
            }
            out.push_str(&digits);
        }
    } else {
        out.push_str(&digits[..1]);
        if digit_count > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        out.push('e');
        let mut e = adjusted_exponent;
        if e < 0 {
            out.push('-');
            e = -e;
        }
        out.push_str(&format!("{:02}", e));
    }
    out
}
