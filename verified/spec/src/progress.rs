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

//! Install-time verification with progress reports (verified/vmverify/
//! README.md, "Install time"): `verify_shipped_progress` is
//! `v2::cert::verify_shipped` with a callback before each method is
//! checked, so the VM can tell its scheduler that the (non-preemptible)
//! verification is making progress. Same proof, same postcondition: the
//! callback only gets the method index and its `Progress` value, which the
//! verdict does not depend on.

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::xvec::*;
use crate::v2::cert::*;
use crate::v2::verifier::*;
use crate::v2::split::*;
use crate::v2::vprog::*;
pub use crate::v2::walk::Progress;

verus! {

/// `verify_shipped` (cert.rs) with `progress` told before each method: the
/// verdict on program `p` with the shipped certificate `cert` is true only
/// if some certificate with the trusted fields `global_count` and
/// `prim_arity` is accepted. Also returns the method the checker stopped
/// at (diagnostics). `Err(Oom)`: an allocation failed (rejected).
pub fn verify_shipped_progress<P: Progress>(p: &VProgram, cert: &[u8], global_count: u64, prim_arity: &[Vec<u8>],
                                            trusted: bool, progress: P)
    -> (res: Result<(bool, usize), Oom>)
    ensures
        res matches Ok(r) ==> (r.0 ==> exists|c: Cert| accepts(vview(p), c, trusted) && #[trigger] c.global_count == global_count as int
            && c.prim_arity == prim_view(prim_arity@)),
{
    let (g, maps) = match parse_cert(p, cert, global_count, prim_arity) {
        Some(x) => x,
        None => return Ok((false, 0)),
    };
    let mut progress = progress;
    let (ok, at, Ghost(ms)) = crate::v2::walk::walk(p, &g, maps, trusted, &mut progress)?;
    if ok {
        proof {
            lemma_split_sound(vview(p), g@, ms, trusted);
            let c = with_maps(g@, ms);
            assert(c.global_count == global_count as int);
            assert(c.prim_arity == prim_view(prim_arity@));
        }
    }
    Ok((ok, at))
}

} // verus!
