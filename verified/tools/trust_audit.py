#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

"""Audit of the Verus escape hatches in verified/core and verified/spec.

Scans every Rust source of both crates for the ways Verus lets code be
trusted instead of proven, and compares the result with the allowlist
verified/TRUSTED.toml. Unlisted occurrences, count changes, entries without
a justification and stale entries are failures. Also reports (without
failing) closed/opaque spec fns, empty-bodied proof fns with an `ensures`,
`rlimit` overrides, and writes the list of top-level theorems to
verified/THEOREMS.txt.

The scanner tokenizes Rust (comments, strings and char literals never
count), tracks `verus!` regions and attaches attributes to the item they
precede. As an independent check, the locations Verus itself rejects with
`--no-cheating` (passed with --no-cheating-log) must all lie in items the
scanner flagged.

Usage:
  trust_audit.py [--update-allowlist] [--no-cheating-log CRATE=FILE]...
"""

import argparse
import os
import re
import sys
import tomllib
from dataclasses import dataclass, field

# Crates: name -> (directory relative to verified/, cfgs passed to Verus).
CRATES = {
    "core": ("core", ["toit_vcore_hosted"]),
    "spec": ("spec", []),
}

# Markdown files that document the trusted base of each crate. Every
# allowlisted item should be mentioned there; misses are reported.
TRUST_DOCS = {
    "core": "core/TRUSTED.md",
    "spec": "spec/DESIGN.md",
}

# `#[verifier::X]` attributes, checked against Verus 0.2026.11.02 (by
# probing which names the installed `verus` accepts, and by reading vstd
# and verus_builtin_macros). Anything not listed as benign or report-only
# is treated as an escape hatch, so unknown or new attributes fail closed.
TRUSTED_ATTRS = {
    "external_body",                  # Body not verified; contract assumed.
    "external",                       # Item ignored by Verus entirely.
    "external_fn_specification",      # Old form of assume_specification.
    "external_type_specification",    # Assumed spec of a foreign type.
    "external_trait_specification",   # Assumed spec of a foreign trait.
    "external_trait_extension",       # Assumed spec extension of a trait.
    "external_derive",                # Derived impls not verified.
    "assume_termination",             # Termination assumed, not proven.
    "exec_allows_no_decreases_clause",  # Exec termination not proven.
    "truncate",                       # Cast wraps silently (semantic change).
    "when_used_as_spec",              # Exec fn replaced by a spec fn in specs.
    "ghost_wrapper",                  # Internal.
    "tracked_swap_primitive",         # Internal trusted vstd primitive.
    "tracked_take_option_primitive",  # Internal trusted vstd primitive.
}
REPORT_ATTRS = {"rlimit", "opaque", "opaque_outside_module"}
BENIGN_ATTRS = {
    "trigger", "spinoff_prover", "inline", "verify", "accept_recursive_types",
    "reject_recursive_types", "reject_recursive_types_in_ground_variants",
    "ext_equal", "nonlinear", "integer_ring", "bit_vector", "memoize",
    "type_invariant", "custom_err", "prophetic", "allow_in_spec", "atomic",
    "loop_isolation", "spec", "proof", "exec", "no_auto_trigger",
    "auto_trigger", "all_triggers", "broadcast_forall",
    "allow_complex_invariants", "no_auto_loop_invariant", "auto_ext_equal",
}

# Identifiers that are escape hatches wherever they appear in code.
ESCAPE_CALLS = {
    "assume": "assume",          # assume(e) (only when followed by `(`).
    "admit": "admit",            # admit() (only when followed by `(`).
}
ESCAPE_IDENTS = {
    "assume_": "assume",                     # verus_builtin::assume_.
    "assume_new": "assume_new",              # Ghost/Tracked::assume_new.
    "assume_new_fallback": "assume_new",
    "inline_air_stmt": "inline_air",         # Needs -V allow-inline-air.
    "unsafe": "unsafe",
}

# cfg names that make the code Verus sees differ from the code rustc builds.
VERUS_CFG_RE = re.compile(r"\bverus\w*\b")

ITEM_KEYWORDS = {
    "fn", "struct", "enum", "union", "trait", "impl", "mod", "const",
    "static", "type", "use", "extern", "assume_specification", "global",
    "group",
}
MODIFIERS = {
    "pub", "open", "closed", "uninterp", "spec", "proof", "exec", "axiom",
    "broadcast", "tracked", "ghost", "default", "async", "unsafe", "safe",
    "const", "extern",
}
# Tokens that can start an item (used to find where a fn body ends: a brace
# group followed by one of these, or by the end of the enclosing block).
ITEM_START = ITEM_KEYWORDS | MODIFIERS | {"#", "verus", "layout"}

KIND_HELP = {
    "external_body": "#[verifier::external_body]",
    "assume": "assume(...)",
    "admit": "admit()",
    "assume_new": "Ghost/Tracked::assume_new",
    "assume_specification": "assume_specification[...]",
    "axiom": "axiom fn (bodiless proof, implicitly external_body)",
    "uninterp": "uninterp spec fn",
    "bodiless_spec": "spec fn without body and without `uninterp`",
    "unsafe": "unsafe",
    "cfg": "cfg on verus*/crate cfgs (Verus sees different code than rustc)",
    "inner_attr": "module/crate-level #![verifier::...] or #![verus...]",
    "verus_internal": "#[verus::internal(...)]",
    "plain_rust_file": "file with no verus! block (not verified)",
    "plain_rust_item": "item outside verus! (not verified)",
    "cargo_metadata": "[package.metadata.verus] option other than verify = true",
    "global_layout": "global size_of/layout directive (Verus assumes it; rustc checks it at compile time)",
}


# ----------------------------------------------------------------------------
# Tokenizer.

@dataclass
class Tok:
    kind: str     # ident, punct, lit, lifetime
    text: str
    start: int
    end: int
    line: int


class LexError(Exception):
    pass


def tokenize(src):
    toks = []
    i = 0
    n = len(src)
    line = 1
    ident_re = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
    num_re = re.compile(
        r"0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*"
        r"(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9_]+)?")

    def add(kind, j):
        nonlocal i, line
        toks.append(Tok(kind, src[i:j], i, j, line))
        line += src.count("\n", i, j)
        i = j

    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c.isspace():
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            depth = 0
            j = i
            while j < n:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            if depth != 0:
                raise LexError(f"line {line}: unterminated block comment")
            line += src.count("\n", i, j)
            i = j
            continue
        # Raw strings: r"..", r#".."#, br"..", cr"..".
        m = re.match(r'(?:b|c)?r(#*)"', src[i:i + 300])
        if m:
            hashes = m.group(1)
            close = '"' + hashes
            j = src.find(close, i + len(m.group(0)))
            if j < 0:
                raise LexError(f"line {line}: unterminated raw string")
            add("lit", j + len(close))
            continue
        # Normal and byte/C strings.
        if c == '"' or (c in "bc" and i + 1 < n and src[i + 1] == '"'):
            j = i + (1 if c == '"' else 2)
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            if j >= n:
                raise LexError(f"line {line}: unterminated string")
            add("lit", j + 1)
            continue
        # Byte char b'x'.
        if c == "b" and i + 1 < n and src[i + 1] == "'":
            j = i + 2
            while j < n and src[j] != "'":
                j += 2 if src[j] == "\\" else 1
            add("lit", j + 1)
            continue
        # Raw identifier r#name.
        if c == "r" and src.startswith("r#", i) and i + 2 < n and (src[i + 2].isalpha() or src[i + 2] == "_"):
            m = ident_re.match(src, i + 2)
            toks.append(Tok("ident", m.group(0), i, m.end(), line))
            i = m.end()
            continue
        if c.isalpha() or c == "_":
            m = ident_re.match(src, i)
            add("ident", m.end())
            continue
        if c.isdigit():
            m = num_re.match(src, i)
            j = m.end()
            # Literal suffix (u8, f64, usize, ...).
            m2 = ident_re.match(src, j)
            if m2:
                j = m2.end()
            add("lit", j)
            continue
        if c == "'":
            # Char literal or lifetime.
            if i + 1 < n and src[i + 1] == "\\":
                j = i + 2
                while j < n and src[j] != "'":
                    j += 2 if src[j] == "\\" else 1
                add("lit", j + 1)
                continue
            if i + 2 < n and src[i + 2] == "'":
                add("lit", i + 3)
                continue
            m = ident_re.match(src, i + 1)
            if m:
                add("lifetime", m.end())
                continue
            add("punct", i + 1)
            continue
        if src.startswith("::", i):
            add("punct", i + 2)
            continue
        add("punct", i + 1)
    return toks


# ----------------------------------------------------------------------------
# Parser: items, attributes, verus! regions.

@dataclass
class Attr:
    inner: bool
    toks: list           # tokens between the brackets
    line: int


@dataclass
class Item:
    kind: str            # fn, struct, impl, ...
    name: str            # qualified name (Type::method)
    simple: str          # last name segment
    mods: set
    attrs: list
    start: int           # token index of first token after the attributes
    end: int             # token index after the item
    body: tuple          # (open, close) token indices of the fn body, or None
    in_verus: bool
    in_trait: bool
    line: int
    end_line: int
    container: bool = False


@dataclass
class Occurrence:
    crate: str
    file: str
    item: str
    kind: str
    line: int
    detail: str = ""


class Parser:
    def __init__(self, path, src):
        self.path = path
        self.src = src
        self.toks = tokenize(src)
        self.match = self._match_brackets()
        self.items = []
        self.warnings = []
        self.verus_regions = []   # (start, end) token index ranges
        self.item_attrs_inner = []  # (Attr, prefix, in_verus) at item level

    def _match_brackets(self):
        pairs = {")": "(", "]": "[", "}": "{"}
        stack = []
        match = {}
        for k, t in enumerate(self.toks):
            if t.kind != "punct":
                continue
            if t.text in "([{":
                stack.append(k)
            elif t.text in ")]}":
                if not stack or self.toks[stack[-1]].text != pairs[t.text]:
                    raise LexError(f"{self.path}:{t.line}: unbalanced '{t.text}'")
                o = stack.pop()
                match[o] = k
                match[k] = o
        if stack:
            raise LexError(f"{self.path}:{self.toks[stack[-1]].line}: unclosed bracket")
        return match

    def t(self, k):
        return self.toks[k].text if 0 <= k < len(self.toks) else ""

    def is_p(self, k, s):
        return 0 <= k < len(self.toks) and self.toks[k].kind == "punct" and self.toks[k].text == s

    def skip_group(self, k):
        """If k opens a group, return the index after it; else k + 1."""
        if self.t(k) in ("(", "[", "{") and self.toks[k].kind == "punct":
            return self.match[k] + 1
        return k + 1

    def scan_to_semi(self, k, end):
        while k < end and not self.is_p(k, ";"):
            k = self.skip_group(k)
        return min(k + 1, end)

    def parse(self):
        self.parse_items(0, len(self.toks), "", False, False)

    def parse_items(self, k, end, prefix, in_verus, in_trait):
        while k < end:
            attrs = []
            while k < end and self.is_p(k, "#"):
                inner = self.is_p(k + 1, "!")
                b = k + 2 if inner else k + 1
                if not self.is_p(b, "["):
                    break
                close = self.match[b]
                a = Attr(inner, self.toks[b + 1:close], self.toks[k].line)
                if inner:
                    self.item_attrs_inner.append((a, prefix, in_verus))
                else:
                    attrs.append(a)
                k = close + 1
            if k >= end:
                break
            if self.is_p(k, ";"):
                k += 1
                continue
            tok = self.toks[k]
            # Macro invocation: verus! { ... } or other!{...}.
            if tok.kind == "ident" and self.is_p(k + 1, "!") and tok.text not in ITEM_KEYWORDS:
                g = k + 2
                if tok.text == "macro_rules":
                    g = k + 3
                if self.t(g) in ("{", "(", "["):
                    close = self.match[g]
                    if tok.text == "verus":
                        self.verus_regions.append((g, close))
                        self.add_item("verus_block", prefix, "verus!", set(), attrs, k, close + 1,
                                      (g, close), in_verus, in_trait, container=True)
                        self.parse_items(g + 1, close, prefix, True, False)
                    else:
                        name = f"{tok.text}!"
                        self.add_item("macro", prefix, name, set(), attrs, k, close + 1,
                                      None, in_verus, in_trait)
                    k = close + 1
                    if self.is_p(k, ";"):
                        k += 1
                    continue
            k = self.parse_item(k, end, attrs, prefix, in_verus, in_trait)

    def add_item(self, kind, prefix, name, mods, attrs, start, end, body, in_verus, in_trait,
                 container=False):
        qual = f"{prefix}::{name}" if prefix else name
        it = Item(kind, qual, name, mods, attrs, start, end, body, in_verus, in_trait,
                  self.toks[start].line, self.toks[end - 1].line, container)
        self.items.append(it)
        return it

    def parse_item(self, k, end, attrs, prefix, in_verus, in_trait):
        start = k
        mods = set()
        while k < end:
            w = self.t(k)
            if self.toks[k].kind != "ident":
                break
            if w == "pub":
                mods.add("pub")
                k += 1
                if self.is_p(k, "("):
                    k = self.match[k] + 1
                continue
            if w == "spec":
                mods.add("spec")
                k += 1
                if self.is_p(k, "("):
                    k = self.match[k] + 1
                continue
            if w == "extern":
                # extern crate / extern "C" fn / extern "C" { ... }
                if self.t(k + 1) == "crate":
                    break
                k += 1
                if self.toks[k].kind == "lit":
                    k += 1
                if self.is_p(k, "{"):
                    close = self.match[k]
                    self.add_item("extern", prefix, "extern", mods | {"extern"}, attrs, start,
                                  close + 1, None, in_verus, in_trait, container=True)
                    self.parse_items(k + 1, close, prefix, in_verus, False)
                    return close + 1
                mods.add("extern")
                continue
            if w == "const" and self.t(k + 1) in ("fn", "unsafe", "async", "extern"):
                mods.add("const")
                k += 1
                continue
            if w == "default" and self.t(k + 1) in ("fn", "unsafe", "const", "type", "impl"):
                mods.add("default")
                k += 1
                continue
            if w == "unsafe" and self.t(k + 1) in ("fn", "impl", "trait", "extern"):
                mods.add("unsafe")
                k += 1
                continue
            if w == "safe" and self.t(k + 1) in ("fn", "static"):
                mods.add("safe")
                k += 1
                continue
            if w in MODIFIERS - {"const", "default", "unsafe", "safe", "extern", "pub", "spec"}:
                if w == "broadcast" and self.t(k + 1) in ("use", "group"):
                    mods.add("broadcast")
                    k += 1
                    continue
                if w in ("tracked", "ghost") and self.t(k + 1) not in ITEM_KEYWORDS | MODIFIERS:
                    break
                mods.add(w)
                k += 1
                if w in ("open", "closed") and self.is_p(k, "("):
                    k = self.match[k] + 1
                continue
            break
        w = self.t(k)
        if w == "fn":
            name = self.t(k + 1)
            j = k + 2
            body = None
            while j < end:
                if self.is_p(j, ";"):
                    j += 1
                    break
                if self.is_p(j, "{"):
                    close = self.match[j]
                    nxt = close + 1
                    if (nxt >= end or self.t(nxt) in ITEM_START or self.is_p(nxt, ";")
                            or (self.toks[nxt].kind == "ident" and self.is_p(nxt + 1, "!"))):
                        body = (j, close)
                        j = close + 1
                        break
                    j = close + 1
                    continue
                j = self.skip_group(j)
            self.add_item("fn", prefix, name, mods, attrs, start, j, body, in_verus, in_trait)
            return j
        if w in ("struct", "enum", "union"):
            name = self.t(k + 1)
            j = k + 2
            while j < end:
                if self.is_p(j, ";"):
                    j += 1
                    break
                if self.is_p(j, "{"):
                    j = self.match[j] + 1
                    break
                j = self.skip_group(j)
            self.add_item(w, prefix, name, mods, attrs, start, j, None, in_verus, in_trait)
            return j
        if w in ("trait", "impl", "mod"):
            j = k + 1
            header = []
            while j < end and not self.is_p(j, "{") and not self.is_p(j, ";"):
                header.append(j)
                j = self.skip_group(j) if self.t(j) in ("(", "[") else j + 1
            if self.is_p(j, ";"):     # mod foo;
                it = self.add_item(w, prefix, self.t(k + 1), mods, attrs, start, j + 1, None,
                                   in_verus, in_trait)
                it.kind = "mod_decl"
                return j + 1
            name = self.t(k + 1) if w != "impl" else self.impl_name(header)
            close = self.match[j]
            self.add_item(w, prefix, name, mods, attrs, start, close + 1, (j, close), in_verus,
                          in_trait, container=True)
            sub = f"{prefix}::{name}" if (prefix and w == "mod") else name
            self.parse_items(j + 1, close, sub, in_verus, w == "trait")
            return close + 1
        if w in ("const", "static", "type", "use", "global") or (w == "extern" and self.t(k + 1) == "crate"):
            name = self.t(k + 1)
            if w == "use":
                name = "use"
            if name == "mut":
                name = self.t(k + 2)
            j = self.scan_to_semi(k + 1, end)
            self.add_item(w, prefix, name, mods, attrs, start, j, None, in_verus, in_trait)
            return j
        if w == "group":           # broadcast group name { ... }
            name = self.t(k + 1)
            j = k + 2
            if self.is_p(j, "{"):
                j = self.match[j] + 1
            self.add_item("broadcast_group", prefix, name, mods, attrs, start, j, None, in_verus,
                          in_trait)
            return j
        if w == "assume_specification":
            j = k + 1
            name = "?"
            while j < end and not self.is_p(j, "["):
                j += 1
            if j < end:
                close = self.match[j]
                name = "".join(t.text for t in self.toks[j + 1:close])
            j = self.scan_to_semi(j, end)
            self.add_item("assume_specification", prefix, name, mods, attrs, start, j, None,
                          in_verus, in_trait)
            return j
        # Unknown: record a warning and skip to the next `;` or group.
        t = self.toks[k] if k < len(self.toks) else self.toks[-1]
        self.warnings.append(f"{self.path}:{t.line}: unrecognized item at `{t.text}`"
                             f"{' (inside verus!)' if in_verus else ''}")
        j = k
        while j < end and not self.is_p(j, ";") and not self.is_p(j, "{"):
            j = self.skip_group(j)
        if j < end and self.is_p(j, "{"):
            j = self.match[j]
        j = min(j + 1, end)
        self.add_item("unknown", prefix, f"?{t.line}", mods, attrs, start, j, None, in_verus,
                      in_trait)
        return j

    def impl_name(self, header):
        toks = [self.toks[h] for h in header]
        # Drop leading generics: impl<...>.
        texts = [t.text for t in toks]
        k = 0
        if k < len(texts) and texts[k] == "<":
            depth = 0
            while k < len(texts):
                if texts[k] == "<":
                    depth += 1
                elif texts[k] == ">":
                    depth -= 1
                    if depth == 0:
                        k += 1
                        break
                k += 1
        texts = texts[k:]
        if "for" in texts:
            texts = texts[texts.index("for") + 1:]
        if "where" in texts:
            texts = texts[:texts.index("where")]
        # Type name: last path segment before generics.
        name = []
        depth = 0
        for x in texts:
            if x == "<":
                depth += 1
            elif x == ">":
                depth -= 1
            elif depth == 0 and (x.isidentifier()):
                name.append(x)
        return name[-1] if name else "impl"

    def text(self, a, b):
        """Source text from token a to the token before b."""
        return self.src[self.toks[a].start:self.toks[b - 1].end]


# ----------------------------------------------------------------------------
# Attribute normalization.

def split_commas(toks):
    parts, cur, depth = [], [], 0
    for t in toks:
        if t.kind == "punct" and t.text in "([{":
            depth += 1
        elif t.kind == "punct" and t.text in ")]}":
            depth -= 1
        if depth == 0 and t.kind == "punct" and t.text == ",":
            parts.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        parts.append(cur)
    return parts


def normalize_attr(toks, extra_cfgs):
    """Returns a list of (category, name, text) for one attribute's tokens.

    category: verifier, verus_internal, verus, cfg, or other."""
    texts = [t.text for t in toks]
    s = " ".join(texts)
    if not texts:
        return []
    head = texts[0]
    if head == "verifier":
        if len(texts) > 2 and texts[1] == "::":
            return [("verifier", texts[2], s)]
        if len(texts) > 2 and texts[1] == "(":
            inner = toks[2:-1]
            return [("verifier", p[0].text, s) for p in split_commas(inner) if p]
        return [("verifier", "?", s)]
    if head in ("verus_verify", "verus_spec"):
        out = []
        if len(texts) > 1 and texts[1] == "(":
            for p in split_commas(toks[2:-1]):
                if p and p[0].text in TRUSTED_ATTRS | REPORT_ATTRS:
                    out.append(("verifier", p[0].text, s))
                elif p and p[0].text == "verifier" and len(p) > 2:
                    out.append(("verifier", p[2].text, s))
        return out
    if head == "verus":
        if len(texts) > 3 and texts[2] == "internal":
            return [("verus_internal", texts[4] if len(texts) > 4 else "?", s)]
        return [("verus", texts[2] if len(texts) > 2 else "?", s)]
    if head in ("cfg", "cfg_attr"):
        out = []
        if len(texts) > 1 and texts[1] == "(":
            parts = split_commas(toks[2:-1])
            pred = " ".join(t.text for t in parts[0]) if parts else ""
            if cfg_is_verus(pred, extra_cfgs):
                out.append(("cfg", head, s))
            if head == "cfg_attr":
                for p in parts[1:]:
                    out.extend(normalize_attr(p, extra_cfgs))
        return out
    return [("other", head, s)]


def cfg_is_verus(pred, extra_cfgs):
    if VERUS_CFG_RE.search(pred):
        return True
    return any(re.search(r"\b%s\b" % re.escape(c), pred) for c in extra_cfgs)


# ----------------------------------------------------------------------------
# Scanning.

@dataclass
class FileScan:
    crate: str
    rel: str           # path relative to the crate directory
    parser: Parser
    occurrences: list = field(default_factory=list)
    reports: list = field(default_factory=list)   # (kind, item, line, detail)


def owned_ranges(p, it):
    """Token ranges of an item that are not inside nested items."""
    if it.container and it.body:
        return [(it.start, it.body[0] + 1)]
    return [(it.start, it.end)]


def innermost_item(p, k):
    best = None
    for it in p.items:
        if it.start <= k < it.end and (best is None or it.end - it.start < best.end - best.start):
            best = it
    return best


def scan_file(crate, rel, path, extra_cfgs):
    src = open(path, encoding="utf-8").read()
    p = Parser(rel, src)
    p.parse()
    fs = FileScan(crate, rel, p)

    def occ(item, kind, line, detail=""):
        fs.occurrences.append(Occurrence(crate, rel, item, kind, line, detail))

    def classify_attr(item_name, a, line, is_use=False, module_level=False):
        for cat, name, text in normalize_attr(a.toks, extra_cfgs):
            if cat in ("verifier", "verus_internal", "verus") and module_level:
                occ(item_name, "inner_attr", line, f"#![{text}]")
            elif cat == "verifier":
                if name in REPORT_ATTRS:
                    fs.reports.append((name, item_name, line, f"#[{text}]"))
                elif name in BENIGN_ATTRS:
                    pass
                else:
                    occ(item_name, name, line, f"#[{text}]")
            elif cat == "verus_internal":
                occ(item_name, "verus_internal", line, f"#[{text}]")
            elif cat == "verus":
                occ(item_name, "verus_attr", line, f"#[{text}]")
            elif cat == "cfg" and not is_use:
                occ(item_name, "cfg", line, f"#[{text}]")

    # Item-level inner attributes (#![...] at file or module level).
    for a, prefix, _ in p.item_attrs_inner:
        classify_attr(prefix or "<module>", a, a.line, module_level=True)

    has_verus = bool(p.verus_regions)
    plain_kinds = {"fn", "struct", "enum", "union", "const", "static", "type", "macro",
                   "unknown", "extern"}
    plain_file_items = []
    toks = p.toks
    for it in p.items:
        name = it.name
        is_use = it.kind == "use"
        for a in it.attrs:
            classify_attr(name, a, a.line, is_use)
        # Scan owned tokens for attributes on expressions and escape idents.
        for (a, b) in owned_ranges(p, it):
            k = a
            # Skip the item's own leading attributes (already handled).
            while k < b:
                t = toks[k]
                if t.kind == "punct" and t.text == "#" and k + 1 < b:
                    inner = p.is_p(k + 1, "!")
                    bk = k + 2 if inner else k + 1
                    if p.is_p(bk, "["):
                        close = p.match[bk]
                        classify_attr(name, Attr(inner, toks[bk + 1:close], t.line), t.line)
                        k = close + 1
                        continue
                if t.kind == "ident":
                    if t.text in ESCAPE_CALLS and p.is_p(k + 1, "("):
                        occ(name, ESCAPE_CALLS[t.text], t.line)
                    elif t.text in ESCAPE_IDENTS:
                        occ(name, ESCAPE_IDENTS[t.text], t.line)
                    elif t.text == "cfg" and p.is_p(k + 1, "!") and p.is_p(k + 2, "("):
                        pred = " ".join(x.text for x in toks[k + 3:p.match[k + 2]])
                        if cfg_is_verus(pred, extra_cfgs):
                            occ(name, "cfg", t.line, f"cfg!({pred})")
                k += 1
        if it.kind == "fn":
            if "uninterp" in it.mods:
                occ(name, "uninterp", it.line)
            if "axiom" in it.mods:
                occ(name, "axiom", it.line)
            if (it.in_verus and "spec" in it.mods and it.body is None and not it.in_trait
                    and "uninterp" not in it.mods):
                occ(name, "bodiless_spec", it.line)
        if it.kind == "assume_specification":
            occ(name, "assume_specification", it.line)
        if it.kind == "global" and it.in_verus:
            occ(name, "global_layout", it.line)
        # Unverified code.
        if not it.in_verus and it.kind in plain_kinds:
            if has_verus:
                occ(name, "plain_rust_item", it.line)
            else:
                plain_file_items.append(it)
    if not has_verus and plain_file_items:
        occ("*", "plain_rust_file", 1, f"{len(plain_file_items)} items")
    return fs


# ----------------------------------------------------------------------------
# Reports: closed/opaque spec fns, empty proof fns, theorems.

def fn_mode(it):
    if "spec" in it.mods:
        return "spec"
    if "proof" in it.mods or "axiom" in it.mods:
        return "proof"
    return "exec"


def clause_tokens(p, it, clause):
    """Tokens of a requires/ensures clause in a fn signature."""
    end = it.body[0] if it.body else it.end
    toks = p.toks
    k = it.start
    out = None
    stops = {"requires", "ensures", "recommends", "decreases", "returns", "opens_invariants",
             "no_unwind", "default_ensures", "via", "when"}
    while k < end:
        t = toks[k]
        if t.kind == "ident" and t.text in stops:
            if out is not None:
                break
            if t.text == clause:
                out = []
            k += 1
            continue
        nk = p.skip_group(k)
        if out is not None:
            out.extend(toks[k:nk])
        k = nk
    return out


def signature(p, it):
    end = it.body[0] if it.body else it.end
    text = p.src[p.toks[it.start].start:p.toks[end - 1].end]
    # Strip comments line by line for readability is not needed; keep text.
    lines = text.rstrip().split("\n")
    first = lines[0]
    rest = lines[1:]
    indent = min((len(l) - len(l.lstrip()) for l in rest if l.strip()), default=0)
    base = max(indent - 4, 0)
    return "\n".join([first] + [l[base:] for l in rest])


def build_reports(scans):
    report = {"closed_spec": [], "opaque": [], "empty_proof": [], "rlimit": []}
    theorems = {}
    entry_points = {}
    for crate in CRATES:
        cs = [s for s in scans if s.crate == crate]
        # Identifier references across the crate (excluding fn name tokens of
        # definitions), split into verus! and all.
        refs_all = {}
        refs_verus = {}
        def_tok = set()
        for s in cs:
            p = s.parser
            for it in p.items:
                if it.kind == "fn":
                    k = it.start
                    while k < it.end and p.t(k) != "fn":
                        k += 1
                    def_tok.add((s.rel, k + 1))
        for s in cs:
            p = s.parser
            regions = p.verus_regions
            for k, t in enumerate(p.toks):
                if t.kind != "ident" or (s.rel, k) in def_tok:
                    continue
                refs_all[t.text] = refs_all.get(t.text, 0) + 1
                if any(a < k < b for a, b in regions):
                    refs_verus[t.text] = refs_verus.get(t.text, 0) + 1
        thms = []
        entries = []
        for s in cs:
            p = s.parser
            esc = {}
            for o in s.occurrences:
                esc.setdefault(o.item, set()).add(o.kind)

            def sig(it):
                kinds = esc.get(it.name)
                note = f"// NOTE: uses trusted {', '.join(sorted(kinds))}\n" if kinds else ""
                return note + signature(p, it)
            for it in p.items:
                if it.kind != "fn" or not it.in_verus:
                    continue
                mode = fn_mode(it)
                attr_names = {n for a in it.attrs for (_, n, _) in normalize_attr(a.toks, [])}
                trusted = bool(attr_names & TRUSTED_ATTRS) or "axiom" in it.mods
                if mode == "spec" and "closed" in it.mods:
                    report["closed_spec"].append((crate, s.rel, it.line, it.name))
                if mode == "spec" and attr_names & {"opaque", "opaque_outside_module"}:
                    report["opaque"].append((crate, s.rel, it.line, it.name))
                if "rlimit" in attr_names:
                    report["rlimit"].append((crate, s.rel, it.line, it.name))
                if mode == "proof" and it.body and not trusted:
                    ens = clause_tokens(p, it, "ensures")
                    trivial = ens is None or all(t.text in ("true", ",") for t in ens)
                    if it.body[1] == it.body[0] + 1 and not trivial:
                        report["empty_proof"].append((crate, s.rel, it.line, it.name))
                    if refs_all.get(it.simple, 0) == 0 and not it.in_trait:
                        thms.append((s.rel, it.line, it.name, sig(it)))
                if (mode == "exec" and it.body and not trusted and not it.in_trait
                        and clause_tokens(p, it, "ensures") is not None
                        and refs_verus.get(it.simple, 0) == 0):
                    entries.append((s.rel, it.line, it.name, sig(it)))
        theorems[crate] = thms
        entry_points[crate] = entries
    return report, theorems, entry_points


def write_theorems(path, theorems, entry_points):
    out = []
    out.append("# Generated by verified/tools/trust_audit.py (run verified/check.sh); do not edit.")
    out.append("#")
    out.append("# What the verified crates claim, for human review.")
    out.append("# Part 1: top-level theorems: proof fns inside verus! that are not referenced")
    out.append("#   anywhere else in their crate (by name; a same-named reference hides one).")
    out.append("# Part 2: verified exec entry points: exec fns inside verus! with an `ensures`")
    out.append("#   that no verified code calls; their contracts are what unverified callers")
    out.append("#   (FFI glue, reference interpreter) rely on.")
    out.append("# Items marked external_body/axiom are not listed; see TRUSTED.toml. Line")
    out.append("# numbers are omitted so that the diff of this file shows only claim changes.")
    out.append("")
    for title, data in (("Top-level theorems", theorems), ("Verified exec entry points", entry_points)):
        for crate, items in data.items():
            out.append("=" * 78)
            out.append(f"{title}: crate {crate} ({len(items)})")
            out.append("=" * 78)
            for rel, line, name, sig in items:
                out.append("")
                out.append(f"--- {name}  ({CRATES[crate][0]}/{rel})")
                out.append(sig)
            out.append("")
    text = "\n".join(out).rstrip() + "\n"
    old = open(path).read() if os.path.exists(path) else None
    with open(path, "w") as f:
        f.write(text)
    return old != text


# ----------------------------------------------------------------------------
# Allowlist.

def occurrence_groups(scans):
    groups = {}
    for s in scans:
        for o in s.occurrences:
            key = (o.crate, o.file, o.item, o.kind)
            groups.setdefault(key, []).append(o)
    return groups


def load_allowlist(path):
    if not os.path.exists(path):
        return []
    with open(path, "rb") as f:
        data = tomllib.load(f)
    return data.get("trusted", [])


def toml_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_allowlist(path, groups, old_entries):
    old = {(e["crate"], e["file"], e["item"], e["kind"]): e for e in old_entries}
    lines = [
        "# Copyright (C) 2026 Toit contributors.",
        "#",
        "# This library is free software; you can redistribute it and/or",
        "# modify it under the terms of the GNU Lesser General Public",
        "# License as published by the Free Software Foundation; version",
        "# 2.1 only.",
        "#",
        "# This library is distributed in the hope that it will be useful,",
        "# but WITHOUT ANY WARRANTY; without even the implied warranty of",
        "# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU",
        "# Lesser General Public License for more details.",
        "#",
        "# The license can be found in the file `LICENSE` in the top level",
        "# directory of this repository.",
        "",
        "# Allowlist of Verus escape hatches in verified/core and verified/spec:",
        "# every place where code is trusted instead of proven. Checked by",
        "# verified/check.sh (verified/tools/trust_audit.py); unlisted occurrences,",
        "# count changes and stale entries fail the check. Regenerate the skeleton",
        "# with `verified/check.sh --update-allowlist` (keeps justifications, new",
        "# entries get TODO, which fails until replaced). This list must only shrink.",
        "#",
        "# Fields: crate, file (relative to the crate), item (qualified name),",
        "# kind (see verified/README.md), count (occurrences of that kind in that",
        "# item), justification (one line).",
        "",
    ]
    for key in sorted(groups):
        crate, file, item, kind = key
        e = old.get(key, {})
        just = e.get("justification", "TODO")
        lines.append("[[trusted]]")
        lines.append(f"crate = {toml_str(crate)}")
        lines.append(f"file = {toml_str(file)}")
        lines.append(f"item = {toml_str(item)}")
        lines.append(f"kind = {toml_str(kind)}")
        lines.append(f"count = {len(groups[key])}")
        lines.append(f"justification = {toml_str(just)}")
        lines.append("")
    with open(path, "w") as f:
        f.write("\n".join(lines))


def check_allowlist(groups, entries):
    errors = []
    seen = set()
    by_key = {}
    for e in entries:
        missing = [f for f in ("crate", "file", "item", "kind", "justification") if f not in e]
        if missing:
            errors.append(f"TRUSTED.toml: entry {e} lacks {', '.join(missing)}")
            continue
        key = (e["crate"], e["file"], e["item"], e["kind"])
        if key in by_key:
            errors.append(f"TRUSTED.toml: duplicate entry {key}")
        by_key[key] = e
    for key, occs in sorted(groups.items()):
        crate, file, item, kind = key
        where = f"{CRATES[crate][0]}/{file}:{occs[0].line}"
        e = by_key.get(key)
        if e is None:
            detail = f" {occs[0].detail}" if occs[0].detail else ""
            errors.append(f"UNLISTED  {where}: {kind} in `{item}`{detail}"
                          f" ({len(occs)}x; lines {', '.join(str(o.line) for o in occs)})")
            continue
        seen.add(key)
        if "count" in e and e["count"] != len(occs):
            errors.append(f"COUNT     {where}: {kind} in `{item}`: allowlist says {e['count']},"
                          f" found {len(occs)} (lines {', '.join(str(o.line) for o in occs)})")
        j = e["justification"].strip()
        if not j or j.upper().startswith("TODO"):
            errors.append(f"NOJUSTIFY {where}: {kind} in `{item}` has no justification")
    for key, e in by_key.items():
        if key not in seen:
            errors.append(f"STALE     {CRATES.get(key[0], (key[0],))[0]}/{key[1]}: {key[3]} in"
                          f" `{key[2]}` is allowlisted but no longer occurs; remove the entry")
    return errors


def cargo_metadata_occurrences(root):
    out = []
    for crate, (d, _) in CRATES.items():
        path = os.path.join(root, d, "Cargo.toml")
        with open(path, "rb") as f:
            data = tomllib.load(f)
        meta = data.get("package", {}).get("metadata", {}).get("verus", {})
        for k, v in meta.items():
            if k == "verify" and v is True:
                continue
            out.append(Occurrence(crate, "Cargo.toml", f"metadata.verus.{k}", "cargo_metadata", 0,
                                  repr(v)))
        if meta.get("verify") is not True:
            out.append(Occurrence(crate, "Cargo.toml", "metadata.verus.verify", "cargo_metadata", 0,
                                  "verify is not true"))
    return out


def cross_check_docs(root, groups):
    """Allowlisted items that the crate's trust document does not mention."""
    misses = []
    for crate, doc in TRUST_DOCS.items():
        path = os.path.join(root, doc)
        if not os.path.exists(path):
            continue
        text = open(path).read()
        for (c, file, item, kind) in sorted(groups):
            if c != crate:
                continue
            if item in ("*", "<crate>"):
                needle = os.path.basename(file)
            else:
                needle = item.split("::")[-1]
            full_ok = item in text
            if full_ok or re.search(r"(?<![\w])%s(?![\w])" % re.escape(needle), text):
                continue
            misses.append(f"{doc}: does not mention `{item}` ({kind}, {CRATES[c][0]}/{file})")
    return misses


def no_cheating_check(scans, crate, log_path):
    """Every location Verus --no-cheating rejects must be in a flagged item."""
    errors = []
    text = open(log_path, errors="replace").read()
    locs = []
    lines = text.split("\n")
    for k, l in enumerate(lines):
        if l.startswith("error") and "--no-cheating" in l:
            for m in lines[k + 1:k + 4]:
                mm = re.match(r"\s*-->\s*(\S+?):(\d+):(\d+)", m)
                if mm:
                    locs.append((os.path.normpath(mm.group(1)), int(mm.group(2)), l.strip()))
                    break
    by_file = {s.rel: s for s in scans if s.crate == crate}
    flagged_kinds = {"external_body", "assume", "admit", "assume_specification", "axiom",
                     "uninterp", "bodiless_spec", "assume_termination", "global_layout",
                     "external_fn_specification", "assume_new", "verus_internal"}
    for f, line, msg in locs:
        s = by_file.get(f)
        if s is None:
            errors.append(f"--no-cheating: {crate}/{f}:{line}: file not scanned ({msg})")
            continue
        # Find the innermost item covering the line.
        cands = [it for it in s.parser.items if it.line <= line <= it.end_line]
        if any(it.attrs and min(a.line for a in it.attrs) <= line < it.line for it in s.parser.items):
            cands += [it for it in s.parser.items
                      if it.attrs and min(a.line for a in it.attrs) <= line < it.line]
        cands.sort(key=lambda it: it.end_line - it.line)
        names = {it.name for it in cands}
        ok = any(o.item in names and o.kind in flagged_kinds for o in s.occurrences)
        if not ok:
            errors.append(f"--no-cheating: Verus rejects {CRATES[crate][0]}/{f}:{line} but the"
                          f" scanner found no escape hatch there ({msg})")
    return errors, len(locs)


# ----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--root", default=os.path.dirname(here), help="the verified/ directory")
    ap.add_argument("--allowlist", default=None)
    ap.add_argument("--theorems", default=None)
    ap.add_argument("--update-allowlist", action="store_true")
    ap.add_argument("--no-cheating-log", action="append", default=[],
                    help="CRATE=FILE: output of verus --no-cheating for that crate")
    args = ap.parse_args()
    root = args.root
    allowlist = args.allowlist or os.path.join(root, "TRUSTED.toml")
    theorems_path = args.theorems or os.path.join(root, "THEOREMS.txt")

    failures = []
    scans = []
    warnings = []
    for crate, (d, cfgs) in CRATES.items():
        cdir = os.path.join(root, d)
        for dirpath, dirnames, filenames in os.walk(os.path.join(cdir, "src")):
            dirnames[:] = sorted(x for x in dirnames if x != "target")
            for fn in sorted(filenames):
                if not fn.endswith(".rs"):
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, cdir)
                try:
                    fs = scan_file(crate, rel, path, cfgs)
                except LexError as e:
                    failures.append(f"PARSE     {d}/{rel}: {e}")
                    continue
                scans.append(fs)
                for w in fs.parser.warnings:
                    (failures if "inside verus!" in w else warnings).append(f"PARSE     {d}/{w}")

    groups = occurrence_groups(scans)
    for o in cargo_metadata_occurrences(root):
        groups.setdefault((o.crate, o.file, o.item, o.kind), []).append(o)

    nfiles = len(scans)
    nocc = sum(len(v) for v in groups.values())
    print(f"Escape-hatch audit: {nfiles} files, {nocc} occurrences in {len(groups)} (item, kind) groups.")
    kinds = {}
    for (c, f, i, k), v in groups.items():
        kinds.setdefault((c, k), 0)
        kinds[(c, k)] += len(v)
    for (c, k), v in sorted(kinds.items()):
        print(f"  {c:5s} {k:32s} {v:4d}")

    if args.update_allowlist:
        write_allowlist(allowlist, groups, load_allowlist(allowlist))
        print(f"Wrote {allowlist}; fill in every TODO justification.")

    failures += check_allowlist(groups, load_allowlist(allowlist))

    for spec in args.no_cheating_log:
        crate, _, path = spec.partition("=")
        errs, n = no_cheating_check(scans, crate, path)
        print(f"Cross-check with `verus --no-cheating` ({crate}): {n} rejected locations,"
              f" {len(errs)} not found by the scanner.")
        failures += errs

    misses = cross_check_docs(root, groups)
    report, theorems, entry_points = build_reports(scans)
    changed = write_theorems(theorems_path, theorems, entry_points)

    def section(title, rows):
        print(f"\n{title} ({len(rows)}):")
        for r in rows:
            print(f"  {r}")

    section("Allowlisted items not mentioned in the crate's trust document (report only)", misses)
    section("Closed spec fns (report only)",
            [f"{CRATES[c][0]}/{f}:{l} {n}" for c, f, l, n in report["closed_spec"]])
    section("Opaque spec fns (report only)",
            [f"{CRATES[c][0]}/{f}:{l} {n}" for c, f, l, n in report["opaque"]])
    section("Proof fns with an empty body and a non-trivial ensures (report only)",
            [f"{CRATES[c][0]}/{f}:{l} {n}" for c, f, l, n in report["empty_proof"]])
    section("rlimit overrides (report only)",
            [f"{CRATES[c][0]}/{f}:{l} {n}" for c, f, l, n in report["rlimit"]])
    section("Parser warnings outside verus! (report only)", warnings)
    print(f"\nTheorems: " + ", ".join(f"{c}: {len(v)} top-level proof fns, "
                                       f"{len(entry_points[c])} exec entry points"
                                       for c, v in theorems.items()))
    print(f"Wrote {os.path.relpath(theorems_path, os.path.dirname(root))}"
          f"{' (CHANGED: review and commit it)' if changed else ' (unchanged)'}.")

    if failures:
        print(f"\nESCAPE-HATCH AUDIT FAILED ({len(failures)}):")
        for f in failures:
            print(f"  {f}")
        return 1
    print("\nEscape-hatch audit passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
