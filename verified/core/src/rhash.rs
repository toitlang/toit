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

//! HASH_FIND on registers (proposal, verified/spec/format/
//! 19-builtins-proposal.md): one probe of a hashed collection's index,
//! refining `spec::op_hash_find`. The probe reads the collection, its index
//! and its backing only through the checked accessors of INVOKE_SIZE and
//! INVOKE_AT (`size_x`, `locate`); it is a bounded loop (at most twice the
//! index size) and writes nothing but the frame's probe state and the
//! pushed results.

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::arrays::Loc;
use toit_spec::types::Value;
use toit_spec::v2::types::{State2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec::Probe;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{as1, p1};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{is_instance, fields, elements, bytes, builtin, smi, class_of_obj, TOMBSTONE_CLASS};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_helpers::{smi_val, band, fast_at, fast_size};
#[cfg(verus_keep_ghost)]
use crate::arrays::{vals_good, val_ok, lemma_val, loc_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::good;

verus! {

/// The result of the probe on the machine: the key's word and value, the
/// position and the probe state, or the code.
pub enum XProbe {
    Cand(usize, Ghost<Value>, i64, i64, i64, i64),
    Miss(i64),
}

pub open spec fn xprobe_ok(m: Machine, x: XProbe, o: Probe) -> bool {
    match (x, o) {
        (XProbe::Cand(w, gk, pos, slot, step, d), Probe::Cand(k, pos2, slot2, step2, d2)) => {
            &&& gk@ == k
            &&& w == enc(m.addr(), k)
            &&& encodable(m.addr(), k)
            &&& pos as int == pos2 && slot as int == slot2 && step as int == step2 && d as int == d2
            &&& smi_range(pos as int) && smi_range(slot as int) && smi_range(step as int) && smi_range(d as int)
        },
        (XProbe::Miss(c), Probe::Miss(c2)) => c as int == c2 && smi_range(c as int),
        _ => false,
    }
}

/// What the probe needs of the machine.
pub open spec fn hpre(p: &Program, m: Machine) -> bool {
    &&& m.hrefines(p)
    &&& ro_ok(p)
    &&& vals_good(m.g@.heap)
    &&& p.null == enc(m.addr(), sp::null2(p.ap@))
    &&& p.ap@.builtin.len() == 23
}

pub proof fn lemma_band_range(a: i64, b: i64)
    requires 0 <= b,
    ensures 0 <= a & b <= b,
{
    assert(0 <= b ==> 0 <= a & b <= b) by (bit_vector);
}

/// `hf_at`: element `i` of the index or backing `av`.
fn hf_at_x(m: &Machine, p: &Program, aw: usize, Ghost(av): Ghost<Value>, i: usize) -> (r: Option<(usize, Ghost<Value>)>)
    requires hpre(p, *m), val_ok(*m, aw, av), i as int <= MAX_SMI,
    ensures
        match r {
            Some((w, gv)) => sp::hf_at(p.ap@, m.g@, av, i as int) == Some(gv@) && val_ok(*m, w, gv@),
            None => sp::hf_at(p.ap@, m.g@, av, i as int) is None,
        },
{
    let ghost s = as1(m.g@);
    let ghost ap = p.ap@;
    match m.locate(p, aw, Ghost(av), i, false, p.null, Ghost(sp::null2(ap)), 8) {
        Loc::Elem(ew, garr, j) => {
            let ghost arr = garr@;
            let ghost id = arr->Obj_0 as int;
            proof {
                lemma_val(p, *m, ew, arr);
                assert(obj_model_ok(m.g@.heap[id], m.heap.class_bits(), m.addr()));
                assert(good(m.g@.heap, elements(s, arr)[j as int]));
            }
            let w = m.heap.element(ew, j, Ghost(id));
            Some((w, Ghost(elements(s, arr)[j as int])))
        },
        Loc::Byte(bw, gba, j) => {
            let ghost ba = gba@;
            let ghost id = ba->Obj_0 as int;
            proof { lemma_val(p, *m, bw, ba); }
            let b = m.heap.byte_at(bw, j, Ghost(id));
            proof { lemma_smi_word(b as i64); }
            let w = smi_of(b as i64);
            Some((w, Ghost(smi(b as int))))
        },
        Loc::Fail => None,
    }
}

/// `is_tombstone` of the value `v` (word `w`).
fn tombstone_x(m: &Machine, p: &Program, w: usize, Ghost(v): Ghost<Value>, tomb: i64) -> (r: bool)
    requires hpre(p, *m), val_ok(*m, w, v), tomb as int == builtin(p1(p.ap@), TOMBSTONE_CLASS),
    ensures r == sp::is_tombstone(p.ap@, m.g@, v),
{
    proof { lemma_val(p, *m, w, v); }
    if w & 1 == 0 {
        return false;
    }
    let ghost id = v->Obj_0 as int;
    let cid = m.heap.class_id(w, Ghost(id));
    proof { assert(class_of_obj(as1(m.g@), v) == m.g@.heap[id].class_id); }
    cid as i64 == tomb
}

/// `hf_probe` from `slot0`, `step0`, `d0` with `fuel0`.
fn probe_x(m: &Machine, p: &Program, iw: usize, Ghost(index): Ghost<Value>, bw: usize, Ghost(backing): Ghost<Value>,
    hash: i64, mask: i64, start: i64, slot0: i64, step0: i64, d0: i64, fuel0: i64, tomb: i64) -> (r: XProbe)
    requires
        hpre(p, *m), val_ok(*m, iw, index), val_ok(*m, bw, backing),
        tomb as int == builtin(p1(p.ap@), TOMBSTONE_CLASS),
        0 <= mask < 0x100_0000, 0 <= start <= mask,
        0 <= slot0 <= mask, 1 <= step0 <= 0x400_0000, 0 <= d0 <= mask + 1, 0 <= fuel0 <= 0x200_0000,
        smi_range(hash as int),
    ensures
        xprobe_ok(*m, r, sp::hf_probe(p.ap@, m.g@, index, backing, hash as int, mask as int, start as int,
            slot0 as int, step0 as int, d0 as int, fuel0 as nat)),
{
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost goal = sp::hf_probe(ap, g, index, backing, hash as int, mask as int, start as int,
        slot0 as int, step0 as int, d0 as int, fuel0 as nat);
    let mut slot = slot0;
    let mut step = step0;
    let mut d = d0;
    let mut fuel = fuel0;
    loop
        invariant
            hpre(p, *m), val_ok(*m, iw, index), val_ok(*m, bw, backing),
            tomb as int == builtin(p1(ap), TOMBSTONE_CLASS),
            ap == p.ap@, g == m.g@,
            0 <= mask < 0x100_0000, 0 <= start <= mask, smi_range(hash as int),
            0 <= slot <= mask, 1 <= step, step + fuel <= 0x600_0000, 0 <= d <= mask + 1, 0 <= fuel <= 0x200_0000,
            goal == sp::hf_probe(ap, g, index, backing, hash as int, mask as int, start as int,
                slot0 as int, step0 as int, d0 as int, fuel0 as nat),
            goal == sp::hf_probe(ap, g, index, backing, hash as int, mask as int, start as int,
                slot as int, step as int, d as int, fuel as nat),
        decreases fuel,
    {
        proof {
            reveal_with_fuel(sp::hf_probe, 1);
            assert(sp::HF_IRREGULAR == -2 && sp::HF_FULL == -1);
        }
        if fuel == 0 {
            proof {
                assert(goal == sp::hf_probe(ap, g, index, backing, hash as int, mask as int, start as int,
                    slot as int, step as int, d as int, 0nat));
                assert(sp::hf_probe(ap, g, index, backing, hash as int, mask as int, start as int,
                    slot as int, step as int, d as int, 0nat) == Probe::Miss(-2));
                assert(smi_range(-2));
                assert(xprobe_ok(*m, XProbe::Miss(-2i64), Probe::Miss(-2)));
            }
            return XProbe::Miss(-2);
        }
        let (hw, Ghost(hv)) = match hf_at_x(m, p, iw, Ghost(index), slot as usize) {
            Some(x) => x,
            None => { return XProbe::Miss(-2); },
        };
        proof { lemma_val(p, *m, hw, hv); }
        if hw & 1 != 0 {
            return XProbe::Miss(-2);
        }
        proof { lemma_word_smi(hw); }
        let hap = smi_value(hw);
        proof { assert(hv == Value::Smi(hap)); }
        if hap == 0 {
            if d > 0 {
                return XProbe::Miss(2 * (d - 1));
            } else {
                return XProbe::Miss(2 * slot + 1);
            }
        }
        if hap < 0 {
            proof { assert((hap as int) / 4096 - 1 < 0) by (nonlinear_arith) requires hap < 0; }
            return XProbe::Miss(-2);
        }
        let pos = hap / 4096 - 1;
        proof { assert(pos as int == (hap as int) / 4096 - 1); }
        if pos < 0 {
            return XProbe::Miss(-2);
        }
        let (kw, Ghost(k)) = match hf_at_x(m, p, bw, Ghost(backing), pos as usize) {
            Some(x) => x,
            None => { return XProbe::Miss(-2); },
        };
        let is_tomb = tombstone_x(m, p, kw, Ghost(k), tomb);
        let d1 = if d == 0 && is_tomb { slot + 1 } else { d };
        if (hap & 0xfff) == (hash & 0xfff) && !is_tomb {
            proof {
                assert(band(hap as int, 0xfff) == (hap & 0xfff) as int);
                assert(band(hash as int, 0xfff) == (hash & 0xfff) as int);
                lemma_val(p, *m, kw, k);
            }
            return XProbe::Cand(kw, Ghost(k), pos, slot, step, d1);
        }
        proof {
            assert(band(hap as int, 0xfff) == (hap & 0xfff) as int);
            assert(band(hash as int, 0xfff) == (hash & 0xfff) as int);
        }
        let slot2 = (slot + step) & mask;
        proof {
            lemma_band_range((slot + step) as i64, mask);
            assert(band((slot + step) as int, mask as int) == slot2 as int);
        }
        if slot2 == start {
            return XProbe::Miss(-1);
        }
        slot = slot2;
        step = step + 1;
        d = d1;
        fuel = fuel - 1;
    }
}

/// `hf_find`.
fn find_x(m: &Machine, p: &Program, cw: usize, Ghost(cv): Ghost<Value>, hw: usize, Ghost(hv): Ghost<Value>,
    sw: usize, Ghost(sv): Ghost<Value>, tw: usize, Ghost(tv): Ghost<Value>, dw: usize, Ghost(dv): Ghost<Value>) -> (r: XProbe)
    requires
        hpre(p, *m),
        val_ok(*m, cw, cv), val_ok(*m, hw, hv), val_ok(*m, sw, sv), val_ok(*m, tw, tv), val_ok(*m, dw, dv),
    ensures xprobe_ok(*m, r, sp::hf_find(p.ap@, m.g@, cv, hv, sv, tv, dv)),
{
    let ghost ap = p.ap@;
    let ghost s = as1(m.g@);
    proof {
        lemma_val(p, *m, hw, hv);
        lemma_val(p, *m, sw, sv);
        lemma_val(p, *m, tw, tv);
        lemma_val(p, *m, dw, dv);
    }
    match m.inst_x(p, cw, Ghost(cv)) {
        Some((cnt, _)) => { if cnt < 4 { return XProbe::Miss(-2); } },
        None => { return XProbe::Miss(-2); },
    }
    if (hw & 1) != 0 || (sw & 1) != 0 || (tw & 1) != 0 || (dw & 1) != 0 {
        return XProbe::Miss(-2);
    }
    let hash = smi_value(hw);
    let slot = smi_value(sw);
    let step = smi_value(tw);
    let d = smi_value(dw);
    let (iw, Ghost(index)) = m.field_x(p, cw, Ghost(cv), 2);
    let (bw, Ghost(backing)) = m.field_x(p, cw, Ghost(cv), 3);
    let size = match m.size_x(p, iw, Ghost(index)) {
        Some(n) => n,
        None => { return XProbe::Miss(-2); },
    };
    if !(1 <= size && size <= 0x100_0000) {
        return XProbe::Miss(-2);
    }
    let sm1 = size - 1;
    let bits = size & sm1;
    proof { assert(band(size as int, sm1 as int) == bits as int); }
    if bits != 0 {
        return XProbe::Miss(-2);
    }
    if !(0 <= slot && slot < size && 0 <= step && step <= 2 * size && 0 <= d && d <= size) {
        return XProbe::Miss(-2);
    }
    let mask = size - 1;
    let start = hash & mask;
    proof {
        lemma_band_range(hash, mask);
        assert(band(hash as int, mask as int) == start as int);
    }
    let tw2 = p.builtin.at(10);
    proof {
        assert(p.builtin@[10] == smi_word(ap.builtin[10] as i64));
        lemma_smi_word(ap.builtin[10] as i64);
    }
    let tomb = smi_value(tw2);
    proof { assert(tomb as int == builtin(p1(ap), TOMBSTONE_CLASS)); }
    if step == 0 {
        probe_x(m, p, iw, Ghost(index), bw, Ghost(backing), hash, mask, start, start, 1, d, 2 * size, tomb)
    } else {
        let slot2 = (slot + step) & mask;
        proof {
            lemma_band_range((slot + step) as i64, mask);
            assert(band((slot + step) as int, mask as int) == slot2 as int);
        }
        if slot2 == start {
            return XProbe::Miss(-1);
        }
        probe_x(m, p, iw, Ghost(index), bw, Ghost(backing), hash, mask, start, slot2, step + 1, d, 2 * size, tomb)
    }
}

/// HASH_FIND n mm: probe state slots `n`, `n + 1`, `n + 2`, the hash in
/// slot `mm`, the collection in `mm + 2`; a miss branches forward by `dd`.
#[inline(always)]
pub fn op_hash_find(m: &mut Machine, r: &mut Regs, p: &Program, n: usize, mm: usize, dd: usize, Ghost(target): Ghost<usize>) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        p.ap@.builtin.len() == 23,
        ro_ok(p),
        vals_good(old(m).g@.heap),
        !(sp::op_hash_find(p.ap@, old(m).g@, target as int, n as int, mm as int, 5) is Stuck),
        forall|j: int| (j == n || j == n + 1 || j == n + 2 || j == mm || j == mm + 2) ==>
            (#[trigger] sp::at(old(m).g@, j) is Smi || sp::at(old(m).g@, j) is Obj),
        old(r).ip@ + dd < 0x1000_0000,
        old(r).ip@ + 5 < 0x1000_0000,
        target as int == old(r).ip@ + dd,
        n < 256, mm < 256,
    ensures
        c == Ctl::Next,
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::op_hash_find(p.ap@, old(m).g@, target as int, n as int, mm as int, 5)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    let ghost ap = p.ap@;
    let ghost vs = sp::at(g0, n as int);
    let ghost vt = sp::at(g0, n + 1);
    let ghost vd = sp::at(g0, n + 2);
    let ghost vh = sp::at(g0, mm as int);
    let ghost vc = sp::at(g0, mm + 2);
    proof {
        m0.lemma_at(p, n as int);
        m0.lemma_at(p, n + 1);
        m0.lemma_at(p, n + 2);
        m0.lemma_at(p, mm as int);
        m0.lemma_at(p, mm + 2);
        m0.lemma_at(p, 0);
        assert(m.hrefines(p));
        assert(ap.roots[0] == sp::null2(ap));
        assert(p.null == enc(m.addr(), sp::null2(ap)));
        assert(sp::at(g0, n as int) is Smi || sp::at(g0, n as int) is Obj);
        assert(sp::at(g0, n + 1) is Smi || sp::at(g0, n + 1) is Obj);
        assert(sp::at(g0, n + 2) is Smi || sp::at(g0, n + 2) is Obj);
        assert(sp::at(g0, mm as int) is Smi || sp::at(g0, mm as int) is Obj);
        assert(sp::at(g0, mm + 2) is Smi || sp::at(g0, mm + 2) is Obj);
    }
    let ws = at(m, r, n);
    let wt = at(m, r, n + 1);
    let wd = at(m, r, n + 2);
    let wh = at(m, r, mm);
    let wc = at(m, r, mm + 2);
    proof {
        assert(good(g0.heap, vs)) by { assert(encodable(m.addr(), vs)); }
        assert(val_ok(*m, ws, vs) && val_ok(*m, wt, vt) && val_ok(*m, wd, vd)
            && val_ok(*m, wh, vh) && val_ok(*m, wc, vc));
    }
    let x = find_x(m, p, wc, Ghost(vc), wh, Ghost(vh), ws, Ghost(vs), wt, Ghost(vt), wd, Ghost(vd));
    match x {
        XProbe::Cand(kw, gk, pos, slot, step, d) => {
            let ghost k = gk@;
            proof {
                lemma_smi_word(slot);
                lemma_smi_word(step);
                lemma_smi_word(d);
                lemma_smi_word(pos);
            }
            let w0 = smi_of(slot);
            let w1 = smi_of(step);
            let w2 = smi_of(d);
            let wp = smi_of(pos);
            r.sp.write(n, w0, &mut m.mem);
            r.sp.write(n + 1, w1, &mut m.mem);
            r.sp.write(n + 2, w2, &mut m.mem);
            let s1 = r.sp.offset(-1);
            s1.write(0, kw, &mut m.mem);
            let s2 = s1.offset(-1);
            s2.write(0, wp, &mut m.mem);
            r.sp = s2;
            r.ip = r.ip.offset(5);
            let ghost g1 = sp::goto(sp::push(sp::push(sp::put(sp::put(sp::put(g0, n as int, smi(slot as int)),
                n + 1, smi(step as int)), n + 2, smi(d as int)), k), smi(pos as int)), g0.bci + 5);
            m.g = Ghost(g1);
            proof {
                let m1 = m.with(*r);
                let hh = m0.height();
                assert(m0.words().len() == enc_seq(m0.addr(), g0.stack).len());
                assert(g0.stack.len() == hh);
                assert(m1.words() =~= m0.words().update(hh - 1 - n, w0).update(hh - 2 - n, w1)
                    .update(hh - 3 - n, w2).push(kw).push(wp));
                assert(g1.stack =~= g0.stack.update(hh - 1 - n, smi(slot as int)).update(hh - 2 - n, smi(step as int))
                    .update(hh - 3 - n, smi(d as int)).push(k).push(smi(pos as int)));
                assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
                assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
                    if j < hh && j != hh - 1 - n && j != hh - 2 - n && j != hh - 3 - n {
                        assert(g1.stack[j] == g0.stack[j]);
                    }
                }
                assert(sp::op_hash_find(ap, g0, target as int, n as int, mm as int, 5) == Outcome2::Next(g1));
                lemma_local(p, m0, m1, g1);
            }
            Ctl::Next
        },
        XProbe::Miss(code) => {
            proof { lemma_smi_word(code); }
            let wcode = smi_of(code);
            let s1 = r.sp.offset(-1);
            s1.write(0, wcode, &mut m.mem);
            r.sp = s1;
            r.ip = r.ip.offset(dd as isize);
            let ghost g1 = sp::goto(sp::push(g0, smi(code as int)), target as int);
            m.g = Ghost(g1);
            proof {
                let m1 = m.with(*r);
                assert(m1.words() =~= m0.words().push(wcode));
                assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
                assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
                    if j < g0.stack.len() { assert(g1.stack[j] == g0.stack[j]); }
                }
                assert(sp::op_hash_find(ap, g0, target as int, n as int, mm as int, 5) == Outcome2::Next(g1));
                lemma_local(p, m0, m1, g1);
            }
            Ctl::Next
        },
    }
}

} // verus!
