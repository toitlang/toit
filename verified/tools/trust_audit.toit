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

/**
Audit of the Verus escape hatches in verified/core, verified/spec and
  verified/vmverify.

Scans every Rust source of the crates for the ways Verus lets code be
  trusted instead of proven, and compares the result with the allowlist
  verified/TRUSTED.toml. Unlisted occurrences, count changes, entries
  without a justification and stale entries are failures. Also reports
  (without failing) closed/opaque spec fns, empty-bodied proof fns with an
  `ensures`, `rlimit` overrides, and writes the list of top-level theorems
  to verified/THEOREMS.txt.

The scanner tokenizes Rust (comments, strings and char literals never
  count), tracks `verus!` regions and attaches attributes to the item they
  precede. As an independent check, the locations Verus itself rejects
  with `--no-cheating` (passed with --verus-no-cheating-log) must all lie in
  items the scanner flagged.

Usage:
  toit run verified/tools/trust_audit.toit -- [--root DIR] [--update-allowlist]
      [--verus-no-cheating-log CRATE=FILE]...

Regression test: verified/tools/tests/trust_audit_test.sh.
*/

import cli
import fs
import host.directory
import host.file
import host.pipe
import system

import .toml

/** Crate name -> [directory relative to verified/, cfgs passed to Verus]. */
CRATES ::= {
  "core": ["core", ["toit_vcore_hosted"]],
  "spec": ["spec", []],
  // Plain Rust (no Verus): the trusted conversion from VM memory and the
  // glue around the verifier, linked into the VM. Audited, not verified.
  "vmverify": ["vmverify", []],
}

/**
Markdown files that document the trusted base of each crate. Every
  allowlisted item should be mentioned there; misses are reported.
*/
TRUST-DOCS ::= {
  "core": "core/TRUSTED.md",
  "spec": "spec/DESIGN.md",
  "vmverify": "vmverify/README.md",
}

/**
`#[verifier::X]` attributes, checked against Verus 0.2026.11.02 (by probing
  which names the installed `verus` accepts, and by reading vstd and
  verus_builtin_macros). Anything not listed as benign or report-only is
  treated as an escape hatch, so unknown or new attributes fail closed.
*/
TRUSTED-ATTRS ::= {
  "external_body",                     // Body not verified; contract assumed.
  "external",                          // Item ignored by Verus entirely.
  "external_fn_specification",         // Old form of assume_specification.
  "external_type_specification",       // Assumed spec of a foreign type.
  "external_trait_specification",      // Assumed spec of a foreign trait.
  "external_trait_extension",          // Assumed spec extension of a trait.
  "external_derive",                   // Derived impls not verified.
  "assume_termination",                // Termination assumed, not proven.
  "exec_allows_no_decreases_clause",   // Exec termination not proven.
  "truncate",                          // Cast wraps silently (semantic change).
  "when_used_as_spec",                 // Exec fn replaced by a spec fn in specs.
  "ghost_wrapper",                     // Internal.
  "tracked_swap_primitive",            // Internal trusted vstd primitive.
  "tracked_take_option_primitive",     // Internal trusted vstd primitive.
}
REPORT-ATTRS ::= {"rlimit", "opaque", "opaque_outside_module"}
BENIGN-ATTRS ::= {
  "trigger", "spinoff_prover", "inline", "verify", "accept_recursive_types",
  "reject_recursive_types", "reject_recursive_types_in_ground_variants",
  "ext_equal", "nonlinear", "integer_ring", "bit_vector", "memoize",
  "type_invariant", "custom_err", "prophetic", "allow_in_spec", "atomic",
  "loop_isolation", "spec", "proof", "exec", "no_auto_trigger",
  "auto_trigger", "all_triggers", "broadcast_forall",
  "allow_complex_invariants", "no_auto_loop_invariant", "auto_ext_equal",
}

/** Identifiers that are escape hatches when followed by `(`. */
ESCAPE-CALLS ::= {
  "assume": "assume",   // assume(e).
  "admit": "admit",     // admit().
}
/** Identifiers that are escape hatches wherever they appear in code. */
ESCAPE-IDENTS ::= {
  "assume_": "assume",                     // verus_builtin::assume_.
  "assume_new": "assume_new",              // Ghost/Tracked::assume_new.
  "assume_new_fallback": "assume_new",
  "inline_air_stmt": "inline_air",         // Needs -V allow-inline-air.
  "unsafe": "unsafe",
}

ITEM-KEYWORDS ::= {
  "fn", "struct", "enum", "union", "trait", "impl", "mod", "const",
  "static", "type", "use", "extern", "assume_specification", "global",
  "group",
}
MODIFIERS ::= {
  "pub", "open", "closed", "uninterp", "spec", "proof", "exec", "axiom",
  "broadcast", "tracked", "ghost", "default", "async", "unsafe", "safe",
  "const", "extern",
}
/** The modifiers that need no lookahead in $Parser.parse-item. */
PLAIN-MODIFIERS ::= {
  "open", "closed", "uninterp", "proof", "exec", "axiom", "broadcast",
  "tracked", "ghost", "async",
}
/**
Tokens that can start an item (used to find where a fn body ends: a brace
  group followed by one of these, or by the end of the enclosing block).
*/
ITEM-START ::= set-union [ITEM-KEYWORDS, MODIFIERS, {"#", "verus", "layout"}]

set-union sets/List -> Set:
  result := {}
  sets.do: result.add-all it
  return result

/** The kinds the --no-cheating cross-check accepts as flagging an item. */
FLAGGED-KINDS ::= {
  "external_body", "assume", "admit", "assume_specification", "axiom",
  "uninterp", "bodiless_spec", "assume_termination", "global_layout",
  "external_fn_specification", "assume_new", "verus_internal",
}

// ----------------------------------------------------------------------------
// Tokenizer.

IDENT ::= 0
PUNCT ::= 1
LIT ::= 2
LIFETIME ::= 3

class Tok:
  kind/int
  text/string
  start/int  // Byte offsets in the source.
  end/int
  line/int

  constructor .kind .text .start .end .line:

  is-punct s/string -> bool: return kind == PUNCT and text == s

class LexError:
  message/string
  constructor .message:
  stringify -> string: return message

is-ascii-alpha c/int -> bool:
  return 'a' <= c <= 'z' or 'A' <= c <= 'Z'

is-ascii-digit c/int -> bool:
  return '0' <= c <= '9'

is-ident-start c/int -> bool:
  return is-ascii-alpha c or c == '_'

is-ident-char c/int -> bool:
  return is-ascii-alpha c or is-ascii-digit c or c == '_'

/** Whitespace as Python's str.isspace sees it. */
is-space-rune c/int -> bool:
  if c == ' ' or '\t' <= c <= '\r' or 0x1c <= c <= 0x1f: return true
  if c < 0x80: return false
  return c == 0x85 or c == 0xa0 or c == 0x1680 or 0x2000 <= c <= 0x200a
      or c == 0x2028 or c == 0x2029 or c == 0x202f or c == 0x205f or c == 0x3000

/**
Whether $c is a word character of a regular expression (`\w`): ASCII
  letters, digits and underscore, and the letters and digits of the
  common non-ASCII scripts.
*/
is-word-rune c/int -> bool:
  if c < 0x80: return is-ident-char c
  if c == 0xaa or c == 0xb5 or c == 0xba or c == 0xb2 or c == 0xb3 or c == 0xb9: return true
  if 0xbc <= c <= 0xbe: return true
  if 0xc0 <= c <= 0x2af: return c != 0xd7 and c != 0xf7
  if 0x370 <= c <= 0x3ff: return c != 0x375 and c != 0x37e and c != 0x384 and c != 0x385 and c != 0x387 and c != 0x3f6
  if 0x400 <= c <= 0x52f: return not (0x482 <= c <= 0x489)
  if 0x4e00 <= c <= 0x9fff or 0xac00 <= c <= 0xd7a3: return true
  return false

/** The number of bytes of the UTF-8 sequence that starts with byte $b. */
utf8-length b/int -> int:
  if b < 0x80: return 1
  if b < 0xe0: return 2
  if b < 0xf0: return 3
  return 4

/** The rune at byte index $i of $src (which must start a character). */
rune-at src/string i/int -> int:
  return src[i]

// Byte at index $i, or -1 past the end.
byte-at src/string i/int -> int:
  return i < src.size ? (src.at --raw i) : -1

count-newlines src/string from/int to/int -> int:
  n := 0
  for i := from; i < to; i++:
    if (src.at --raw i) == '\n': n++
  return n

/** The end of the identifier that starts at $i, or $i if none does. */
ident-end src/string i/int -> int:
  if i >= src.size or not is-ident-start (src.at --raw i): return i
  j := i + 1
  while j < src.size and is-ident-char (src.at --raw j): j++
  return j

/**
The end of the number literal at $i (without suffix), like the regular
  expression `0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*`
  followed by an optional fraction `(\.[0-9][0-9_]*)?` and an optional
  exponent `([eE][+-]?[0-9_]+)?`.
*/
number-end src/string i/int -> int:
  n := src.size
  if (byte-at src i) == '0':
    c := byte-at src i + 1
    prefix-digit := null
    if c == 'x' or c == 'X': prefix-digit = (:: | d | is-ascii-digit d or 'a' <= d <= 'f' or 'A' <= d <= 'F' or d == '_')
    else if c == 'o' or c == 'O': prefix-digit = (:: | d | '0' <= d <= '7' or d == '_')
    else if c == 'b' or c == 'B': prefix-digit = (:: | d | d == '0' or d == '1' or d == '_')
    if prefix-digit and i + 2 < n and (prefix-digit.call (src.at --raw i + 2)):
      j := i + 3
      while j < n and (prefix-digit.call (src.at --raw j)): j++
      return j
  digit-or-underscore := : | d | is-ascii-digit d or d == '_'
  j := i + 1
  while j < n and (digit-or-underscore.call (src.at --raw j)): j++
  if (byte-at src j) == '.' and j + 1 < n and is-ascii-digit (src.at --raw j + 1):
    j += 2
    while j < n and (digit-or-underscore.call (src.at --raw j)): j++
  e := byte-at src j
  if e == 'e' or e == 'E':
    k := j + 1
    sign := byte-at src k
    if sign == '+' or sign == '-': k++
    if k < n and (digit-or-underscore.call (src.at --raw k)):
      k++
      while k < n and (digit-or-underscore.call (src.at --raw k)): k++
      j = k
  return j

/** Index of the first occurrence of $needle in $src at or after $from, or -1. */
find src/string needle/string from/int -> int:
  return src.index-of needle from

tokenize src/string -> List:
  toks := []
  i := 0
  n := src.size
  line := 1
  add := : | kind/int j/int |
    toks.add (Tok kind src[i..j] i j line)
    line += count-newlines src i j
    i = j
  while i < n:
    c := src.at --raw i
    if c == '\n':
      line++
      i++
      continue
    if c >= 0x80:
      rune := rune-at src i
      if is-space-rune rune:
        i += utf8-length c
        continue
    else if is-space-rune c:
      i++
      continue
    if c == '/' and (byte-at src i + 1) == '/':
      j := find src "\n" i
      i = j < 0 ? n : j
      continue
    if c == '/' and (byte-at src i + 1) == '*':
      depth := 0
      j := i
      while j < n:
        if (src.at --raw j) == '/' and (byte-at src j + 1) == '*':
          depth++
          j += 2
        else if (src.at --raw j) == '*' and (byte-at src j + 1) == '/':
          depth--
          j += 2
          if depth == 0: break
        else:
          j++
      if depth != 0: throw (LexError "line $line: unterminated block comment")
      line += count-newlines src i j
      i = j
      continue
    // Raw strings: r"..", r#".."#, br"..", cr"..".
    raw-start := i
    if c == 'b' or c == 'c': raw-start = i + 1
    if (byte-at src raw-start) == 'r':
      h := raw-start + 1
      while (byte-at src h) == '#' and h - raw-start <= 300: h++
      if (byte-at src h) == '"' and h - i < 300:
        hashes := src[raw-start + 1..h]
        close := "\"$hashes"
        j := find src close (h + 1)
        if j < 0: throw (LexError "line $line: unterminated raw string")
        add.call LIT (j + close.size)
        continue
    // Normal and byte/C strings.
    if c == '"' or ((c == 'b' or c == 'c') and (byte-at src i + 1) == '"'):
      j := i + (c == '"' ? 1 : 2)
      while j < n and (src.at --raw j) != '"':
        j += (src.at --raw j) == '\\' ? 2 : 1
      if j >= n: throw (LexError "line $line: unterminated string")
      add.call LIT (j + 1)
      continue
    // Byte char b'x'.
    if c == 'b' and (byte-at src i + 1) == '\'':
      j := i + 2
      while j < n and (src.at --raw j) != '\'':
        j += (src.at --raw j) == '\\' ? 2 : 1
      add.call LIT (min n (j + 1))
      continue
    // Raw identifier r#name.
    if c == 'r' and (byte-at src i + 1) == '#' and i + 2 < n:
      c2 := src.at --raw i + 2
      if is-ident-start c2:
        j := ident-end src (i + 2)
        toks.add (Tok IDENT src[i + 2..j] i j line)
        i = j
        continue
      if c2 >= 0x80 and is-word-rune (rune-at src i + 2): throw (LexError "line $line: non-ASCII identifier")
    if is-ident-start c:
      add.call IDENT (ident-end src i)
      continue
    if is-ascii-digit c:
      j := number-end src i
      // Literal suffix (u8, f64, usize, ...).
      j = ident-end src j
      add.call LIT j
      continue
    if c == '\'':
      // Char literal or lifetime.
      if (byte-at src i + 1) == '\\':
        j := i + 2
        while j < n and (src.at --raw j) != '\'':
          j += (src.at --raw j) == '\\' ? 2 : 1
        add.call LIT (min n (j + 1))
        continue
      if i + 1 < n:
        width := utf8-length (src.at --raw i + 1)
        if (byte-at src i + 1 + width) == '\'':
          add.call LIT (i + 2 + width)
          continue
      j := ident-end src (i + 1)
      if j > i + 1:
        add.call LIFETIME j
        continue
      add.call PUNCT (i + 1)
      continue
    if c == ':' and (byte-at src i + 1) == ':':
      add.call PUNCT (i + 2)
      continue
    if c >= 0x80:
      // Python's tokenizer took letters and digits for the start of an
      // identifier or a number and failed on them.
      rune := rune-at src i
      if is-word-rune rune: throw (LexError "line $line: non-ASCII identifier")
      add.call PUNCT (i + (utf8-length c))
      continue
    add.call PUNCT (i + 1)
  return toks

// ----------------------------------------------------------------------------
// Parser: items, attributes, verus! regions.

class Attr:
  inner/bool
  toks/List  // The tokens between the brackets.
  line/int

  constructor .inner .toks .line:

class Item:
  kind/string  // fn, struct, impl, ...
  name/string  // Qualified name (Type::method).
  simple/string  // Last name segment.
  mods/Set
  attrs/List
  start/int  // Token index of the first token after the attributes.
  end/int  // Token index after the item.
  body/List?  // [open, close] token indices of the fn body, or null.
  in-verus/bool
  in-trait/bool
  line/int
  end-line/int
  container/bool

  constructor .kind .name .simple .mods .attrs .start .end .body .in-verus .in-trait
      .line .end-line .container:

class Occurrence:
  crate/string
  file/string
  item/string
  kind/string
  line/int
  detail/string

  constructor .crate .file .item .kind .line .detail="":

  key -> string: return group-key crate file item kind

/**
A key that sorts like the tuple (crate, file, item, kind): the fields
  joined by a character that sorts before every other.
*/
group-key crate/string file/string item/string kind/string -> string:
  return "$crate\0$file\0$item\0$kind"

class Parser:
  path/string
  src/string
  toks/List
  match/Map := {:}
  items/List := []
  warnings/List := []
  verus-regions/List := []  // [start, end] token index ranges.
  item-attrs-inner/List := []  // [Attr, prefix, in-verus] at item level.

  constructor .path .src:
    toks = tokenize src
    match-brackets

  match-brackets -> none:
    pairs := {")": "(", "]": "[", "}": "{"}
    stack := []
    toks.size.repeat: | k |
      t/Tok := toks[k]
      if t.kind == PUNCT:
        if t.text == "(" or t.text == "[" or t.text == "{":
          stack.add k
        else if t.text == ")" or t.text == "]" or t.text == "}":
          if stack.is-empty or toks[stack.last].text != pairs[t.text]:
            throw (LexError "$path:$t.line: unbalanced '$t.text'")
          o := stack.remove-last
          match[o] = k
          match[k] = o
    if not stack.is-empty:
      throw (LexError "$path:$toks[stack.last].line: unclosed bracket")

  t k/int -> string:
    return 0 <= k < toks.size ? toks[k].text : ""

  is-p k/int s/string -> bool:
    return 0 <= k < toks.size and toks[k].kind == PUNCT and toks[k].text == s

  is-group-open k/int -> bool:
    return is-p k "(" or is-p k "[" or is-p k "{"

  /** If $k opens a group, the index after it; else $k + 1. */
  skip-group k/int -> int:
    if is-group-open k: return match[k] + 1
    return k + 1

  scan-to-semi k/int end/int -> int:
    while k < end and not is-p k ";":
      k = skip-group k
    return min (k + 1) end

  parse -> none:
    parse-items 0 toks.size "" false false

  parse-items k/int end/int prefix/string in-verus/bool in-trait/bool -> none:
    while k < end:
      attrs := []
      while k < end and is-p k "#":
        inner := is-p k + 1 "!"
        b := inner ? k + 2 : k + 1
        if not is-p b "[": break
        close := match[b]
        a := Attr inner toks[b + 1..close] toks[k].line
        if inner:
          item-attrs-inner.add [a, prefix, in-verus]
        else:
          attrs.add a
        k = close + 1
      if k >= end: break
      if is-p k ";":
        k++
        continue
      tok/Tok := toks[k]
      // Macro invocation: verus! { ... } or other!{...}.
      if tok.kind == IDENT and (is-p k + 1 "!") and not ITEM-KEYWORDS.contains tok.text:
        g := k + 2
        if tok.text == "macro_rules": g = k + 3
        tg := t g
        if tg == "{" or tg == "(" or tg == "[":
          close := match[g]
          if tok.text == "verus":
            verus-regions.add [g, close]
            add-item "verus_block" prefix "verus!" {} attrs k (close + 1) [g, close] in-verus in-trait
                --container
            parse-items (g + 1) close prefix true false
          else:
            add-item "macro" prefix "$(tok.text)!" {} attrs k (close + 1) null in-verus in-trait
          k = close + 1
          if is-p k ";": k++
          continue
      k = parse-item k end attrs prefix in-verus in-trait

  add-item kind/string prefix/string name/string mods/Set attrs/List start/int end/int
      body/List? in-verus/bool in-trait/bool --container/bool=false -> Item:
    qual := prefix.is-empty ? name : "$prefix::$name"
    first-line := toks[start].line
    last-line := toks[end - 1].line
    it := Item kind qual name mods attrs start end body in-verus in-trait first-line last-line container
    items.add it
    return it

  parse-item k/int end/int attrs/List prefix/string in-verus/bool in-trait/bool -> int:
    start := k
    mods := {}
    while k < end:
      w := t k
      if toks[k].kind != IDENT: break
      if w == "pub":
        mods.add "pub"
        k++
        if is-p k "(": k = match[k] + 1
        continue
      if w == "spec":
        mods.add "spec"
        k++
        if is-p k "(": k = match[k] + 1
        continue
      if w == "extern":
        // extern crate / extern "C" fn / extern "C" { ... }
        if (t k + 1) == "crate": break
        k++
        if toks[k].kind == LIT: k++
        if is-p k "{":
          close := match[k]
          extern-mods := set-union [mods, {"extern"}]
          add-item "extern" prefix "extern" extern-mods attrs start (close + 1) null in-verus in-trait --container
          parse-items (k + 1) close prefix in-verus false
          return close + 1
        mods.add "extern"
        continue
      next := t k + 1
      if w == "const" and (next == "fn" or next == "unsafe" or next == "async" or next == "extern"):
        mods.add "const"
        k++
        continue
      if w == "default" and (next == "fn" or next == "unsafe" or next == "const" or next == "type" or next == "impl"):
        mods.add "default"
        k++
        continue
      if w == "unsafe" and (next == "fn" or next == "impl" or next == "trait" or next == "extern"):
        mods.add "unsafe"
        k++
        continue
      if w == "safe" and (next == "fn" or next == "static"):
        mods.add "safe"
        k++
        continue
      if PLAIN-MODIFIERS.contains w:
        if w == "broadcast" and (next == "use" or next == "group"):
          mods.add "broadcast"
          k++
          continue
        if (w == "tracked" or w == "ghost") and not ITEM-KEYWORDS.contains next and not MODIFIERS.contains next:
          break
        mods.add w
        k++
        if (w == "open" or w == "closed") and is-p k "(": k = match[k] + 1
        continue
      break
    w := t k
    if w == "fn":
      name := t k + 1
      j := k + 2
      body := null
      while j < end:
        if is-p j ";":
          j++
          break
        if is-p j "{":
          close := match[j]
          nxt := close + 1
          if nxt >= end or ITEM-START.contains (t nxt) or is-p nxt ";"
              or (toks[nxt].kind == IDENT and is-p nxt + 1 "!"):
            body = [j, close]
            j = close + 1
            break
          j = close + 1
          continue
        j = skip-group j
      add-item "fn" prefix name mods attrs start j body in-verus in-trait
      return j
    if w == "struct" or w == "enum" or w == "union":
      name := t k + 1
      j := k + 2
      while j < end:
        if is-p j ";":
          j++
          break
        if is-p j "{":
          j = match[j] + 1
          break
        j = skip-group j
      add-item w prefix name mods attrs start j null in-verus in-trait
      return j
    if w == "trait" or w == "impl" or w == "mod":
      j := k + 1
      header := []
      while j < end and not is-p j "{" and not is-p j ";":
        header.add j
        tj := t j
        j = (tj == "(" or tj == "[") ? skip-group j : j + 1
      if is-p j ";":  // mod foo;
        add-item "mod_decl" prefix (t k + 1) mods attrs start (j + 1) null in-verus in-trait
        return j + 1
      name := w != "impl" ? (t k + 1) : (impl-name header)
      if not match.contains j: throw (LexError "$path:$toks[start].line: $w without a body")
      close := match[j]
      add-item w prefix name mods attrs start (close + 1) [j, close] in-verus in-trait --container
      sub := (not prefix.is-empty and w == "mod") ? "$prefix::$name" : name
      parse-items (j + 1) close sub in-verus (w == "trait")
      return close + 1
    if w == "const" or w == "static" or w == "type" or w == "use" or w == "global"
        or (w == "extern" and (t k + 1) == "crate"):
      name := t k + 1
      if w == "use": name = "use"
      if name == "mut": name = t k + 2
      j := scan-to-semi (k + 1) end
      add-item w prefix name mods attrs start j null in-verus in-trait
      return j
    if w == "group":  // broadcast group name { ... }
      name := t k + 1
      j := k + 2
      if is-p j "{": j = match[j] + 1
      add-item "broadcast_group" prefix name mods attrs start j null in-verus in-trait
      return j
    if w == "assume_specification":
      j := k + 1
      name := "?"
      while j < end and not is-p j "[": j++
      if j < end:
        close := match[j]
        name = (toks[j + 1..close].map: it.text).join ""
      j = scan-to-semi j end
      add-item "assume_specification" prefix name mods attrs start j null in-verus in-trait
      return j
    // Unknown: record a warning and skip to the next `;` or group.
    tk/Tok := k < toks.size ? toks[k] : toks.last
    warnings.add "$path:$tk.line: unrecognized item at `$tk.text`$(in-verus ? " (inside verus!)" : "")"
    j := k
    while j < end and not is-p j ";" and not is-p j "{":
      j = skip-group j
    if j < end and is-p j "{": j = match[j]
    j = min (j + 1) end
    add-item "unknown" prefix "?$tk.line" mods attrs start j null in-verus in-trait
    return j

  impl-name header/List -> string:
    texts := header.map: toks[it].text
    kinds := header.map: toks[it].kind
    // Drop leading generics: impl<...>.
    k := 0
    if k < texts.size and texts[k] == "<":
      depth := 0
      while k < texts.size:
        if texts[k] == "<":
          depth++
        else if texts[k] == ">":
          depth--
          if depth == 0:
            k++
            break
        k++
    texts = texts[k..]
    kinds = kinds[k..]
    for-index := texts.index-of "for"
    if for-index >= 0:
      texts = texts[for-index + 1..]
      kinds = kinds[for-index + 1..]
    where-index := texts.index-of "where"
    if where-index >= 0:
      texts = texts[..where-index]
      kinds = kinds[..where-index]
    // Type name: last path segment before generics.
    name := null
    depth := 0
    texts.size.repeat: | i |
      x := texts[i]
      if x == "<":
        depth++
      else if x == ">":
        depth--
      else if depth == 0 and kinds[i] == IDENT:
        name = x
    return name or "impl"

// ----------------------------------------------------------------------------
// Attribute normalization.

split-commas toks/List -> List:
  parts := []
  cur := []
  depth := 0
  toks.do: | t/Tok |
    if t.kind == PUNCT and (t.text == "(" or t.text == "[" or t.text == "{"):
      depth++
    else if t.kind == PUNCT and (t.text == ")" or t.text == "]" or t.text == "}"):
      depth--
    if depth == 0 and t.kind == PUNCT and t.text == ",":
      parts.add cur
      cur = []
    else:
      cur.add t
  if not cur.is-empty: parts.add cur
  return parts

/**
Returns a list of [category, name, text] for one attribute's tokens.

category: verifier, verus_internal, verus, cfg, or other.
*/
normalize-attr toks/List extra-cfgs/List -> List:
  texts := toks.map: it.text
  s := texts.join " "
  if texts.is-empty: return []
  head := texts[0]
  if head == "verifier":
    if texts.size > 2 and texts[1] == "::":
      return [["verifier", texts[2], s]]
    if texts.size > 2 and texts[1] == "(":
      inner := toks[2..toks.size - 1]
      result := []
      (split-commas inner).do: | p |
        if not p.is-empty: result.add ["verifier", p[0].text, s]
      return result
    return [["verifier", "?", s]]
  if head == "verus_verify" or head == "verus_spec":
    result := []
    if texts.size > 1 and texts[1] == "(":
      (split-commas toks[2..toks.size - 1]).do: | p |
        if not p.is-empty and (TRUSTED-ATTRS.contains p[0].text or REPORT-ATTRS.contains p[0].text):
          result.add ["verifier", p[0].text, s]
        else if not p.is-empty and p[0].text == "verifier" and p.size > 2:
          result.add ["verifier", p[2].text, s]
    return result
  if head == "verus":
    if texts.size > 3 and texts[2] == "internal":
      return [["verus_internal", texts.size > 4 ? texts[4] : "?", s]]
    return [["verus", texts.size > 2 ? texts[2] : "?", s]]
  if head == "cfg" or head == "cfg_attr":
    result := []
    if texts.size > 1 and texts[1] == "(":
      parts := split-commas toks[2..toks.size - 1]
      pred := parts.is-empty ? "" : ((parts[0].map: it.text).join " ")
      if cfg-is-verus pred extra-cfgs:
        result.add ["cfg", head, s]
      if head == "cfg_attr":
        for i := 1; i < parts.size; i++:
          result.add-all (normalize-attr parts[i] extra-cfgs)
    return result
  return [["other", head, s]]

/** The rune that ends just before byte index $i of $s, or -1 at the start. */
rune-before s/string i/int -> int:
  if i == 0: return -1
  j := i - 1
  while j > 0 and ((s.at --raw j) & 0xc0) == 0x80: j--
  return s[j]

/** The rune at byte index $i of $s, or -1 at the end. */
rune-after s/string i/int -> int:
  return i < s.size ? s[i] : -1

/**
Whether $needle occurs in $text as a whole word: neither preceded nor
  followed by a word character (the regular expression
  `(?<![\w])needle(?![\w])`). With $prefix-only, only the start must be at
  a word boundary and the word may continue (`\bneedle\w*\b`).
*/
contains-word text/string needle/string --prefix-only/bool=false -> bool:
  if needle.is-empty:
    // An empty needle matches between two non-word characters.
    for i := 0; i <= text.size; i++:
      if i < text.size and ((text.at --raw i) & 0xc0) == 0x80: continue
      if not is-word-rune (rune-before text i) and not is-word-rune (rune-after text i): return true
    return false
  from := 0
  while true:
    i := text.index-of needle from
    if i < 0: return false
    before := rune-before text i
    if not is-word-rune before:
      if prefix-only:
        // `\b` before the needle needs a word character at its start.
        if is-word-rune (rune-after text i): return true
      else if not is-word-rune (rune-after text (i + needle.size)):
        return true
    from = i + 1

cfg-is-verus pred/string extra-cfgs/List -> bool:
  if contains-word pred "verus" --prefix-only: return true
  return extra-cfgs.any: | c |
    // `\bc\b`: a word boundary on both sides; c is an identifier.
    contains-word pred c

// ----------------------------------------------------------------------------
// Scanning.

class FileScan:
  crate/string
  rel/string  // Path relative to the crate directory.
  parser/Parser
  extra-cfgs/List
  occurrences/List := []
  reports/List := []  // [kind, item, line, detail].

  constructor .crate .rel .parser .extra-cfgs:

  occ item/string kind/string line/int detail/string="" -> none:
    occurrences.add (Occurrence crate rel item kind line detail)

  classify-attr item-name/string a/Attr line/int --is-use/bool=false --module-level/bool=false -> none:
    (normalize-attr a.toks extra-cfgs).do: | entry |
      cat/string := entry[0]
      name/string := entry[1]
      text/string := entry[2]
      if (cat == "verifier" or cat == "verus_internal" or cat == "verus") and module-level:
        occ item-name "inner_attr" line "#![$text]"
      else if cat == "verifier":
        if REPORT-ATTRS.contains name:
          reports.add [name, item-name, line, "#[$text]"]
        else if not BENIGN-ATTRS.contains name:
          occ item-name name line "#[$text]"
      else if cat == "verus_internal":
        occ item-name "verus_internal" line "#[$text]"
      else if cat == "verus":
        occ item-name "verus_attr" line "#[$text]"
      else if cat == "cfg" and not is-use:
        occ item-name "cfg" line "#[$text]"

owned-ranges it/Item -> List:
  if it.container and it.body: return [[it.start, it.body[0] + 1]]
  return [[it.start, it.end]]

PLAIN-KINDS ::= {
  "fn", "struct", "enum", "union", "const", "static", "type", "macro",
  "unknown", "extern",
}

scan-file crate/string rel/string path/string extra-cfgs/List -> FileScan:
  src := (file.read-contents path).to-string
  p := Parser rel src
  p.parse
  scan := FileScan crate rel p extra-cfgs

  // Item-level inner attributes (#![...] at file or module level).
  p.item-attrs-inner.do: | entry |
    a/Attr := entry[0]
    prefix/string := entry[1]
    scan.classify-attr (prefix.is-empty ? "<module>" : prefix) a a.line --module-level

  has-verus := not p.verus-regions.is-empty
  plain-file-items := []
  toks := p.toks
  p.items.do: | item/Item |
    name := item.name
    is-use := item.kind == "use"
    item.attrs.do: | a/Attr |
      scan.classify-attr name a a.line --is-use=is-use
    // Scan owned tokens for attributes on expressions and escape idents.
    (owned-ranges item).do: | range |
      k := range[0]
      b := range[1]
      while k < b:
        t/Tok := toks[k]
        if t.kind == PUNCT and t.text == "#" and k + 1 < b:
          inner := p.is-p k + 1 "!"
          bk := inner ? k + 2 : k + 1
          if p.is-p bk "[":
            close := p.match[bk]
            scan.classify-attr name (Attr inner toks[bk + 1..close] t.line) t.line
            k = close + 1
            continue
        if t.kind == IDENT:
          if ESCAPE-CALLS.contains t.text and (p.is-p k + 1 "("):
            scan.occ name ESCAPE-CALLS[t.text] t.line
          else if ESCAPE-IDENTS.contains t.text:
            scan.occ name ESCAPE-IDENTS[t.text] t.line
          else if t.text == "cfg" and (p.is-p k + 1 "!") and (p.is-p k + 2 "("):
            pred := (toks[k + 3..p.match[k + 2]].map: it.text).join " "
            if cfg-is-verus pred extra-cfgs:
              scan.occ name "cfg" t.line "cfg!($pred)"
        k++
    if item.kind == "fn":
      if item.mods.contains "uninterp": scan.occ name "uninterp" item.line
      if item.mods.contains "axiom": scan.occ name "axiom" item.line
      if item.in-verus and (item.mods.contains "spec") and item.body == null and not item.in-trait
          and not item.mods.contains "uninterp":
        scan.occ name "bodiless_spec" item.line
    if item.kind == "assume_specification":
      scan.occ name "assume_specification" item.line
    if item.kind == "global" and item.in-verus:
      scan.occ name "global_layout" item.line
    // Unverified code.
    if not item.in-verus and PLAIN-KINDS.contains item.kind:
      if has-verus:
        scan.occ name "plain_rust_item" item.line
      else:
        plain-file-items.add item
  if not has-verus and not plain-file-items.is-empty:
    scan.occ "*" "plain_rust_file" 1 "$plain-file-items.size items"
  return scan

// ----------------------------------------------------------------------------
// Reports: closed/opaque spec fns, empty proof fns, theorems.

fn-mode it/Item -> string:
  if it.mods.contains "spec": return "spec"
  if it.mods.contains "proof" or it.mods.contains "axiom": return "proof"
  return "exec"

CLAUSE-STOPS ::= {
  "requires", "ensures", "recommends", "decreases", "returns", "opens_invariants",
  "no_unwind", "default_ensures", "via", "when",
}

/** Tokens of a requires/ensures clause in a fn signature, or null. */
clause-tokens p/Parser it/Item clause/string -> List?:
  end := it.body ? it.body[0] : it.end
  toks := p.toks
  k := it.start
  out := null
  while k < end:
    t/Tok := toks[k]
    if t.kind == IDENT and CLAUSE-STOPS.contains t.text:
      if out != null: break
      if t.text == clause: out = []
      k++
      continue
    nk := p.skip-group k
    if out != null: out.add-all toks[k..nk]
    k = nk
  return out

/** $s without leading whitespace (Python's str.lstrip). */
lstrip s/string -> string:
  i := 0
  while i < s.size:
    c := s.at --raw i
    if c < 0x80:
      if not is-space-rune c: break
      i++
    else:
      if not is-space-rune s[i]: break
      i += utf8-length c
  return s[i..]

/** $s without trailing whitespace (Python's str.rstrip). */
rstrip s/string -> string:
  i := s.size
  while i > 0:
    j := i - 1
    while j > 0 and ((s.at --raw j) & 0xc0) == 0x80: j--
    if not is-space-rune s[j]: break
    i = j
  return s[..i]

strip s/string -> string: return lstrip (rstrip s)

signature p/Parser it/Item -> string:
  end := it.body ? it.body[0] : it.end
  text := p.src[p.toks[it.start].start..p.toks[end - 1].end]
  lines := (rstrip text).split "\n"
  first := lines[0]
  rest := lines[1..]
  indent := null
  rest.do: | l/string |
    if not (strip l).is-empty:
      width := l.size - (lstrip l).size
      if indent == null or width < indent: indent = width
  base := max ((indent or 0) - 4) 0
  result := [first]
  rest.do: | l/string |
    result.add (l.size <= base ? "" : l[base..])
  return result.join "\n"

class Reports:
  closed-spec := []
  opaque := []
  empty-proof := []
  rlimit := []
  theorems := {:}  // Crate -> [rel, line, name, signature].
  entry-points := {:}

build-reports scans/List -> Reports:
  reports := Reports
  CRATES.do --keys: | crate |
    cs := scans.filter: it.crate == crate
    // Identifier references across the crate (excluding fn name tokens of
    // definitions), split into verus! and all.
    refs-all := {:}
    refs-verus := {:}
    def-tok := {}
    cs.do: | s/FileScan |
      p := s.parser
      p.items.do: | it/Item |
        if it.kind == "fn":
          k := it.start
          while k < it.end and (p.t k) != "fn": k++
          def-tok.add "$s.rel\0$(k + 1)"
    cs.do: | s/FileScan |
      p := s.parser
      regions := p.verus-regions
      p.toks.size.repeat: | k |
        t/Tok := p.toks[k]
        if t.kind == IDENT and not def-tok.contains "$s.rel\0$k":
          refs-all[t.text] = (refs-all.get t.text --if-absent=: 0) + 1
          in-region := regions.any: it[0] < k and k < it[1]
          if in-region:
            refs-verus[t.text] = (refs-verus.get t.text --if-absent=: 0) + 1
    thms := []
    entries := []
    cs.do: | s/FileScan |
      p := s.parser
      esc := {:}
      s.occurrences.do: | o/Occurrence |
        (esc.get o.item --init=: {}).add o.kind
      sig := : | it/Item |
        kinds := esc.get it.name
        note := ""
        if kinds:
          sorted := kinds.to-list
          sorted.sort --in-place
          note = "// NOTE: uses trusted $(sorted.join ", ")\n"
        note + (signature p it)
      p.items.do: | it/Item |
        if it.kind != "fn" or not it.in-verus: continue.do
        mode := fn-mode it
        attr-names := {}
        it.attrs.do: | a/Attr |
          (normalize-attr a.toks []).do: attr-names.add it[1]
        trusted := (attr-names.any: TRUSTED-ATTRS.contains it) or it.mods.contains "axiom"
        if mode == "spec" and it.mods.contains "closed":
          reports.closed-spec.add [crate, s.rel, it.line, it.name]
        if mode == "spec" and (attr-names.contains "opaque" or attr-names.contains "opaque_outside_module"):
          reports.opaque.add [crate, s.rel, it.line, it.name]
        if attr-names.contains "rlimit":
          reports.rlimit.add [crate, s.rel, it.line, it.name]
        if mode == "proof" and it.body and not trusted:
          ens := clause-tokens p it "ensures"
          trivial := ens == null or (ens.every: it.text == "true" or it.text == ",")
          if it.body[1] == it.body[0] + 1 and not trivial:
            reports.empty-proof.add [crate, s.rel, it.line, it.name]
          if (refs-all.get it.simple --if-absent=: 0) == 0 and not it.in-trait:
            thms.add [s.rel, it.line, it.name, sig.call it]
        if mode == "exec" and it.body and not trusted and not it.in-trait
            and (clause-tokens p it "ensures") != null
            and (refs-verus.get it.simple --if-absent=: 0) == 0:
          entries.add [s.rel, it.line, it.name, sig.call it]
    reports.theorems[crate] = thms
    reports.entry-points[crate] = entries
  return reports

RULE ::= "=" * 78

/** Writes the theorems file and returns whether its content changed. */
write-theorems path/string reports/Reports -> bool:
  out := []
  out.add "# Generated by verified/tools/trust_audit.toit (run verified/check.sh); do not edit."
  out.add "#"
  out.add "# What the verified crates claim, for human review."
  out.add "# Part 1: top-level theorems: proof fns inside verus! that are not referenced"
  out.add "#   anywhere else in their crate (by name; a same-named reference hides one)."
  out.add "# Part 2: verified exec entry points: exec fns inside verus! with an `ensures`"
  out.add "#   that no verified code calls; their contracts are what unverified callers"
  out.add "#   (FFI glue, reference interpreter) rely on."
  out.add "# Items marked external_body/axiom are not listed; see TRUSTED.toml. Line"
  out.add "# numbers are omitted so that the diff of this file shows only claim changes."
  out.add ""
  [["Top-level theorems", reports.theorems], ["Verified exec entry points", reports.entry-points]].do: | section |
    title := section[0]
    data/Map := section[1]
    data.do: | crate items |
      out.add RULE
      out.add "$title: crate $crate ($items.size)"
      out.add RULE
      items.do: | entry |
        out.add ""
        out.add "--- $entry[2]  ($CRATES[crate][0]/$entry[0])"
        out.add entry[3]
      out.add ""
  text := (rstrip (out.join "\n")) + "\n"
  old := file.is-file path ? (file.read-contents path).to-string-non-throwing : null
  file.write-contents text --path=path
  return old != text

// ----------------------------------------------------------------------------
// Python-compatible formatting of values in messages.

/** The value as Python's repr shows it (strings, ints, bools, lists, maps). */
py-repr value -> string:
  if value is string: return py-repr-string value
  if value is bool: return value ? "True" : "False"
  if value == null: return "None"
  if value is List: return "[$((value.map: py-repr it).join ", ")]"
  if value is Map:
    entries := []
    value.do: | k v | entries.add "$(py-repr k): $(py-repr v)"
    return "{$(entries.join ", ")}"
  return "$value"

/** The value as Python's str shows it. */
py-str value -> string:
  if value is string: return value
  return py-repr value

py-repr-string s/string -> string:
  quote := (s.contains "'") and not (s.contains "\"") ? '"' : '\''
  result := "$(string.from-rune quote)"
  s.do --runes: | c |
    if c == quote or c == '\\': result += "\\$(string.from-rune c)"
    else if c == '\t': result += "\\t"
    else if c == '\n': result += "\\n"
    else if c == '\r': result += "\\r"
    else if c < 0x20 or c == 0x7f: result += "\\x$(%02x c)"
    else if 0x80 <= c <= 0xa0 or c == 0xad: result += "\\x$(%02x c)"
    else: result += string.from-rune c
  return result + (string.from-rune quote)

/** Python's `a == b` for the scalar values of the allowlist. */
py-equals a b -> bool:
  if a is bool: a = a ? 1 : 0
  if b is bool: b = b ? 1 : 0
  if a is not num or b is not num: return identical a b or (a is string and b is string and a == b)
  return a == b

/** Python's `v is True`. */
is-true v -> bool:
  return v is bool and v

/** Python's `s.upper().startswith("TODO")` (non-ASCII never maps to these letters). */
starts-with-todo s/string -> bool:
  if s.size < 4: return false
  4.repeat: | i |
    c := s.at --raw i
    if 'a' <= c <= 'z': c -= 'a' - 'A'
    if c != "TODO"[i]: return false
  return true

/** ASCII whitespace (bytes of a UTF-8 string). */
is-space-byte b/int -> bool:
  return b < 0x80 and is-space-rune b

// ----------------------------------------------------------------------------
// Allowlist.

class Group:
  crate/string
  file/string
  item/string
  kind/string
  occs/List := []

  constructor .crate .file .item .kind:

  where -> string: return "$CRATES[crate][0]/$file:$occs[0].line"

  lines -> string: return (occs.map: "$it.line").join ", "

occurrence-groups scans/List -> Map:
  groups := {:}
  scans.do: | s/FileScan |
    s.occurrences.do: | o/Occurrence | add-to-groups groups o
  return groups

add-to-groups groups/Map o/Occurrence -> none:
  group := groups.get o.key --init=: Group o.crate o.file o.item o.kind
  group.occs.add o

sorted-keys map/Map -> List:
  keys := map.keys
  keys.sort --in-place
  return keys

load-allowlist path/string -> List:
  if not file.is-file path: return []
  data := parse-toml (file.read-contents path).to-string
  trusted := data.get "trusted"
  return trusted or []

toml-str s/string -> string:
  return "\"" + ((s.replace --all "\\" "\\\\").replace --all "\"" "\\\"") + "\""

ALLOWLIST-HEADER ::= [
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
  "# verified/check.sh (verified/tools/trust_audit.toit); unlisted occurrences,",
  "# count changes and stale entries fail the check. Regenerate the skeleton",
  "# with `verified/check.sh --update-allowlist` (keeps justifications, new",
  "# entries get TODO, which fails until replaced). This list must only shrink.",
  "#",
  "# Fields: crate, file (relative to the crate), item (qualified name),",
  "# kind (see verified/README.md), count (occurrences of that kind in that",
  "# item), justification (one line).",
  "",
]

entry-key e/Map -> string:
  return group-key (py-str e["crate"]) (py-str e["file"]) (py-str e["item"]) (py-str e["kind"])

write-allowlist path/string groups/Map old-entries/List -> none:
  old := {:}
  // The caller checked that every entry has the key fields.
  old-entries.do: | e/Map | old[entry-key e] = e
  lines := ALLOWLIST-HEADER.copy
  (sorted-keys groups).do: | key |
    group/Group := groups[key]
    e := old.get key --if-absent=: {:}
    just := e.get "justification" --if-absent=: "TODO"
    lines.add "[[trusted]]"
    lines.add "crate = $(toml-str group.crate)"
    lines.add "file = $(toml-str group.file)"
    lines.add "item = $(toml-str group.item)"
    lines.add "kind = $(toml-str group.kind)"
    lines.add "count = $group.occs.size"
    lines.add "justification = $(toml-str (py-str just))"
    lines.add ""
  file.write-contents (lines.join "\n") --path=path

check-allowlist groups/Map entries/List -> List:
  errors := []
  seen := {}
  by-key := {:}
  entries.do: | e |
    if e is not Map:
      errors.add "TRUSTED.toml: entry $(py-repr e) is not a table"
      continue.do
    missing := ["crate", "file", "item", "kind", "justification"].filter: not e.contains it
    if not missing.is-empty:
      errors.add "TRUSTED.toml: entry $(py-repr e) lacks $(missing.join ", ")"
      continue.do
    key := entry-key e
    if by-key.contains key:
      errors.add "TRUSTED.toml: duplicate entry ($(py-repr e["crate"]), $(py-repr e["file"]), $(py-repr e["item"]), $(py-repr e["kind"]))"
    by-key[key] = e
  (sorted-keys groups).do: | key |
    group/Group := groups[key]
    occs := group.occs
    where := group.where
    e := by-key.get key
    if e == null:
      detail := occs[0].detail.is-empty ? "" : " $occs[0].detail"
      errors.add "UNLISTED  $where: $group.kind in `$group.item`$detail ($(occs.size)x; lines $group.lines)"
      continue.do
    seen.add key
    if (e.contains "count") and not py-equals e["count"] occs.size:
      errors.add "COUNT     $where: $group.kind in `$group.item`: allowlist says $(py-str e["count"]), found $occs.size (lines $group.lines)"
    justification := e["justification"]
    j := justification is string ? strip justification : ""
    if j.is-empty or starts-with-todo j:
      errors.add "NOJUSTIFY $where: $group.kind in `$group.item` has no justification"
  by-key.do: | key e |
    if not seen.contains key:
      crate := py-str e["crate"]
      dir := CRATES.contains crate ? CRATES[crate][0] : crate
      errors.add "STALE     $dir/$(py-str e["file"]): $(py-str e["kind"]) in `$(py-str e["item"])` is allowlisted but no longer occurs; remove the entry"
  return errors

cargo-metadata-occurrences root/string -> List:
  out := []
  CRATES.do: | crate entry |
    path := py-join (py-join root entry[0]) "Cargo.toml"
    data := parse-toml (file.read-contents path).to-string
    package := data.get "package" --if-absent=: {:}
    metadata := package.get "metadata" --if-absent=: {:}
    meta := metadata.get "verus" --if-absent=: {:}
    meta.do: | k v |
      if k == "verify" and is-true v: continue.do
      out.add (Occurrence crate "Cargo.toml" "metadata.verus.$k" "cargo_metadata" 0 (py-repr v))
    if not is-true (meta.get "verify"):
      out.add (Occurrence crate "Cargo.toml" "metadata.verus.verify" "cargo_metadata" 0 "verify is not true")
  return out

/** Allowlisted items that the crate's trust document does not mention. */
cross-check-docs root/string groups/Map -> List:
  misses := []
  keys := sorted-keys groups
  TRUST-DOCS.do: | crate doc |
    path := py-join root doc
    if not file.is-file path: continue.do
    text := (file.read-contents path).to-string-non-throwing
    keys.do: | key |
      group/Group := groups[key]
      if group.crate != crate: continue.do
      needle := (group.item == "*" or group.item == "<crate>")
          ? fs.basename group.file
          : (group.item.split "::").last
      if text.contains group.item or contains-word text needle: continue.do
      misses.add "$doc: does not mention `$group.item` ($group.kind, $CRATES[crate][0]/$group.file)"
  return misses

/**
Parses a `-->  path:line:column` line (after optional whitespace) like the
  regular expression `\s*-->\s*(\S+?):(\d+):(\d+)`; returns [path, line] or
  null.
*/
parse-location l/string -> List?:
  i := 0
  while i < l.size and is-space-byte (l.at --raw i): i++
  if not l[i..].starts-with "-->": return null
  i += 3
  while i < l.size and is-space-byte (l.at --raw i): i++
  start := i
  // The shortest non-space path followed by :digits:digits.
  for end := start + 1; end < l.size; end++:
    c := l.at --raw end - 1
    if is-space-byte c: return null
    if (l.at --raw end) != ':': continue
    d := end + 1
    while d < l.size and is-ascii-digit (l.at --raw d): d++
    if d == end + 1 or d >= l.size or (l.at --raw d) != ':': continue
    e := d + 1
    if e >= l.size or not is-ascii-digit (l.at --raw e): continue
    return [l[start..end], int.parse l[end + 1..d]]
  return null

/** Every location Verus --no-cheating rejects must be in a flagged item. */
no-cheating-check scans/List crate/string log-path/string -> List:
  errors := []
  text := (file.read-contents log-path).to-string-non-throwing
  locs := []
  lines := text.split "\n"
  lines.size.repeat: | k |
    l/string := lines[k]
    if l.starts-with "error" and l.contains "--no-cheating":
      for m := k + 1; m < (min lines.size (k + 4)); m++:
        loc := parse-location lines[m]
        if loc:
          locs.add [py-normpath loc[0], loc[1], strip l]
          break
  by-file := {:}
  scans.do: | s/FileScan | if s.crate == crate: by-file[s.rel] = s
  locs.do: | loc |
    f/string := loc[0]
    line/int := loc[1]
    msg/string := loc[2]
    s/FileScan? := by-file.get f
    if s == null:
      errors.add "--no-cheating: $crate/$f:$line: file not scanned ($msg)"
      continue.do
    // The items covering the line, and those whose attributes precede it.
    names := {}
    s.parser.items.do: | it/Item |
      if it.line <= line <= it.end-line: names.add it.name
      if not it.attrs.is-empty:
        first := (it.attrs.map: it.line).reduce: | a b | min a b
        if first <= line < it.line: names.add it.name
    ok := s.occurrences.any: | o/Occurrence |
      (names.contains o.item) and FLAGGED-KINDS.contains o.kind
    if not ok:
      errors.add "--no-cheating: Verus rejects $CRATES[crate][0]/$f:$line but the scanner found no escape hatch there ($msg)"
  return [errors, locs.size]

// ----------------------------------------------------------------------------
// Paths as Python's os.path computes them.

py-join a/string b/string -> string:
  if b.starts-with "/": return b
  if a.is-empty or a.ends-with "/": return a + b
  return "$a/$b"

py-dirname p/string -> string:
  i := (p.index-of --last "/") + 1
  head := p[..i]
  if not head.is-empty and head != "/" * head.size:
    while head.size > 0 and head.ends-with "/": head = head[..head.size - 1]
  return head

py-normpath p/string -> string:
  if p.is-empty: return "."
  initial := p.starts-with "/" ? (p.starts-with "//" and not p.starts-with "///" ? 2 : 1) : 0
  comps := []
  (p.split "/").do: | comp |
    if comp == "" or comp == ".": continue.do
    if comp != ".." or (initial == 0 and comps.is-empty) or (not comps.is-empty and comps.last == ".."):
      comps.add comp
    else if not comps.is-empty:
      comps.remove-last
  result := ("/" * initial) + (comps.join "/")
  return result.is-empty ? "." : result

py-abspath p/string -> string:
  if not p.starts-with "/": p = py-join directory.cwd p
  return py-normpath p

py-relpath path/string start/string -> string:
  start-list := ((py-abspath start).split "/").filter: not it.is-empty
  path-list := ((py-abspath path).split "/").filter: not it.is-empty
  i := 0
  while i < start-list.size and i < path-list.size and start-list[i] == path-list[i]: i++
  rel := (List (start-list.size - i) "..") + path-list[i..]
  return rel.is-empty ? "." : rel.join "/"

/**
The .rs files under $dir in the order of Python's sorted os.walk: the
  files of a directory (sorted), then its subdirectories (sorted, without
  `target`; symbolic links to directories are listed but not entered).
*/
walk-rust-files dir/string -> List:
  result := []
  walk-rust-files_ dir result
  return result

walk-rust-files_ dir/string result/List -> none:
  if not file.is-directory dir: return
  files := []
  dirs := []
  stream := directory.DirectoryStream dir
  try:
    while name := stream.next:
      path := "$dir/$name"
      if file.is-directory path: dirs.add name
      else: files.add name
  finally:
    stream.close
  files.sort --in-place
  dirs.sort --in-place
  files.do: | name/string |
    if name.ends-with ".rs": result.add "$dir/$name"
  dirs.do: | name/string |
    if name == "target": continue.do
    path := "$dir/$name"
    if file.is-directory path --no-follow-links: walk-rust-files_ path result

// ----------------------------------------------------------------------------

main args:
  default-root := fs.dirname (fs.dirname system.program-path)
  command := cli.Command "trust_audit"
      --help="""
        Audit of the Verus escape hatches in the crates under verified/.

        Scans every Rust source of verified/core, verified/spec and
        verified/vmverify for the ways Verus lets code be trusted instead of
        proven and compares the result with the allowlist verified/TRUSTED.toml.
        Unlisted occurrences, count changes, entries without a justification
        and stale entries are failures. Writes verified/THEOREMS.txt.
        """
      --options=[
        cli.Option "root" --default=default-root
            --help="The verified/ directory.",
        cli.Option "allowlist"
            --help="The allowlist (default: ROOT/TRUSTED.toml).",
        cli.Option "theorems"
            --help="The theorems file to write (default: ROOT/THEOREMS.txt).",
        cli.Flag "update-allowlist" --default=false
            --help="Rewrite the allowlist from the scan, keeping justifications.",
        cli.Option "verus-no-cheating-log" --multi
            --help="CRATE=FILE: output of verus --no-cheating for that crate.",
      ]
      --run=:: | invocation/cli.Invocation |
        exit (audit invocation)
  command.run args

audit invocation/cli.Invocation -> int:
  root/string := invocation["root"]
  allowlist/string := invocation["allowlist"] or (py-join root "TRUSTED.toml")
  theorems-path/string := invocation["theorems"] or (py-join root "THEOREMS.txt")

  failures := []
  scans := []
  warnings := []
  CRATES.do: | crate entry |
    d/string := entry[0]
    cfgs/List := entry[1]
    cdir := py-join root d
    (walk-rust-files (py-join cdir "src")).do: | path/string |
      rel := py-relpath path cdir
      exception := catch --unwind=(: it is not LexError):
        scan := scan-file crate rel path cfgs
        scans.add scan
        scan.parser.warnings.do: | w/string |
          (w.contains "inside verus!" ? failures : warnings).add "PARSE     $d/$w"
      if exception:
        failures.add "PARSE     $d/$rel: $exception"

  groups := occurrence-groups scans
  (cargo-metadata-occurrences root).do: | o | add-to-groups groups o

  nfiles := scans.size
  nocc := 0
  groups.do --values: nocc += it.occs.size
  print "Escape-hatch audit: $nfiles files, $nocc occurrences in $groups.size (item, kind) groups."
  kinds := {:}
  groups.do --values: | group/Group |
    key := "$group.crate\0$group.kind"
    kinds[key] = (kinds.get key --if-absent=: 0) + group.occs.size
  (sorted-keys kinds).do: | key/string |
    parts := key.split "\0"
    print "  $(pad-right parts[0] 5) $(pad-right parts[1] 32) $(pad-left "$kinds[key]" 4)"

  if invocation["update-allowlist"]:
    old-entries := load-allowlist allowlist
    // Rewriting needs the key of every entry; leave a broken file alone.
    old-entries.do: | e |
      if e is not Map or (["crate", "file", "item", "kind"].any: not e.contains it):
        pipe.stderr.out.write "$allowlist: entry $(py-repr e) lacks a key field (crate, file, item, kind); fix it before --update-allowlist\n"
        return 1
    write-allowlist allowlist groups old-entries
    print "Wrote $allowlist; fill in every TODO justification."

  failures.add-all (check-allowlist groups (load-allowlist allowlist))

  invocation["verus-no-cheating-log"].do: | spec/string |
    eq := spec.index-of "="
    crate := eq < 0 ? spec : spec[..eq]
    path := eq < 0 ? "" : spec[eq + 1..]
    result := no-cheating-check scans crate path
    errs/List := result[0]
    print "Cross-check with `verus --no-cheating` ($crate): $result[1] rejected locations, $errs.size not found by the scanner."
    failures.add-all errs

  misses := cross-check-docs root groups
  reports := build-reports scans
  changed := write-theorems theorems-path reports

  section := : | title/string rows/List |
    print "\n$title ($rows.size):"
    rows.do: print "  $it"
  located := : | rows/List |
    rows.map: "$CRATES[it[0]][0]/$it[1]:$it[2] $it[3]"

  section.call "Allowlisted items not mentioned in the crate's trust document (report only)" misses
  section.call "Closed spec fns (report only)" (located.call reports.closed-spec)
  section.call "Opaque spec fns (report only)" (located.call reports.opaque)
  section.call "Proof fns with an empty body and a non-trivial ensures (report only)" (located.call reports.empty-proof)
  section.call "rlimit overrides (report only)" (located.call reports.rlimit)
  section.call "Parser warnings outside verus! (report only)" warnings
  summary := []
  reports.theorems.do: | crate thms |
    summary.add "$crate: $thms.size top-level proof fns, $reports.entry-points[crate].size exec entry points"
  print "\nTheorems: $(summary.join ", ")"
  print "Wrote $(py-relpath theorems-path (py-dirname root))$(changed ? " (CHANGED: review and commit it)" : " (unchanged)")."

  if not failures.is-empty:
    print "\nESCAPE-HATCH AUDIT FAILED ($failures.size):"
    failures.do: print "  $it"
    return 1
  print "\nEscape-hatch audit passed."
  return 0

pad-right s/string width/int -> string:
  return s.size >= width ? s : s + " " * (width - s.size)

pad-left s/string width/int -> string:
  return s.size >= width ? s : " " * (width - s.size) + s
