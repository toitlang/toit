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
//! `v2::cert::verify_shipped` with a callback before each method's maps
//! are read, so the VM can tell its scheduler that the (non-preemptible)
//! verification is making progress. Same proof, same postcondition: the
//! callback only gets the method index and its `Progress` value, which the
//! verdict does not depend on.

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::xvec::*;
use crate::v2::check::*;
use crate::v2::cert::*;
use crate::v2::verifier::*;
use crate::v2::split::*;
use crate::v2::vprog::*;
#[cfg(verus_only)]
use crate::v2::exec::wf_program2;

verus! {

/// What the checker reports between methods (implemented by the VM's glue:
/// verified/vmverify/src/verify.rs).
pub trait Progress {
    /// Called before the maps of method `m` are read, so once per method in
    /// order, before the method is checked.
    fn method(&mut self, m: usize);
}

/// `ShippedOracle` with a progress report per method.
pub struct ProgressOracle<'a, P: Progress> {
    pub inner: ShippedOracle<'a>,
    pub progress: P,
}

impl<'a, P: Progress> MapOracle for ProgressOracle<'a, P> {
    fn method_maps(&mut self, p: &VProgram, g: &XGlobal, m: usize) -> Result<XMaps, Oom> {
        self.progress.method(m);
        self.inner.method_maps(p, g, m)
    }
}

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
    let mut o = ProgressOracle { inner: ShippedOracle::new(maps, trusted), progress };
    let (ok, Ghost(ms)) = verify(p, &g, &mut o, trusted)?;
    if ok {
        proof {
            lemma_split_sound(vview(p), g@, ms, trusted);
            let c = with_maps(g@, ms);
            assert(c.global_count == global_count as int);
            assert(c.prim_arity == prim_view(prim_arity@));
        }
    }
    Ok((ok, o.inner.last))
}

} // verus!
