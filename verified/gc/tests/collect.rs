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

//! Tests of the collector on concrete heaps (plain Rust: the ghost
//! arguments are erased, `Ghost::assume_new`/`Tracked::assume_new` stand in
//! for them). Heaps use the VM's object layouts (layout.rs): a class
//! table, instances, tasks, arrays, strings and byte arrays (internal and
//! external), doubles, large integers, stacks; oddballs in the program heap.
//!
//! Every collection is checked against an independent reference: the
//! from-space objects reachable from the roots (a breadth-first search
//! over the heap as built), the result read back from the to-space pages
//! (each page parsed from its start up to its used words, a zero sentinel
//! after them), and the old and new graphs compared up to renumbering by
//! walking them from the roots in parallel. Plus: the page count bound,
//! the failure cases (nothing changed).

use std::collections::{HashMap, HashSet, VecDeque};
use toit_gc::model::Ctx;
use toit_gc::space::PageSource;
use toit_gc::statement::{collect, GcError, Window};
use vstd::prelude::*;

const W: usize = std::mem::size_of::<usize>();

// ---------------------------------------------------------------------------
// A deterministic generator (xorshift64*).

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % (n as u64)) as usize
    }
}

// ---------------------------------------------------------------------------
// Memory: one arena of words; pages are carved out of it (one provenance,
// as the heap's exposed provenance in the VM).

struct Arena {
    words: Vec<usize>,
    pw: usize,
    /// Page indices of the arena not in use.
    free: Vec<usize>,
}

impl Arena {
    fn new(pages: usize, pw: usize) -> Arena {
        Arena { words: vec![0xdead_beef; pages * pw], pw, free: (0..pages).rev().collect() }
    }
    fn base(&mut self) -> *mut usize {
        self.words.as_mut_ptr()
    }
    fn page_addr(&mut self, p: usize) -> usize {
        self.base() as usize + p * self.pw * W
    }
    fn alloc(&mut self) -> Option<usize> {
        let p = self.free.pop()?;
        Some(self.page_addr(p))
    }
    fn read(&self, addr: usize) -> usize {
        let i = (addr - self.words.as_ptr() as usize) / W;
        self.words[i]
    }
    fn write(&mut self, addr: usize, v: usize) {
        let i = (addr - self.words.as_ptr() as usize) / W;
        self.words[i] = v;
    }
}

/// A page source over the arena: reserves while enough pages are free.
struct Source<'a> {
    arena: &'a mut Arena,
    reserved: usize,
    taken: usize,
    /// Fail every reservation (the failure case).
    refuse: bool,
    /// The pages asked for.
    asked: usize,
}

impl<'a> PageSource for Source<'a> {
    fn reserve(&mut self, n: usize) -> bool {
        self.asked = n;
        if self.refuse || self.arena.free.len() < n {
            return false;
        }
        self.reserved = n;
        true
    }
    fn take(&mut self, _key: Ghost<int>) -> (usize, Tracked<Map<(int, int), vstd::raw_ptr::PointsTo<usize>>>) {
        assert!(self.reserved > 0, "take without reservation");
        self.reserved -= 1;
        self.taken += 1;
        let a = self.arena.alloc().expect("reserved page");
        // Fill the page with garbage: the collector must not read it.
        for k in 0..self.arena.pw {
            self.arena.write(a + k * W, 0x5a5a_5a5b);
        }
        (a, Tracked::assume_new())
    }
    fn release(&mut self) {
        self.reserved = 0;
    }
}


// ---------------------------------------------------------------------------
// Heaps in the VM's layouts.

#[derive(Clone, Debug, PartialEq)]
enum V {
    Ref(usize), // object index
    Smi(usize), // an even word
    Raw(usize), // any word, outside reference slots
}

/// An object: all its words (header included) and its reference slots.
#[derive(Clone, Debug)]
struct Obj {
    words: Vec<V>,
    lo: usize,
    hi: usize,
}

#[cfg(target_pointer_width = "64")]
const VALUE_WORDS: usize = 1;
#[cfg(target_pointer_width = "32")]
const VALUE_WORDS: usize = 2;
const CONTENT: usize = 2 * W;
const SHIFT: usize = 4 * W; // the string length half word in word 1
const MASK: usize = if W == 8 { 0xffff_ffff } else { 0xffff };

// The class table: tags of src/objects.h; instance classes 8 + k have k fields.
const CLS_ARRAY: usize = 0;
const CLS_STRING: usize = 1;
const CLS_BYTES: usize = 2;
const CLS_DOUBLE: usize = 3;
const CLS_LARGE: usize = 4;
const CLS_STACK: usize = 5;
const CLS_ODDBALL: usize = 6;
const CLS_TASK: usize = 7;
const CLS_INST: usize = 8;
const MAX_FIELDS: usize = 24;
const TASK_FIELDS: usize = 3;

fn class_table() -> Vec<u16> {
    let mut cb = vec![0u16; CLS_INST + MAX_FIELDS + 1];
    cb[CLS_ARRAY] = 0;
    cb[CLS_STRING] = 1;
    cb[CLS_BYTES] = 5;
    cb[CLS_DOUBLE] = 4;
    cb[CLS_LARGE] = 6;
    cb[CLS_STACK] = 7;
    cb[CLS_ODDBALL] = (1 << 5) | 3;
    cb[CLS_TASK] = (((1 + TASK_FIELDS) as u16) << 5) | 8;
    for k in 0..=MAX_FIELDS {
        cb[CLS_INST + k] = (((1 + k) as u16) << 5) | 2;
    }
    cb
}

fn hdr(cid: usize, tag: usize) -> V { V::Raw(((cid << 5) | tag) << 1) }

fn inst(fields: Vec<V>) -> Obj {
    let k = fields.len();
    let mut w = vec![hdr(CLS_INST + k, 2)];
    w.extend(fields);
    Obj { words: w, lo: 1, hi: 1 + k }
}

fn task(fields: Vec<V>) -> Obj {
    assert_eq!(fields.len(), TASK_FIELDS);
    let mut w = vec![hdr(CLS_TASK, 8)];
    w.extend(fields);
    Obj { words: w, lo: 1, hi: 1 + TASK_FIELDS }
}

fn arr(elems: Vec<V>) -> Obj {
    let n = elems.len();
    let mut w = vec![hdr(CLS_ARRAY, 0), V::Raw(n)];
    w.extend(elems);
    Obj { words: w, lo: 2, hi: 2 + n }
}

fn raw_tail(n: usize, seed: usize) -> Vec<V> {
    (0..n).map(|k| V::Raw(seed.wrapping_mul(0x9e37_79b9).wrapping_add(k * 0x0101_0101) | 1)).collect()
}

fn string(len: usize, seed: usize) -> Obj {
    let size = (CONTENT + len + 1 + W - 1) / W;
    let mut w = vec![hdr(CLS_STRING, 1), V::Raw((len << SHIFT) | (seed & 0xff))];
    w.extend(raw_tail(size - 2, seed));
    Obj { words: w, lo: size, hi: size }
}

fn string_ext(len: usize, seed: usize) -> Obj {
    let w = vec![hdr(CLS_STRING, 1), V::Raw((0xffff << SHIFT) | 7), V::Raw(len), V::Raw(0x4000_1001 + seed * 8)];
    Obj { words: w, lo: 4, hi: 4 }
}

fn bytes(len: usize, seed: usize) -> Obj {
    let size = (CONTENT + len + W - 1) / W;
    let mut w = vec![hdr(CLS_BYTES, 5), V::Raw(len)];
    w.extend(raw_tail(size - 2, seed));
    Obj { words: w, lo: size, hi: size }
}

fn bytes_ext(len: usize, tag: usize) -> Obj {
    // A negative raw length -1 - len; an address that looks like a tagged pointer.
    let w = vec![hdr(CLS_BYTES, 5), V::Raw(usize::MAX - len), V::Raw(0x2000_0003), V::Raw(tag)];
    Obj { words: w, lo: 4, hi: 4 }
}

fn double(bits: u64) -> Obj {
    let mut w = vec![hdr(CLS_DOUBLE, 4)];
    for k in 0..VALUE_WORDS { w.push(V::Raw((bits >> (32 * k)) as usize | 1)); }
    Obj { lo: w.len(), hi: w.len(), words: w }
}

fn large(x: u64) -> Obj {
    let mut w = vec![hdr(CLS_LARGE, 6)];
    for k in 0..VALUE_WORDS { w.push(V::Raw((x >> (32 * k)) as usize)); }
    Obj { lo: w.len(), hi: w.len(), words: w }
}

/// A stack of `len` array words, the frame records below `top` (raw), the
/// object stack `values` above it.
fn stack(sw: usize, top: usize, values: Vec<V>) -> Obj {
    let len = top + values.len();
    let mut w = vec![hdr(CLS_STACK, 7), V::Raw(0), V::Raw(len), V::Raw(top), V::Raw(top | (top << 16)), V::Raw(17)];
    while w.len() < sw { w.push(V::Raw(0xcaad_abe7)); }
    for k in 0..top { w.push(V::Raw(k * 3 + 1)); }
    w.extend(values);
    Obj { words: w, lo: sw + top, hi: sw + len }
}

fn oddball() -> Obj {
    Obj { words: vec![hdr(CLS_ODDBALL, 3)], lo: 1, hi: 1 }
}

/// A built heap: objects (the first `nprog` are the program heap, outside
/// from-space), their addresses, the from-space pages, the roots, the
/// stack array word.
struct Heap {
    objs: Vec<Obj>,
    nprog: usize,
    addr: Vec<usize>,
    fpages: Vec<usize>,
    roots: Vec<V>,
    sw: usize,
    /// Finalizer nodes (kind, key, lambda): callback and queued nodes first,
    /// then VM finalizers.
    nodes: Vec<(usize, V, V)>,
    /// Give the collector the pages' used words (the tail bound).
    tail: bool,
}

fn enc(h: &Heap, v: &V) -> usize {
    match v {
        V::Ref(i) => h.addr[*i],
        V::Smi(w) | V::Raw(w) => *w,
    }
}

/// Lays out the objects: program objects next-fit in their own pages (not
/// in the table), heap objects next-fit in from-space pages (an object that
/// does not fit below the sentinel word starts a new page). `shuffle_pages`
/// takes pages out of order from the arena (the table is sorted anyway).
fn build(arena: &mut Arena, objs: Vec<Obj>, nprog: usize, roots: Vec<V>, sw: usize, rng: &mut Rng, shuffle_pages: bool) -> Heap {
    let pw = arena.pw;
    if shuffle_pages {
        let n = arena.free.len();
        for i in 0..n {
            let j = i + rng.below(n - i);
            arena.free.swap(i, j);
        }
    }
    let mut addr = vec![0; objs.len()];
    let mut fpages = vec![];
    let place = |arena: &mut Arena, pages: &mut Vec<usize>, cur: &mut Option<(usize, usize)>, words: usize| -> usize {
        assert!(words <= pw - 1, "object of {} words in pages of {}", words, pw);
        match cur {
            Some((p, top)) if *top + words <= pw - 1 => {
                let a = *p + *top * W;
                *top += words;
                a
            }
            _ => {
                let p = arena.alloc().expect("arena too small");
                pages.push(p);
                *cur = Some((p, words));
                p
            }
        }
    };
    let mut prog_pages = vec![];
    let mut pcur = None;
    let mut fcur = None;
    for (i, o) in objs.iter().enumerate() {
        let a = if i < nprog {
            place(arena, &mut prog_pages, &mut pcur, o.words.len())
        } else {
            place(arena, &mut fpages, &mut fcur, o.words.len())
        };
        addr[i] = a + 1;
    }
    let mut h = Heap { objs, nprog, addr, fpages, roots, sw, nodes: vec![], tail: false };
    for (i, o) in h.objs.iter().enumerate() {
        let a = h.addr[i] - 1;
        for (k, v) in o.words.iter().enumerate() {
            arena.write(a + k * W, enc(&h, v));
        }
    }
    h.fpages.sort();
    h
}


const NULL: usize = 0x11; // the null object's address in these tests (outside every page)
const FBIT: usize = 32; // the finalizer bit of a header word

/// Adds finalizer nodes; the keys of the active ones get the finalizer bit.
fn add_nodes(arena: &mut Arena, h: &mut Heap, nodes: Vec<(usize, V, V)>, active: &[bool]) {
    for (n, (_, key, _)) in nodes.iter().enumerate() {
        if let V::Ref(k) = key {
            if active[n] {
                if let V::Raw(hd) = h.objs[*k].words[0] {
                    h.objs[*k].words[0] = V::Raw(hd | FBIT);
                    arena.write(h.addr[*k] - 1, hd | FBIT);
                }
            }
        }
    }
    h.nodes = nodes;
}

fn header_bit(o: &Obj) -> bool {
    matches!(o.words[0], V::Raw(hd) if hd & FBIT != 0)
}

/// The from-space objects reachable from `start` in `objs`.
fn closure(objs: &[Obj], nprog: usize, start: impl IntoIterator<Item = usize>) -> HashSet<usize> {
    let mut seen = HashSet::new();
    let mut q: VecDeque<usize> = start.into_iter().collect();
    while let Some(i) = q.pop_front() {
        if !seen.insert(i) { continue; }
        let o = &objs[i];
        for v in &o.words[o.lo..o.hi] {
            if let V::Ref(j) = v { q.push_back(*j); }
        }
    }
    seen.retain(|i| *i >= nprog);
    seen
}

/// The expected result, written out from src/heap_roots.cc (without the
/// zapping of live weak maps' values): the verdict of each node, the heap
/// after the finalizer pass (dead keys killed), and the copies.
fn expected(h: &Heap) -> (Vec<usize>, Vec<Obj>, HashSet<usize>) {
    let roots = h.roots.iter().filter_map(|v| if let V::Ref(i) = v { Some(*i) } else { None });
    let mut copied = closure(&h.objs, h.nprog, roots);
    let mut objs = h.objs.clone();
    let mut verdicts = vec![];
    let from = |v: &V| matches!(v, V::Ref(i) if *i >= h.nprog);
    let idx = |v: &V| if let V::Ref(i) = v { *i } else { usize::MAX };
    for (kind, key, lam) in &h.nodes {
        if *kind == 4 { continue; }
        let active = from(key) && header_bit(&objs[idx(key)]);
        let alive = !from(key) || copied.contains(&idx(key));
        if *kind == 2 {
            verdicts.push(0);
            if from(key) { copied.insert(idx(key)); }
            if from(lam) { copied.insert(idx(lam)); }
        } else if !active {
            verdicts.push(2);
        } else if alive {
            verdicts.push(0);
            if from(lam) { copied.insert(idx(lam)); }
        } else if *kind == 0 {
            verdicts.push(1);
            let k = idx(key);
            if let V::Raw(hd) = objs[k].words[0] { objs[k].words[0] = V::Raw(hd & !FBIT); }
            if from(lam) { copied.insert(idx(lam)); }
        } else {
            verdicts.push(2);
            let k = idx(key);
            if let V::Raw(hd) = objs[k].words[0] { objs[k].words[0] = V::Raw(hd & !FBIT); }
            if objs[k].lo == 1 && objs[k].hi >= 5 {
                objs[k].words[1] = V::Raw(0);
                objs[k].words[2] = V::Raw(0);
                objs[k].words[3] = V::Raw(NULL);
                objs[k].words[4] = V::Raw(NULL);
            }
        }
    }
    let copied = closure(&objs, h.nprog, copied);
    for (kind, key, _) in &h.nodes {
        if *kind != 4 { continue; }
        let active = from(key) && header_bit(&objs[idx(key)]);
        verdicts.push(if !active { 2 } else if copied.contains(&idx(key)) { 0 } else { 3 });
    }
    (verdicts, objs, copied)
}

/// The from-space objects reachable from the roots.
fn reachable(h: &Heap) -> HashSet<usize> {
    let roots = h.roots.iter().filter_map(|v| if let V::Ref(i) = v { Some(*i) } else { None });
    closure(&h.objs, h.nprog, roots)
}

/// Runs a collection and checks it.
fn run(arena: &mut Arena, h: &Heap, tcap_extra: isize, refuse: bool) -> Result<(Window, Vec<usize>, Vec<usize>), GcError> {
    let pw = arena.pw;
    let nf = h.fpages.len();
    let mut cb = class_table();
    let mut ftab = h.fpages.clone();
    let mut rootw: Vec<usize> = h.roots.iter().map(|v| enc(h, v)).collect();
    let tcap = ((2 * nf + 1) as isize + tcap_extra).max(0) as usize;
    let mut ttab = vec![0usize; tcap.max(1)];
    let mut tused = vec![0usize; tcap.max(1)];
    let ncb = h.nodes.iter().filter(|n| n.0 != 4).count();
    let mut nodew: Vec<usize> = vec![];
    for (kind, key, lam) in &h.nodes {
        nodew.extend([*kind, enc(h, key), enc(h, lam), 99]);
    }
    nodew.push(0);
    let nodes_before = nodew.clone();
    // The used words of each from-space page and the largest object (an
    // oracle for the tail bound).
    let mut fused = vec![0usize; nf.max(1)];
    let mut mx = 1usize;
    for (i, o) in h.objs.iter().enumerate().skip(h.nprog) {
        let a = h.addr[i] - 1;
        let p = h.fpages.iter().position(|s| a >= *s && a < *s + pw * W).unwrap();
        fused[p] = fused[p].max((a - h.fpages[p]) / W + o.words.len());
        mx = mx.max(o.words.len());
    }
    let rs = if h.tail { (2 * nf + 1).min(nf * pw / (pw - mx) + 1) } else { 2 * nf + 1 };
    let before: Vec<usize> = arena.words.clone();
    let roots_before = rootw.clone();
    let c = Ctx { base: arena.base(), ftab: ftab.as_mut_ptr(), nf, pw, ctab: cb.as_mut_ptr(), ncls: cb.len(), sw: h.sw,
                  null: NULL, nullid: Ghost::assume_new(), fused: fused.as_mut_ptr(), tail: h.tail, fss: Ghost::assume_new(), cbs: Ghost::assume_new() };
    let mut src = Source { arena, reserved: 0, taken: 0, refuse, asked: 0 };
    let r = collect(&c, &mut src, rootw.as_mut_ptr(), rootw.len(), ttab.as_mut_ptr(), tused.as_mut_ptr(), tcap,
                    nodew.as_mut_ptr(), ncb, h.nodes.len(),
                    Ghost::assume_new(), Ghost::assume_new(), Ghost::assume_new(), Tracked::assume_new(), Tracked::assume_new(),
                    Tracked::assume_new());
    let taken = src.taken;
    let asked = src.asked;
    match r {
        Err(e) => {
            // Nothing changed.
            assert_eq!(taken, 0);
            assert!(arena.words == before, "memory changed on failure");
            assert_eq!(rootw, roots_before, "roots changed on failure");
            assert_eq!(nodew, nodes_before, "nodes changed on failure");
            Err(e)
        }
        Ok(w) => {
            assert!(taken <= rs, "{} pages taken, reservation {}", taken, rs);
            assert_eq!(asked, rs, "reservation");
            check(arena, &cb, h, &rootw, &nodew, &ttab[..w.pages], &tused[..w.pages], &w, taken);
            let (a, b) = (ttab[..w.pages].to_vec(), tused[..w.pages].to_vec());
            Ok((w, a, b))
        }
    }
}

fn check(arena: &Arena, cb: &[u16], h: &Heap, rootw: &[usize], nodew: &[usize], ttab: &[usize], tused: &[usize], w: &Window,
         taken: usize) {
    let pw = arena.pw;
    let nf = h.fpages.len();
    assert!(w.pages >= 1 && w.pages <= 2 * nf + 1, "pages {} for nf {}", w.pages, nf);
    assert_eq!(w.pages, taken);
    assert_eq!(tused[w.pages - 1], w.top);
    // Parse the to-space pages.
    let mut copies = HashSet::new();
    for p in 0..w.pages {
        assert!(tused[p] <= pw - 1);
        assert_eq!(arena.read(ttab[p] + tused[p] * W), 0, "sentinel of page {}", p);
        let mut off = 0;
        while off < tused[p] {
            let a = ttab[p] + off * W;
            copies.insert(a + 1);
            off += size_at(arena, cb, h.sw, a);
        }
        assert_eq!(off, tused[p], "objects end at the used words of page {}", p);
    }
    let (verdicts, objs, live) = expected(h);
    assert_eq!(copies.len(), live.len(), "copies vs expected survivors");
    // The nodes: verdicts, and the slots to walk from.
    let mut q = VecDeque::new();
    let mut start = |v: &V, word: usize, what: String, q: &mut VecDeque<(usize, usize)>| match v {
        V::Ref(j) if *j >= h.nprog => {
            assert!(copies.contains(&word), "{} not to a copy", what);
            q.push_back((*j, word));
        }
        _ => assert_eq!(word, enc(h, v), "{} changed", what),
    };
    for (n, (kind, key, lam)) in h.nodes.iter().enumerate() {
        let d = nodew[4 * n + 3];
        assert_eq!(d, verdicts[n], "verdict of node {} (kind {})", n, kind);
        match d {
            0 => {
                start(key, nodew[4 * n + 1], format!("key of node {}", n), &mut q);
                if *kind != 4 { start(lam, nodew[4 * n + 2], format!("lambda of node {}", n), &mut q); }
            }
            1 => {
                assert_eq!(nodew[4 * n + 1], NULL, "key of queued node {}", n);
                start(lam, nodew[4 * n + 2], format!("lambda of node {}", n), &mut q);
            }
            _ => {}
        }
        // A killed key: its words in from-space are the killed object's.
        if let V::Ref(k) = key {
            if *k >= h.nprog && (d == 1 || (d == 2 && *kind != 4 && header_bit(&h.objs[*k]) && !header_bit(&objs[*k]))) {
                let a = h.addr[*k] - 1;
                let hd = arena.read(a);
                if hd % 2 == 0 {
                    for (i, v) in objs[*k].words.iter().enumerate() {
                        if i < 5 { assert_eq!(arena.read(a + i * W), enc(h, v), "word {} of killed key {}", i, k); }
                    }
                }
            }
        }
    }
    for (i, v) in h.roots.iter().enumerate() {
        start(v, rootw[i], format!("root {}", i), &mut q);
    }
    // Compare the graphs (against the heap after the finalizer pass).
    let mut map: HashMap<usize, usize> = HashMap::new(); // old index -> new address
    while let Some((j, na)) = q.pop_front() {
        if let Some(prev) = map.get(&j) {
            assert_eq!(*prev, na, "object {} copied twice", j);
            continue;
        }
        map.insert(j, na);
        let o = &objs[j];
        let a = na - 1;
        assert_eq!(size_at(arena, cb, h.sw, a), o.words.len(), "size of {}", j);
        for (k, v) in o.words.iter().enumerate() {
            let word = arena.read(a + k * W);
            match v {
                V::Ref(t) if *t >= h.nprog && k >= o.lo && k < o.hi => {
                    assert!(copies.contains(&word), "word {} of {} not to a copy", k, j);
                    q.push_back((*t, word));
                }
                _ => assert_eq!(word, enc(h, v), "word {} of {}", k, j),
            }
        }
    }
    assert_eq!(map.len(), live.len());
    let targets: HashSet<usize> = map.values().cloned().collect();
    assert_eq!(targets.len(), map.len(), "distinct copies");
}
/// The size in words of the object at `a` (untagged) in to-space: the C++
/// `HeapObject::size`, written out again (an oracle independent of the
/// verified code).
fn size_at(arena: &Arena, cb: &[u16], sw: usize, a: usize) -> usize {
    let hd = arena.read(a);
    assert_eq!(hd % 2, 0, "header expected at {:#x}", a);
    let v = hd >> 1;
    let (tag, cid) = (v & 15, v >> 5);
    match tag {
        0 => 2 + arena.read(a + W),
        1 => {
            let l = (arena.read(a + W) >> SHIFT) & MASK;
            if l == 0xffff { 4 } else { (CONTENT + l + 1 + W - 1) / W }
        }
        2 | 3 | 8 => ((cb[cid] >> 5) & 0x7ff) as usize,
        4 | 6 => 1 + VALUE_WORDS,
        5 => {
            let r = arena.read(a + W) as isize;
            if r >= 0 { (CONTENT + r as usize + W - 1) / W } else { 4 }
        }
        7 => sw + arena.read(a + 2 * W),
        _ => panic!("bad tag {}", tag),
    }
}

// ---------------------------------------------------------------------------
// Generators.

fn value(rng: &mut Rng, n: usize, refs_below: usize) -> V {
    match rng.below(4) {
        0 => V::Smi((rng.next() as usize) & !1),
        _ => V::Ref(rng.below(refs_below.max(1)).min(n - 1)),
    }
}

/// A random object of at most `maxw` words referring to objects below
/// `refs_below` (of `n`).
fn random_obj(rng: &mut Rng, n: usize, refs_below: usize, maxw: usize, sw: usize) -> Obj {
    loop {
        let o = match rng.below(10) {
            0 | 1 => {
                let k = rng.below(MAX_FIELDS.min(maxw - 1) + 1);
                inst((0..k).map(|_| value(rng, n, refs_below)).collect())
            }
            2 | 3 => {
                let k = rng.below(maxw - 1);
                arr((0..k).map(|_| value(rng, n, refs_below)).collect())
            }
            4 => task((0..TASK_FIELDS).map(|_| value(rng, n, refs_below)).collect()),
            5 => if rng.below(3) == 0 { string_ext(rng.below(5000), rng.below(1000)) } else { string(rng.below(maxw * W), rng.below(1000)) },
            6 => if rng.below(3) == 0 { bytes_ext(rng.below(9000), rng.below(3)) } else { bytes(rng.below(maxw * W), rng.below(1000)) },
            7 => double(rng.next()),
            8 => large(rng.next()),
            _ => {
                if maxw < sw + 2 { continue; }
                let len = rng.below(maxw - sw);
                let top = rng.below(len + 1);
                stack(sw, top, (0..len - top).map(|_| value(rng, n, refs_below)).collect())
            }
        };
        if o.words.len() <= maxw { return o; }
    }
}

/// A random heap of `n` objects (the first `nprog` program objects that
/// refer only to program objects, oddballs among them), `nroots` roots.
fn random_heap(rng: &mut Rng, n: usize, nprog: usize, nroots: usize, maxw: usize, sw: usize) -> (Vec<Obj>, Vec<V>) {
    let mut objs = vec![];
    for i in 0..n {
        if i < nprog {
            if rng.below(3) == 0 { objs.push(oddball()); } else { objs.push(random_obj(rng, n, nprog, maxw, sw)); }
        } else {
            objs.push(random_obj(rng, n, n, maxw, sw));
        }
    }
    let mut roots = vec![];
    for _ in 0..nroots {
        if rng.below(4) == 0 { roots.push(V::Smi(2 * rng.below(1000))); } else { roots.push(V::Ref(rng.below(n))); }
    }
    (objs, roots)
}

// ---------------------------------------------------------------------------
// Tests.

const PW: usize = 32;
const SW: usize = 10;

fn heap(arena: &mut Arena, objs: Vec<Obj>, nprog: usize, roots: Vec<V>) -> Heap {
    let mut rng = Rng(1);
    build(arena, objs, nprog, roots, SW, &mut rng, false)
}

#[test]
fn every_kind() {
    let mut arena = Arena::new(64, PW);
    let objs = vec![
        oddball(),                                                   // 0: null (program heap)
        inst(vec![V::Ref(0)]),                                       // 1: program instance
        inst(vec![V::Ref(3), V::Ref(4), V::Ref(1), V::Smi(6)]),      // 2
        arr(vec![V::Ref(2), V::Ref(5), V::Ref(6), V::Ref(7), V::Ref(8), V::Ref(9), V::Ref(10)]), // 3: cycle via 2
        task(vec![V::Ref(11), V::Ref(0), V::Smi(2)]),                // 4
        string(13, 1),                                               // 5
        string_ext(9000, 2),                                         // 6
        bytes(21, 3),                                                // 7
        bytes_ext(70000, 0),                                         // 8
        double(0x4009_21fb_5444_2d18),                               // 9
        large(0xffff_ffff_0000_0001),                                // 10
        stack(SW, 3, vec![V::Ref(2), V::Smi(8), V::Ref(4), V::Ref(12)]), // 11: refers to its task
        inst(vec![V::Ref(12)]),                                      // 12: self loop
        arr(vec![V::Ref(2)]),                                        // 13: garbage
    ];
    let h = heap(&mut arena, objs, 2, vec![V::Ref(2), V::Smi(10), V::Ref(0), V::Ref(2)]);
    run(&mut arena, &h, 0, false).ok().unwrap();
}

#[test]
fn stack_slots_only_above_top() {
    // A record below the top that holds a from-space address must not be
    // forwarded (it is raw); the object stack slots are.
    let mut arena = Arena::new(16, PW);
    let objs = vec![inst(vec![V::Smi(2)]), stack(SW, 0, vec![V::Ref(0)])];
    let mut h = heap(&mut arena, objs, 0, vec![V::Ref(1)]);
    // Put object 0's address in a record word (below top): top = 1 now.
    let mut s = stack(SW, 1, vec![V::Ref(0)]);
    s.words[SW] = V::Raw(h.addr[0]);
    h.objs[1] = s.clone();
    let a = h.addr[1] - 1;
    for (k, v) in s.words.iter().enumerate() { arena.write(a + k * W, enc(&h, v)); }
    run(&mut arena, &h, 0, false).ok().unwrap();
}

#[test]
fn nothing_survives() {
    let mut arena = Arena::new(16, PW);
    let objs = vec![inst(vec![V::Smi(2)]), inst(vec![])];
    let h = heap(&mut arena, objs, 0, vec![V::Smi(8)]);
    let (w, _, tused) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!((w.pages, w.top, tused[0]), (1, 0, 0));
}

#[test]
fn no_from_space() {
    // Only program objects; nf = 0: the window page is the only page.
    let mut arena = Arena::new(8, PW);
    let objs = vec![oddball(), inst(vec![V::Ref(0)])];
    let h = heap(&mut arena, objs, 2, vec![V::Ref(1)]);
    let (w, _, _) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!(w.pages, 1);
}

#[test]
fn exactly_full_pages() {
    // Arrays of pw - 1 words fill a page up to its sentinel word.
    let mut arena = Arena::new(64, PW);
    let mut objs = vec![];
    for i in 0..5 {
        objs.push(arr((0..PW - 3).map(|k| if k == 0 && i < 4 { V::Ref(i + 1) } else { V::Smi(2 * k) }).collect()));
    }
    let h = heap(&mut arena, objs, 0, vec![V::Ref(0)]);
    assert_eq!(h.fpages.len(), 5);
    let (w, _, tused) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!(w.pages, 5);
    assert!(tused.iter().all(|u| *u == PW - 1));
}

#[test]
fn object_spanning_the_page_end() {
    // A 17-word array after a 17-word one does not fit a 31-word page: it
    // starts the next page (page-tail waste).
    let mut arena = Arena::new(64, PW);
    let fill = |next: V| arr(std::iter::once(next).chain((1..15).map(|k| V::Smi(2 * k))).collect());
    let objs = vec![fill(V::Ref(1)), fill(V::Ref(2)), inst(vec![V::Smi(2)])];
    let h = heap(&mut arena, objs, 0, vec![V::Ref(0)]);
    let (w, _, tused) = run(&mut arena, &h, 0, false).ok().unwrap();
    assert_eq!(w.pages, 2);
    assert_eq!(tused, vec![17, 19]);
}

#[test]
fn worst_case_placement() {
    // Alternating 16- and 2-word survivors: every page wastes words, the
    // bound 2 nf + 1 holds.
    let mut arena = Arena::new(400, PW);
    let mut objs = vec![];
    let n = 40;
    for i in 0..n {
        let next = if i + 1 < n { V::Ref(i + 1) } else { V::Smi(0) };
        if i % 2 == 0 {
            objs.push(arr(std::iter::once(next).chain((1..14).map(|k| V::Smi(2 * k))).collect()));
        } else {
            objs.push(inst(vec![next]));
        }
    }
    let h = heap(&mut arena, objs.clone(), 0, vec![V::Ref(0)]);
    run(&mut arena, &h, 0, false).ok().unwrap();
    let mut arena = Arena::new(400, PW);
    let mut h = heap(&mut arena, objs, 0, vec![V::Ref(0)]);
    // With the tail bound (largest object 16 words of 32): at most
    // floor(nf * 32 / 16) + 1 = 2 nf + 1 pages, the same here.
    h.tail = true;
    run(&mut arena, &h, 0, false).ok().unwrap();
}

#[test]
fn tail_bound_small_objects() {
    // Survivors of at most 4 words in pages of 32: the tail bound reserves
    // floor(nf * 32 / 28) + 1 pages instead of 2 nf + 1, and the collection
    // fits (the test source refuses a take beyond the reservation).
    let mut rng = Rng(11);
    for _ in 0..50 {
        let n = 20 + rng.below(200);
        let mut objs = vec![];
        for i in 0..n {
            let next = if i + 1 < n { V::Ref(i + 1) } else { V::Smi(0) };
            match rng.below(3) {
                0 => objs.push(inst(vec![next])),
                1 => objs.push(arr(vec![next, V::Smi(4)])),
                _ => objs.push(inst(vec![next, V::Ref(rng.below(n)), V::Smi(2)])),
            }
        }
        let mut arena = Arena::new(600, PW);
        let mut h = build(&mut arena, objs, 0, vec![V::Ref(0)], SW, &mut rng, true);
        h.tail = true;
        run(&mut arena, &h, 0, false).ok().unwrap();
    }
}

#[test]
fn reservation_failure_changes_nothing() {
    // Too few free pages for the reservation, at every count below it.
    let mut rng = Rng(7);
    let (objs, roots) = random_heap(&mut rng, 60, 4, 6, 12, SW);
    for spare in 0..64 {
        let mut arena = Arena::new(96, PW);
        let h = build(&mut arena, objs.clone(), 4, roots.clone(), SW, &mut rng, false);
        let need = 2 * h.fpages.len() + 1;
        while arena.free.len() > spare { arena.free.pop(); }
        let r = run(&mut arena, &h, 0, false);
        if spare >= need {
            assert!(r.is_ok());
        } else {
            assert!(matches!(r, Err(GcError::NoReservation)));
        }
    }
    let mut arena = Arena::new(96, PW);
    let h = build(&mut arena, objs, 4, roots, SW, &mut rng, false);
    assert!(matches!(run(&mut arena, &h, 0, true), Err(GcError::NoReservation)));
}

#[test]
fn small_table_changes_nothing() {
    let mut rng = Rng(9);
    let (objs, roots) = random_heap(&mut rng, 40, 2, 4, 12, SW);
    let mut arena = Arena::new(96, PW);
    let h = build(&mut arena, objs, 2, roots, SW, &mut rng, false);
    assert!(matches!(run(&mut arena, &h, -1, false), Err(GcError::SmallTable)));
}

#[test]
fn bad_table_changes_nothing() {
    let mut rng = Rng(11);
    let (objs, roots) = random_heap(&mut rng, 60, 2, 4, 12, SW);
    let mut arena = Arena::new(96, PW);
    let mut h = build(&mut arena, objs, 2, roots, SW, &mut rng, false);
    assert!(h.fpages.len() >= 2);
    h.fpages.swap(0, 1);
    assert!(matches!(run(&mut arena, &h, 0, false), Err(GcError::BadFromTable)));
}

#[test]
fn random_graphs() {
    for seed in 1..600u64 {
        let mut rng = Rng(seed * 0x9e37_79b9_7f4a_7c15 + 1);
        let sw = if rng.below(2) == 0 { 10 } else { 14 };
        let pw = [24, 32, 64, 128][rng.below(4)];
        let n = 1 + rng.below(150);
        let nprog = rng.below(n.min(8) + 1);
        let nroots = rng.below(12);
        let maxw = 3 + rng.below(pw - 4);
        let (objs, roots) = random_heap(&mut rng, n, nprog, nroots, maxw, sw);
        let mut arena = Arena::new(1200, pw);
        let mut h = build(&mut arena, objs, nprog, roots, sw, &mut rng, seed % 2 == 0);
        h.tail = seed % 3 != 0;
        run(&mut arena, &h, 0, false).ok().unwrap();
    }
}

// ---------------------------------------------------------------------------
// Finalizers.

#[test]
fn finalizers() {
    let mut arena = Arena::new(64, PW);
    let objs = vec![
        oddball(),                                                  // 0: program heap
        inst(vec![V::Ref(2), V::Ref(3)]),                           // 1: root holder
        inst(vec![V::Smi(2)]),                                      // 2: live key (Toit finalizer)
        inst(vec![V::Ref(9), V::Smi(0), V::Ref(4), V::Ref(5)]),     // 3: live weak map
        arr(vec![V::Smi(4)]),                                       // 4
        arr(vec![V::Ref(6)]),                                       // 5
        inst(vec![V::Smi(6)]),                                      // 6
        inst(vec![V::Smi(8)]),                                      // 7: dead key (Toit finalizer)
        inst(vec![V::Ref(8), V::Ref(12)]),                          // 8: its lambda (revived), refers to the dead map
        bytes_ext(100, 0),                                          // 9: live VM key
        bytes_ext(200, 0),                                          // 10: dead VM key
        inst(vec![V::Smi(10)]),                                     // 11: inactive key
        inst(vec![V::Ref(13), V::Smi(2), V::Ref(4), V::Ref(13)]),   // 12: dead weak map (revived by 8)
        arr(vec![V::Smi(12)]),                                      // 13
        inst(vec![V::Ref(14)]),                                     // 14: lambda of the live key
        bytes_ext(300, 0),                                          // 15: VM key reached only from a queued lambda
        inst(vec![V::Ref(15)]),                                     // 16: queued node's lambda
        inst(vec![V::Smi(14)]),                                     // 17: queued node's key (otherwise dead)
    ];
    let mut h = heap(&mut arena, objs, 1, vec![V::Ref(1), V::Ref(0)]);
    let nodes = vec![
        (0, V::Ref(2), V::Ref(14)),   // KEEP
        (1, V::Ref(3), V::Ref(14)),   // KEEP (weak map traced strongly)
        (0, V::Ref(7), V::Ref(8)),    // QUEUE: key dead, lambda revived
        (0, V::Ref(11), V::Ref(14)),  // DELETE: no finalizer bit
        (1, V::Ref(12), V::Ref(14)),  // DELETE: dead weak map, reset
        (2, V::Ref(17), V::Ref(16)),  // queued: KEEP, both forwarded
        (4, V::Ref(9), V::Smi(0)),    // KEEP
        (4, V::Ref(10), V::Smi(0)),   // FREE
        (4, V::Ref(15), V::Smi(0)),   // KEEP: reached from a queued lambda
    ];
    let active = [true, true, true, false, true, false, true, true, true];
    add_nodes(&mut arena, &mut h, nodes, &active);
    run(&mut arena, &h, 0, false).ok().unwrap();
}

#[test]
fn random_finalizers() {
    for seed in 1..400u64 {
        let mut rng = Rng(seed * 0x2545_f491_4f6c_dd1d + 7);
        let pw = [32, 64, 128][rng.below(3)];
        let n = 2 + rng.below(120);
        let nprog = 1 + rng.below(4.min(n - 1));
        let nroots = rng.below(6);
        let maxw = 3 + rng.below(pw - 4);
        let (mut objs, roots) = random_heap(&mut rng, n, nprog, nroots, maxw, SW);
        // Some weak maps: instances with at least four fields.
        for i in nprog..n {
            if rng.below(6) == 0 {
                let k = 4 + rng.below(3);
                objs[i] = inst((0..k).map(|_| value(&mut rng, n, n)).collect());
            }
        }
        let mut arena = Arena::new(1200, pw);
        let mut h = build(&mut arena, objs, nprog, roots, SW, &mut rng, seed % 2 == 0);
        h.tail = seed % 2 == 1;
        let mut nodes = vec![];
        let mut active = vec![];
        let mut keys = HashSet::new();
        for _ in 0..rng.below(10) {
            let k = nprog + rng.below(n - nprog);
            if !keys.insert(k) { continue; }
            let is_weak = h.objs[k].lo == 1 && h.objs[k].hi >= 5;
            let kind = if is_weak && rng.below(2) == 0 { 1 } else { [0, 0, 2, 3][rng.below(4)] };
            let kind = if kind == 3 && !is_weak { 0 } else { kind };
            let lam = value(&mut rng, n, n);
            nodes.push((kind, V::Ref(k), lam));
            active.push(rng.below(5) != 0);
        }
        for _ in 0..rng.below(4) {
            let k = nprog + rng.below(n - nprog);
            if !keys.insert(k) { continue; }
            nodes.push((4, V::Ref(k), V::Smi(0)));
            active.push(rng.below(5) != 0);
        }
        add_nodes(&mut arena, &mut h, nodes, &active);
        run(&mut arena, &h, 0, false).ok().unwrap();
    }
}
