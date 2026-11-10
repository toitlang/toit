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

//! Phase times for the verifier's result (diagnostics only): monotonic
//! nanoseconds on hosts, zero without `std`.

pub struct Clock {
    #[cfg(feature = "std")]
    start: std::time::Instant,
}

impl Clock {
    pub fn start() -> Clock {
        Clock {
            #[cfg(feature = "std")]
            start: std::time::Instant::now(),
        }
    }

    /// Nanoseconds since `start`.
    pub fn ns(&self) -> u64 {
        #[cfg(feature = "std")]
        { self.start.elapsed().as_nanos() as u64 }
        #[cfg(not(feature = "std"))]
        { 0 }
    }
}
