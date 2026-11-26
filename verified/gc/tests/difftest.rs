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

//! The differential test: the proved collector against the C++ prototype
//! (src/sandbox_gc.cc) on heaps of real programs.
//!
//! With TOIT_GC_DUMP=DIR the VM writes, around every copying collection of
//! a sandboxed process, the heap before it and after it (src/sandbox_gc.cc,
//! `TwoSpaceHeap::dump_copying_heap`): pages, root values, class bits, the
//! stack array word, the null object's address, the finalizer nodes (list,
//! kind, node, key, lambda). With TOIT_GC_DIFF=DIR this
//! test reads every `*-before.bin` under DIR (dumps of this word size),
//! copies its pages into an arena (relocating the references of the
//! objects reachable from the roots), runs the proved collector, and walks
//! its result and the C++ prototype's (`*-after.bin`) from the roots in
//! parallel: the graphs must be equal up to renumbering. Two differences of
//! the C++ prototype are expected and counted: it shrinks stacks (the object
//! stack moves down; the proved collector does not shrink), and it zaps the
//! values of weak maps no one else reached (null where the proved
//! collector, which traces live weak maps strongly, keeps the reference;
//! such a map the C++ prototype also queues, the proved collector keeps).
//! The finalizer nodes go to the proved collector in the order of the C++
//! lists; its verdicts must equal the C++ ones (where the node is after
//! the collection), and the slots of kept and queued nodes are walked like
//! roots. A verdict that differs only because a key is reachable through a
//! weak map's fields would be counted (weak_divergent), not failed.
//! Without TOIT_GC_DIFF the test does nothing.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use toit_gc::model::Ctx;
use toit_gc::space::PageSource;
use toit_gc::statement::collect;
use vstd::prelude::*;

const W: usize = std::mem::size_of::<usize>();
const CONTENT: usize = 2 * W;
const SHIFT: usize = 4 * W;
const MASK: usize = if W == 8 { 0xffff_ffff } else { 0xffff };
#[cfg(target_pointer_width = "64")]
const VALUE_WORDS: usize = 1;
#[cfg(target_pointer_width = "32")]
const VALUE_WORDS: usize = 2;

struct Page {
    start: usize,
    bytes: usize,
    used: usize,
    words: Vec<usize>,
}

struct Dump {
    sw: usize,
    null: usize,
    cb: Vec<u16>,
    pages: Vec<Page>,
    roots: Vec<usize>,
    /// The finalizer nodes: (list, kind, node, key, lambda); list 0 the
    /// registered callback finalizers, 1 the queue, 2 the VM finalizers;
    /// kind 0 Toit, 1 weak map, 4 VM.
    nodes: Vec<[usize; 5]>,
}

fn read_dump(path: &Path) -> Option<Dump> {
    let data = std::fs::read(path).ok()?;
    let mut pos = 0;
    let mut u64_at = |pos: &mut usize| -> u64 {
        let v = u64::from_le_bytes(data[*pos..*pos + 8].try_into().unwrap());
        *pos += 8;
        v
    };
    if u64_at(&mut pos) != 0x3144_4347_544f_4954 { panic!("{}: not a heap dump", path.display()); }
    if u64_at(&mut pos) as usize != W { return None; } // Another word size.
    let sw = u64_at(&mut pos) as usize;
    let null = u64_at(&mut pos) as usize;
    let ncls = u64_at(&mut pos) as usize;
    let cb = (0..ncls).map(|_| u64_at(&mut pos) as u16).collect();
    let npages = u64_at(&mut pos) as usize;
    let mut pages = vec![];
    for _ in 0..npages {
        let start = u64_at(&mut pos) as usize;
        let bytes = u64_at(&mut pos) as usize;
        let used = u64_at(&mut pos) as usize;
        let words = data[pos..pos + bytes].chunks(W).map(|c| usize::from_le_bytes(c.try_into().unwrap())).collect();
        pos += bytes;
        pages.push(Page { start, bytes, used, words });
    }
    let nroots = u64_at(&mut pos) as usize;
    let roots = (0..nroots).map(|_| u64_at(&mut pos) as usize).collect();
    let mut nodes = vec![];
    if pos < data.len() {
        let nn = u64_at(&mut pos) as usize;
        for _ in 0..nn {
            let mut n = [0usize; 5];
            for x in n.iter_mut() { *x = u64_at(&mut pos) as usize; }
            nodes.push(n);
        }
    }
    Some(Dump { sw, null, cb, pages, roots, nodes })
}

impl Dump {
    /// The word at `a` if it is in a page.
    fn word(&self, a: usize) -> Option<usize> {
        for p in &self.pages {
            if a >= p.start && a < p.start + p.bytes {
                return Some(p.words[(a - p.start) / W]);
            }
        }
        None
    }
    fn in_pages(&self, w: usize) -> bool {
        w % 2 == 1 && self.word(w - 1).is_some()
    }
}

/// The C++ `HeapObject::size` and the reference slots, of the object at
/// `a` (untagged) read through `word`: (size, lo, hi).
fn layout(word: &dyn Fn(usize) -> usize, cb: &[u16], sw: usize, a: usize) -> (usize, usize, usize) {
    let hd = word(a);
    assert_eq!(hd % 2, 0, "header expected at {:#x}", a);
    let v = hd >> 1;
    let (tag, cid) = (v & 15, v >> 5);
    let s = |n: usize| (n, n, n);
    match tag {
        0 => { let n = 2 + word(a + W); (n, 2, n) }
        1 => {
            let l = (word(a + W) >> SHIFT) & MASK;
            s(if l == 0xffff { 4 } else { (CONTENT + l + 1 + W - 1) / W })
        }
        2 | 8 => { let n = ((cb[cid] >> 5) & 0x7ff) as usize; (n, 1, n) }
        3 => s(((cb[cid] >> 5) & 0x7ff) as usize),
        4 | 6 => s(1 + VALUE_WORDS),
        5 => {
            let r = word(a + W) as isize;
            s(if r >= 0 { (CONTENT + r as usize + W - 1) / W } else { 4 })
        }
        7 => { let len = word(a + 2 * W); let top = word(a + 3 * W); (sw + len, sw + top, sw + len) }
        _ => panic!("tag {} at {:#x}", tag, a),
    }
}

struct Arena {
    words: Vec<usize>,
    pw: usize,
    free: Vec<usize>,
}

impl Arena {
    fn base(&mut self) -> *mut usize { self.words.as_mut_ptr() }
    fn addr(&self, page: usize) -> usize { self.words.as_ptr() as usize + page * self.pw * W }
    fn read(&self, a: usize) -> usize { self.words[(a - self.words.as_ptr() as usize) / W] }
    fn write(&mut self, a: usize, v: usize) {
        let i = (a - self.words.as_ptr() as usize) / W;
        self.words[i] = v;
    }
}

struct Source<'a> {
    arena: &'a mut Arena,
    reserved: usize,
    taken: Vec<usize>,
    asked: usize,
}

impl<'a> PageSource for Source<'a> {
    fn reserve(&mut self, n: usize) -> bool {
        self.asked = n;
        if self.arena.free.len() < n { return false; }
        self.reserved = n;
        true
    }
    fn take(&mut self, _key: Ghost<int>) -> (usize, Tracked<Map<(int, int), vstd::raw_ptr::PointsTo<usize>>>) {
        assert!(self.reserved > 0);
        self.reserved -= 1;
        let p = self.arena.free.pop().unwrap();
        let a = self.arena.addr(p);
        self.taken.push(a);
        (a, Tracked::assume_new())
    }
    fn release(&mut self) { self.reserved = 0; }
}

#[derive(Default, Debug)]
struct Stats {
    pairs: usize,
    objects: usize,
    words: usize,
    zapped: usize,
    shrunk: usize,
    // The reservation question: from-space pages, to-space pages taken,
    // and the page counts of candidate bounds.
    from_pages: usize,
    to_pages: usize,
    max_to_minus_from: isize,
    max_to_over_from_permille: usize,
    over_tail_bound: usize,
    max_object_words: usize,
    reserved_2nf: usize,
    reserved_tail: usize,
    // The proved tail bound (tail::reserve_pages): dumps it applied to, and
    // the pages it reserved.
    tail_dumps: usize,
    tail_skipped: usize,
    reserved_proved: usize,
    max_proved_minus_nf: isize,
    max_largest_permille: usize,
    // The finalizer nodes: compared, by the proved collector's verdict
    // (KEEP, QUEUE, DELETE, FREE), live weak maps the C++ prototype zapped
    // and queued, verdicts that differ only through a weak map's fields.
    nodes: usize,
    verdicts: [usize; 5],
    weak_zap_queued: usize,
    weak_divergent: usize,
}

/// Runs the proved collector on `before` and compares with `after`.
fn diff(before: &Dump, after: &Dump, stats: &mut Stats) -> Result<(), String> {
    let nf = before.pages.len();
    let bytes = before.pages[0].bytes;
    if before.pages.iter().any(|p| p.bytes != bytes) { return Err("pages of different sizes".into()); }
    let pw = bytes / W;
    let mut arena = Arena { words: vec![0x5a5a_5a5b; (3 * nf + 2) * pw], pw, free: vec![] };
    // From-space: the pages in address order at arena pages 0..nf.
    let mut order: Vec<usize> = (0..nf).collect();
    order.sort_by_key(|&i| before.pages[i].start);
    let pord = order.clone();
    let mut ftab = vec![];
    let mut reloc: Vec<(usize, usize)> = vec![]; // (old start, new start)
    for (k, &i) in order.iter().enumerate() {
        let a = arena.addr(k);
        for (j, w) in before.pages[i].words.iter().enumerate() { arena.write(a + j * W, *w); }
        ftab.push(a);
        reloc.push((before.pages[i].start, a));
    }
    arena.free = (nf..3 * nf + 2).rev().collect();
    let new_addr = |w: usize| -> usize {
        for (o, n) in &reloc {
            if w > *o && w < *o + bytes { return n + (w - o); }
        }
        w
    };
    // Relocate the references of the objects the roots reach.
    let bword = |a: usize| before.word(a).unwrap();
    let mut seen = std::collections::HashSet::new();
    let mut work: Vec<usize> = before.roots.iter().filter(|r| before.in_pages(**r)).cloned().collect();
    for n in &before.nodes {
        for v in [n[3], n[4]] { if before.in_pages(v) { work.push(v); } }
    }
    while let Some(r) = work.pop() {
        if !seen.insert(r) { continue; }
        let a = r - 1;
        let (_, lo, hi) = layout(&bword, &before.cb, before.sw, a);
        for k in lo..hi {
            let v = bword(a + k * W);
            if before.in_pages(v) {
                work.push(v);
                arena.write(new_addr(r) - 1 + k * W, new_addr(v));
            }
        }
    }
    let mut roots: Vec<usize> = before.roots.iter().map(|r| if before.in_pages(*r) { new_addr(*r) } else { *r }).collect();
    let mut cb = before.cb.clone();
    let tcap = 2 * nf + 1;
    let mut ttab = vec![0usize; tcap];
    let mut tused = vec![0usize; tcap];
    // The nodes for the proved collector: the registered callback
    // finalizers (kinds 0, 1), the queue (kinds 2, 3), the VM finalizers.
    let rel = |v: usize| if before.in_pages(v) { new_addr(v) } else { v };
    let mut order: Vec<usize> = (0..before.nodes.len()).collect();
    order.sort_by_key(|&i| before.nodes[i][0]);
    // The used words of each from-space page for the tail bound: the
    // objects from offset 0 up to the dump's used bytes or the sentinel (a
    // zero header word). Used only if every reachable object starts at
    // one of these offsets (else the dump is not parsed that way).
    let mut fusedw = vec![0usize; nf.max(1)];
    let mut starts = std::collections::HashSet::new();
    for (k, &i) in pord.iter().enumerate() {
        let pg = &before.pages[i];
        let lim = (pg.used / W).min(pw - 1);
        let mut off = 0;
        while off < lim && pg.words[off] == usize::MAX - 107 { off += 1; }  // One-word fillers.
        while off < lim && pg.words[off] != 0 && pg.words[off] % 2 == 0 && (pg.words[off] >> 1) & 15 <= 8 {
            starts.insert(pg.start + off * W + 1);
            let (sz, _, _) = layout(&bword, &before.cb, before.sw, pg.start + off * W);
            if sz == 0 || off + sz > lim { break; }
            off += sz;
            while off < lim && pg.words[off] == usize::MAX - 107 { off += 1; }
        }
        fusedw[k] = off;
    }
    let tail = seen.iter().all(|r| starts.contains(r));
    if !tail && std::env::var("TAILDBG").is_ok() {
        let r = seen.iter().find(|r| !starts.contains(r)).unwrap();
        for (k, &i) in pord.iter().enumerate() {
            let pg = &before.pages[i];
            if *r > pg.start && *r < pg.start + pg.bytes {
                let stop = fusedw[k];
                eprintln!("TAILDBG obj off {} page used {} stop {} word {:#x} next {:#x} {:#x}", (r - 1 - pg.start) / W, pg.used / W, stop, pg.words[stop], pg.words[stop + 1], pg.words[stop + 2]);
            }
        }
    }
    if tail { stats.tail_dumps += 1; } else { stats.tail_skipped += 1; }
    let mut nodew = vec![];
    for &i in &order {
        let n = before.nodes[i];
        let kind = if n[0] == 1 { n[1] + 2 } else { n[1] };
        nodew.extend([kind, rel(n[3]), if n[0] == 2 { 0 } else { rel(n[4]) }, 99]);
    }
    nodew.push(0);
    let ncb = order.iter().filter(|&&i| before.nodes[i][0] != 2).count();
    let nn = order.len();
    let c = Ctx { base: arena.base(), ftab: ftab.as_mut_ptr(), nf, pw, ctab: cb.as_mut_ptr(), ncls: cb.len(), sw: before.sw,
                  null: before.null, nullid: Ghost::assume_new(), fused: fusedw.as_mut_ptr(), tail, fss: Ghost::assume_new(), cbs: Ghost::assume_new() };
    let mut src = Source { arena: &mut arena, reserved: 0, taken: vec![], asked: 0 };
    let r = collect(&c, &mut src, roots.as_mut_ptr(), roots.len(), ttab.as_mut_ptr(), tused.as_mut_ptr(), tcap,
                    nodew.as_mut_ptr(), ncb, nn,
                    Ghost::assume_new(), Ghost::assume_new(), Ghost::assume_new(), Tracked::assume_new(), Tracked::assume_new(),
                    Tracked::assume_new());
    let taken = src.taken.clone();
    stats.reserved_proved += src.asked;
    stats.max_proved_minus_nf = stats.max_proved_minus_nf.max(src.asked as isize - nf as isize);
    if tail { stats.max_largest_permille = stats.max_largest_permille.max(largest(&before, &pord, pw, &bword) * 1000 / pw); }
    let w = r.map_err(|_| "the collection did not start".to_string())?;
    if w.pages > tcap { return Err("too many pages".into()); }
    let in_rust = |v: usize| v % 2 == 1 && taken.iter().any(|p| v > *p && v < *p + bytes);
    // Walk both results from the roots.
    if roots.len() != after.roots.len() { return Err(format!("{} roots, C++ {}", roots.len(), after.roots.len())); }
    let aword = |a: usize| after.word(a).unwrap();
    let rword = |a: usize| arena.read(a);
    let mut r2c: HashMap<usize, usize> = HashMap::new();
    let mut c2r: HashMap<usize, usize> = HashMap::new();
    let mut work: Vec<(usize, usize)> = vec![];
    let mut pair = |rv: usize, cv: usize, work: &mut Vec<(usize, usize)>, stats: &mut Stats| -> Result<(), String> {
        if in_rust(rv) {
            if cv == after.null && !after.in_pages(cv) {
                stats.zapped += 1;
                return Ok(());
            }
            if !after.in_pages(cv) { return Err(format!("{:#x} copied, C++ {:#x}", rv, cv)); }
            match (r2c.get(&rv), c2r.get(&cv)) {
                (None, None) => { r2c.insert(rv, cv); c2r.insert(cv, rv); work.push((rv, cv)); }
                (Some(c), Some(r)) if *c == cv && *r == rv => {}
                _ => return Err(format!("not a renumbering at {:#x} / {:#x}", rv, cv)),
            }
            Ok(())
        } else if rv == cv {
            Ok(())
        } else {
            Err(format!("word {:#x}, C++ {:#x}", rv, cv))
        }
    };
    for (i, (rv, cv)) in roots.iter().zip(after.roots.iter()).enumerate() {
        pair(*rv, *cv, &mut work, stats).map_err(|e| format!("root {}: {}", i, e))?;
    }
    // The finalizer nodes: the C++ verdict from where the node is after the
    // collection (by its address), the proved collector's from its verdict
    // word; the slots of kept and queued nodes are walked like roots.
    let after_nodes: HashMap<usize, [usize; 5]> = after.nodes.iter().map(|n| (n[2], *n)).collect();
    let has_weak = before.nodes.iter().any(|n| n[1] == 1);
    for (m, &i) in order.iter().enumerate() {
        let n = before.nodes[i];
        let d = nodew[4 * m + 3];
        let a = after_nodes.get(&n[2]);
        let fbit = before.word(n[3] - 1).map_or(false, |h| h & 32 != 0);
        // 0 KEEP, 1 QUEUE, 2 DELETE, 3 FREE; 5: a live weak map the C++
        // prototype zapped and queued (kept by the proved collector, which
        // traces weak maps strongly).
        let cpp = match (n[0], a) {
            (0, Some(x)) if x[0] == 0 => 0,
            (0, Some(_)) => if n[1] == 0 { 1 } else { 5 },
            (_, Some(_)) => 0,
            (2, None) => if fbit { 3 } else { 2 },
            (_, None) => 2,
        };
        stats.nodes += 1;
        stats.verdicts[d.min(4)] += 1;
        if cpp == 5 { stats.weak_zap_queued += 1; }
        let expect = if cpp == 5 { 0 } else { cpp };
        if d != expect {
            // A key the C++ prototype found dead that is reachable through a
            // weak map's fields (traced strongly here) is the one expected
            // difference.
            if d == 0 && has_weak && (cpp == 1 || cpp == 3 || (cpp == 2 && fbit)) {
                stats.weak_divergent += 1;
                continue;
            }
            return Err(format!("node {} (list {} kind {}): verdict {}, C++ {}", m, n[0], n[1], d, cpp));
        }
        let what = |s: &str, e: String| format!("{} of node {}: {}", s, m, e);
        match d {
            0 => {
                let x = a.unwrap();
                pair(nodew[4 * m + 1], x[3], &mut work, stats).map_err(|e| what("key", e))?;
                if n[0] != 2 { pair(nodew[4 * m + 2], x[4], &mut work, stats).map_err(|e| what("lambda", e))?; }
            }
            1 => {
                let x = a.unwrap();
                if nodew[4 * m + 1] != x[3] { return Err(what("key", format!("{:#x}, C++ {:#x}", nodew[4 * m + 1], x[3]))); }
                pair(nodew[4 * m + 2], x[4], &mut work, stats).map_err(|e| what("lambda", e))?;
            }
            _ => {}
        }
    }
    while let Some((rv, cv)) = work.pop() {
        let (ra, ca) = (rv - 1, cv - 1);
        stats.objects += 1;
        let hd = rword(ra);
        if hd != aword(ca) { return Err(format!("header {:#x}, C++ {:#x}", hd, aword(ca))); }
        let rtag = (hd >> 1) & 15;
        if rtag == 0 || rtag == 7 { let l = rword(ra + (if rtag == 0 { 1 } else { 2 }) * W); if l > pw { return Err(format!("tag {} length {:#x} at {:#x} (C++ {:#x})", rtag, l, rv, cv)); } }
        let (size, lo, hi) = layout(&rword, &cb, before.sw, ra);
        if size > pw { return Err(format!("size {} of {:#x}", size, rv)); }
        let (csize, clo, chi) = layout(&aword, &cb, before.sw, ca);
        stats.words += size;
        if (hd >> 1) & 15 == 7 {
            // A stack: the C++ prototype may have moved the object stack down.
            let d = size - csize;
            if lo - clo != d || hi - chi != d { return Err("stack shrunk unevenly".into()); }
            if d > 0 { stats.shrunk += 1; }
            for k in 0..clo {
                if k == 2 || k == 3 { continue; } // Length and top.
                if rword(ra + k * W) != aword(ca + k * W) { return Err(format!("stack word {}", k)); }
            }
            for k in 0..(hi - lo) {
                pair(rword(ra + (lo + k) * W), aword(ca + (clo + k) * W), &mut work, stats)
                    .map_err(|e| format!("stack slot {}: {}", k, e))?;
            }
            continue;
        }
        if (size, lo, hi) != (csize, clo, chi) { return Err(format!("layout {:?}, C++ {:?}", (size, lo, hi), (csize, clo, chi))); }
        for k in 1..size {
            let (x, y) = (rword(ra + k * W), aword(ca + k * W));
            if k >= lo && k < hi {
                pair(x, y, &mut work, stats).map_err(|e| format!("slot {} of {:#x}: {}", k, cv, e))?;
            } else if x != y {
                return Err(format!("raw word {} of {:#x}: {:#x}, C++ {:#x}", k, cv, x, y));
            }
        }
    }
    // The page counts: what was taken against the from-space pages and
    // against the bound from the largest live object (a page closes only
    // when the next object does not fit: every closed page holds more than
    // `pw - 1 - maxw` words).
    let mut live_words = 0usize;
    let mut maxw = 0usize;
    for (rv, _) in &r2c { let (sz, _, _) = layout(&rword, &cb, before.sw, rv - 1); live_words += sz; if sz > maxw { maxw = sz; } }
    let tail_bound = if live_words == 0 { 1 } else { live_words / (pw - maxw) + 1 };
    if w.pages > tail_bound { stats.over_tail_bound += 1; }
    stats.reserved_2nf += 2 * nf + 1;
    stats.reserved_tail += (tail_bound + 1).min(2 * nf + 1);
    stats.from_pages += nf;
    stats.to_pages += w.pages;
    stats.max_to_minus_from = stats.max_to_minus_from.max(w.pages as isize - nf as isize);
    stats.max_to_over_from_permille = stats.max_to_over_from_permille.max(w.pages * 1000 / nf);
    stats.max_object_words = stats.max_object_words.max(maxw);
    stats.pairs += 1;
    Ok(())
}

fn dumps(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() { dumps(&p, out); }
        else if p.to_string_lossy().ends_with("-before.bin") { out.push(p); }
    }
}

#[test]
fn differential() {
    let Ok(dir) = std::env::var("TOIT_GC_DIFF") else {
        eprintln!("TOIT_GC_DIFF not set: no differential test");
        return;
    };
    let mut files = vec![];
    dumps(Path::new(&dir), &mut files);
    files.sort();
    let mut stats = Stats::default();
    let mut failures = vec![];
    let mut other_width = 0;
    for f in &files {
        let a = PathBuf::from(f.to_string_lossy().replace("-before.bin", "-after.bin"));
        let Some(before) = read_dump(f) else { other_width += 1; continue };
        let Some(after) = read_dump(&a) else { continue };
        if before.pages.is_empty() { continue; }
        if let Err(e) = diff(&before, &after, &mut stats) {
            failures.push(format!("{}: {}", f.display(), e));
        }
    }
    eprintln!("differential: {} collections compared ({} of another word size skipped), {:?}", stats.pairs, other_width, stats);
    for f in &failures { eprintln!("MISMATCH {}", f); }
    assert!(failures.is_empty(), "{} mismatches", failures.len());
    assert!(stats.pairs > 0, "no dumps of this word size under {}", dir);
}

/// The largest object of the dump's from-space pages (the tail bound's
/// `mx`, as the oracle sees it).
fn largest(before: &Dump, pord: &[usize], pw: usize, bword: &dyn Fn(usize) -> usize) -> usize {
    let mut m = 1;
    for &i in pord {
        let pg = &before.pages[i];
        let lim = (pg.used / W).min(pw - 1);
        let mut off = 0;
        while off < lim {
            let w = pg.words[off];
            if w == usize::MAX - 107 { off += 1; continue; }
            if w == 0 || w % 2 != 0 || (w >> 1) & 15 > 8 { break; }
            let (sz, _, _) = layout(bword, &before.cb, before.sw, pg.start + off * W);
            if sz == 0 || off + sz > lim { break; }
            m = m.max(sz);
            off += sz;
        }
    }
    m
}
