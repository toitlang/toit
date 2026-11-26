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

//! Object layouts: the size of an object and its range of reference slots,
//! computed from its raw words (the header and, for some kinds, a length
//! word), as the C++ `HeapObject::size` and `roots_do` compute them
//! (src/objects.cc, src/objects.h). The collector depends on layouts only
//! through `lay`, `obj_ok` and `obj_layout`.
//!
//! The header is the smi `class_id << 5 | class_tag` (plus the finalizer
//! bit 4); its class tag selects the kind:
//!
//! | tag | kind | size in words | reference slots |
//! |---|---|---|---|
//! | 0 | array | `2 + length` (length word 1) | `2..size` |
//! | 1 | string | internal: `align(16/8 + length + 1)` (length half word at byte 12/6); external (length `0xffff`): 4 | none |
//! | 2, 8 | instance, task | the class's instance size (class bits `>> 5 & 0x7ff`) | `1..size` |
//! | 3 | oddball (program heap only) | the class's instance size | none |
//! | 4, 6 | double, large integer | `1 + VALUE_WORDS` (2 / 3) | none |
//! | 5 | byte array | internal (raw length word 1 `>= 0`): `align(16/8 + length)`; external: 4 | none |
//! | 7 | stack | `sw + length` (length word 2, top word 3; `sw`, the array's first word, from C++) | the object stack `sw + top .. sw + length` |
//!
//! (16/8: the 64-bit/32-bit value; `align` rounds bytes up to words.)
//!
//! Stacks: the collector reads only the length and top words; the frame
//! records below the top (format 2: frame and finally records; format 3,
//! branch format3/try: frame records only) are raw words, the object stack
//! above it holds values. A raw word in the object stack (a smi, a block
//! reference; in format 1 a bytecode pointer) is never a from-space
//! address, so visiting it leaves it as it is (the C++ skips bytecode
//! pointers explicitly). Stacks are not shrunk (stage-1 README, section 6:
//! then `stack_copy_equiv` is not needed); the C++ prototype shrinks them.
//!
//! Little-endian targets only (the string length half word's position in
//! word 1).

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::*;
use crate::model::*;

verus! {

// The VM's layout facts (src/objects.h; the ones the core shares are proved
// equal to verified/core/src/layout.rs in the bridge, which LAYOUT.toml
// checks against the C++).
pub const ARRAY_TAG: usize = 0;
pub const STRING_TAG: usize = 1;
pub const INSTANCE_TAG: usize = 2;
pub const ODDBALL_TAG: usize = 3;
pub const DOUBLE_TAG: usize = 4;
pub const BYTE_ARRAY_TAG: usize = 5;
pub const LARGE_INTEGER_TAG: usize = 6;
pub const STACK_TAG: usize = 7;
pub const TASK_TAG: usize = 8;

pub const ARRAY_LENGTH_WORD: usize = 1;
pub const ARRAY_ELEMENTS_WORD: usize = 2;
pub const INSTANCE_FIELDS_WORD: usize = 1;
pub const STACK_LENGTH_WORD: usize = 2;
pub const STACK_TOP_WORD: usize = 3;
/// Format 2: the record top in the low 16 bits (and the frame top above).
pub const STACK_RECORD_TOP_WORD: usize = 4;
/// A stack's header words up to its bci word (the array starts at or after
/// it; C++ passes the array's first word, which depends on the guard zone).
pub const STACK_MIN_ARRAY_WORD: usize = 6;
/// External strings and byte arrays: header, two or three words.
pub const EXTERNAL_WORDS: usize = 4;
pub const STRING_SENTINEL: usize = 0xffff;
#[cfg(target_pointer_width = "64")]
pub const VALUE_WORDS: usize = 1;
#[cfg(target_pointer_width = "32")]
pub const VALUE_WORDS: usize = 2;
#[cfg(target_pointer_width = "64")]
pub const CONTENT_BYTE: usize = 16;
#[cfg(target_pointer_width = "32")]
pub const CONTENT_BYTE: usize = 8;
/// The string length half word in word 1 (byte offset 12 / 6, little
/// endian): its shift and mask.
#[cfg(all(target_pointer_width = "64", target_endian = "little"))]
pub const STRING_LENGTH_SHIFT: usize = 32;
#[cfg(all(target_pointer_width = "64", target_endian = "little"))]
pub const STRING_LENGTH_MASK: usize = 0xffff_ffff;
#[cfg(all(target_pointer_width = "32", target_endian = "little"))]
pub const STRING_LENGTH_SHIFT: usize = 16;
#[cfg(all(target_pointer_width = "32", target_endian = "little"))]
pub const STRING_LENGTH_MASK: usize = 0xffff;

/// Size in words, and the reference slots `lo..hi`.
pub struct Lay {
    pub size: int,
    pub lo: int,
    pub hi: int,
}

pub open spec fn hdr(o: AObj) -> usize { raw(o.words[0]) }

/// The class tag and class id of a header word.
pub open spec fn htag(h: usize) -> usize { (h >> 1usize) & 15usize }

pub open spec fn hcid(h: usize) -> usize { h >> 6usize }

/// The instance size in words of class bits `b` (`Program::
/// instance_size_from_class_bits`).
pub open spec fn isize_bits(b: u16) -> int { ((b >> 5u16) & 0x7ffu16) as int }

/// Words of a string whose word 1 is `w`.
pub open spec fn str_words(w: usize) -> int {
    let l = (w >> STRING_LENGTH_SHIFT) & STRING_LENGTH_MASK;
    if l == STRING_SENTINEL { EXTERNAL_WORDS as int } else { (CONTENT_BYTE + l + 1 + W - 1) as int / W as int }
}

/// Words of a byte array whose raw length word is `w`.
pub open spec fn ba_words(w: usize) -> int {
    if w <= usize::MAX / 2 { (CONTENT_BYTE + w + W - 1) as int / W as int } else { EXTERNAL_WORDS as int }
}

pub open spec fn lay(o: AObj) -> Lay {
    let t = htag(hdr(o));
    let w1 = raw(o.words[1]);
    if t == ARRAY_TAG {
        Lay { size: 2 + w1 as int, lo: 2, hi: 2 + w1 as int }
    } else if t == INSTANCE_TAG || t == TASK_TAG {
        Lay { size: isize_bits(o.cbits), lo: 1, hi: isize_bits(o.cbits) }
    } else if t == ODDBALL_TAG {
        Lay { size: isize_bits(o.cbits), lo: isize_bits(o.cbits), hi: isize_bits(o.cbits) }
    } else if t == STRING_TAG {
        Lay { size: str_words(w1), lo: str_words(w1), hi: str_words(w1) }
    } else if t == BYTE_ARRAY_TAG {
        Lay { size: ba_words(w1), lo: ba_words(w1), hi: ba_words(w1) }
    } else if t == DOUBLE_TAG || t == LARGE_INTEGER_TAG {
        Lay { size: 1 + VALUE_WORDS as int, lo: 1 + VALUE_WORDS as int, hi: 1 + VALUE_WORDS as int }
    } else if t == STACK_TAG {
        let len = raw(o.words[STACK_LENGTH_WORD as int]) as int;
        let top = raw(o.words[STACK_TOP_WORD as int]) as int;
        Lay { size: o.sw + len, lo: o.sw + top, hi: o.sw + len }
    } else {
        Lay { size: 0, lo: 1, hi: 1 }
    }
}

/// The object agrees with its layout: its words, a raw even header, raw
/// words outside the reference slots; a stack's array starts after its
/// header words, and its top is at most its length.
pub open spec fn obj_ok(o: AObj) -> bool {
    let l = lay(o);
    &&& o.words.len() == l.size
    &&& 1 <= l.lo <= l.hi <= l.size
    &&& o.words[0] is Raw
    &&& hdr(o) % 2 == 0
    &&& forall|k: int| 0 <= k < l.size && !(l.lo <= k < l.hi) ==> #[trigger] o.words[k] is Raw
    &&& htag(hdr(o)) == STACK_TAG ==> STACK_MIN_ARRAY_WORD <= o.sw
        && raw(o.words[STACK_TOP_WORD as int]) <= raw(o.words[STACK_LENGTH_WORD as int])
}

/// The class table's permissions: `ncls` 16-bit entries holding `cbs`.
pub open spec fn at16(base: *mut u16, i: int) -> *mut u16 {
    ptr_mut_from_data::<u16>(PtrData::<u16> { addr: (base@.addr + 2 * i) as usize, provenance: base@.provenance, metadata: () })
}

pub open spec fn ctab_ok(c: Ctx, ctp: Map<int, PointsTo<u16>>) -> bool {
    &&& c.ctab@.addr + 2 * c.ncls <= usize::MAX
    &&& forall|i: int| 0 <= i < c.ncls ==> #[trigger] ctp.contains_key(i) && ctp[i].ptr() == at16(c.ctab, i)
            && ctp[i].is_init() && ctp[i].value() == c.cbs@[i]
}

/// The object's class id is in the class table, its class bits are that
/// entry, and its stack array word is the context's.
pub open spec fn cls_ok(c: Ctx, o: AObj) -> bool {
    &&& (hcid(hdr(o)) as int) < c.ncls
    &&& o.cbits == c.cbs@[hcid(hdr(o)) as int]
    &&& o.sw == c.sw
}

/// The raw words of the object at offset `off` of page `pg` (base pointer
/// `page`) in `m` are the object's.
pub open spec fn raw_words_at(m: Map<(int, int), PointsTo<usize>>, page: *mut usize, pg: int, off: int, o: AObj) -> bool {
    forall|k: int| 0 <= k < lay(o).size && #[trigger] o.words[k] is Raw ==>
        wperm_ok(m, (pg, off + k), page, off + k) && m[(pg, off + k)].is_init()
        && m[(pg, off + k)].value() == raw(o.words[k])
}

/// Reads class table entry `i`.
#[inline(always)]
fn class_bits(c: &Ctx, i: usize, Tracked(ctp): Tracked<&Map<int, PointsTo<u16>>>) -> (b: u16)
    requires ctab_ok(*c, *ctp), i < c.ncls,
    ensures b == c.cbs@[i as int],
{
    proof { assert(ctp.contains_key(i as int)); }
    let p = c.ctab.with_addr(c.ctab.addr() + 2 * i);
    *ptr_ref(p, Tracked(ctp.tracked_borrow(i as int)))
}

/// Rounding bytes up to words: the size computations do not overflow when
/// the result is at most a page.
proof fn lemma_words_bound(x: int, pw: int)
    requires x >= 0, (x + W - 1) / (W as int) <= pw, pw <= 0x10_0000,
    ensures x + W - 1 <= usize::MAX,
{
    lemma_w();
    let w = W as int;
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(x + w - 1, w);
    assert(x + w - 1 < ((x + w - 1) / w + 1) * w) by (nonlinear_arith)
        requires x + w - 1 == w * ((x + w - 1) / w) + (x + w - 1) % w, 0 <= (x + w - 1) % w < w;
    assert(((x + w - 1) / w + 1) * w <= (pw + 1) * w) by (nonlinear_arith)
        requires (x + w - 1) / w <= pw, w > 0;
}

/// The layout of the object at offset `off` of page `pg`, read from its
/// raw words (and, for instances, the class table): (size, lo, hi).
pub fn obj_layout(c: &Ctx, page: *mut usize, off: usize, Ghost(pg): Ghost<int>, Tracked(m): Tracked<&Map<(int, int), PointsTo<usize>>>,
                  Ghost(o): Ghost<AObj>, Ghost(pw): Ghost<int>, Tracked(ctp): Tracked<&Map<int, PointsTo<u16>>>) -> (r: (usize, usize, usize))
    requires
        obj_ok(o), cls_ok(*c, o), ctab_ok(*c, *ctp),
        off + lay(o).size <= pw,
        pw <= 0x10_0000,
        page@.addr + pw * W <= usize::MAX,
        raw_words_at(*m, page, pg, off as int, o),
    ensures
        r.0 == lay(o).size, r.1 == lay(o).lo, r.2 == lay(o).hi,
{
    proof {
        lemma_w();
        assert(o.words[0] is Raw);
        assert(off * W <= pw * W) by (nonlinear_arith) requires off <= pw, W > 0;
        assert(pw <= usize::MAX) by (nonlinear_arith) requires page@.addr + pw * W <= usize::MAX, W >= 1, page@.addr >= 0;
        assert(pw * W <= usize::MAX) by (nonlinear_arith) requires page@.addr + pw * W <= usize::MAX, page@.addr >= 0;
    }
    let h = rd(page, off, Ghost((pg, off as int)), Tracked(m));
    let t = (h >> 1) & 15;
    proof { assert(h == hdr(o)); assert(t == htag(h)); }
    if t == INSTANCE_TAG || t == TASK_TAG || t == ODDBALL_TAG {
        let b = class_bits(c, h >> 6, Tracked(ctp));
        let s = ((b >> 5) & 0x7ff) as usize;
        if t == ODDBALL_TAG { (s, s, s) } else { (s, 1, s) }
    } else if t == STACK_TAG {
        proof {
            assert(o.words[2] is Raw && o.words[3] is Raw);
            assert((off + 3) * W <= pw * W) by (nonlinear_arith) requires off + 3 <= pw, W > 0;
            assert((off + 2) * W <= pw * W) by (nonlinear_arith) requires off + 2 <= pw, W > 0;
        }
        let len = rd(page, off + 2, Ghost((pg, off + 2)), Tracked(m));
        let top = rd(page, off + 3, Ghost((pg, off + 3)), Tracked(m));
        (c.sw + len, c.sw + top, c.sw + len)
    } else if t == DOUBLE_TAG || t == LARGE_INTEGER_TAG {
        (1 + VALUE_WORDS, 1 + VALUE_WORDS, 1 + VALUE_WORDS)
    } else {
        // Array, string or byte array: the size is in word 1.
        proof {
            assert(t == ARRAY_TAG || t == STRING_TAG || t == BYTE_ARRAY_TAG);
            assert(lay(o).size >= 2 && 1 < lay(o).lo);
            assert(o.words[1] is Raw);
            assert((off + 1) * W <= pw * W) by (nonlinear_arith) requires off + 1 <= pw, W > 0;
        }
        let w1 = rd(page, off + 1, Ghost((pg, off + 1)), Tracked(m));
        if t == ARRAY_TAG {
            (2 + w1, 2, 2 + w1)
        } else if t == STRING_TAG {
            let l = (w1 >> STRING_LENGTH_SHIFT) & STRING_LENGTH_MASK;
            let s = if l == STRING_SENTINEL {
                EXTERNAL_WORDS
            } else {
                proof { lemma_words_bound(CONTENT_BYTE + l + 1, pw); }
                (CONTENT_BYTE + l + 1 + W - 1) / W
            };
            (s, s, s)
        } else {
            let s = if w1 <= usize::MAX / 2 {
                proof { lemma_words_bound(CONTENT_BYTE + w1, pw); }
                (CONTENT_BYTE + w1 + W - 1) / W
            } else {
                EXTERNAL_WORDS
            };
            (s, s, s)
        }
    }
}

} // verus!
