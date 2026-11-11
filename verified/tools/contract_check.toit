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
Checks verified/CONTRACTS.toml against both of its renderings: the
  requires/ensures clauses of each Verus external_body function (in order,
  whitespace aside) and the requires/ensures conjuncts of the VeriFast
  contract of the C++ function in its generated rendering. Reports the
  clauses one side lacks ("MISSING": known disagreements) without failing.

Usage: toit run verified/tools/contract_check.toit -- [--root DIR]
Exit status 1 on any difference between the table and a source.
*/

import cli
import fs
import host.file
import system
import .toml

normalize s/string -> string:
  out := []
  space := false
  s.size.repeat: | i |
    c := s.at --raw i
    if c == ' ' or c == '\n' or c == '\t' or c == '\r':
      space = true
    else:
      if space and not out.is-empty: out.add " "
      space = false
      out.add (string.from-rune c)
  return out.join ""

/** Splits $text at depth-0 occurrences of $sep (parens, brackets, braces and closure bars count). */
split-top text/string sep/string -> List:
  result := []
  depth := 0
  bars := false
  start := 0
  i := 0
  while i < text.size:
    c := text.at --raw i
    if c == '|' and not bars:
      before := text[..i].trim
      if before.ends-with "exists" or before.ends-with "forall" or before.ends-with "choose": bars = true
    else if c == '|' and bars:
      bars = false
    else if not bars and (c == '(' or c == '[' or c == '{'):
      depth++
    else if not bars and (c == ')' or c == ']' or c == '}'):
      depth--
    if depth == 0 and not bars and text[i..].starts-with sep:
      result.add text[start..i]
      i += sep.size
      start = i
      continue
    i++
  result.add text[start..]
  return (result.map: normalize it).filter: it != ""

/** The requires and ensures clauses of Verus function $name in $path. */
verus-clauses path/string name/string -> Map:
  text := (file.read-contents path).to-string
  at := text.index-of "fn $name("
  if at < 0: throw "no fn $name in $path"
  // The signature ends at the body's brace at depth 0.
  depth := 0
  end := -1
  for i := at; i < text.size; i++:
    c := text.at --raw i
    if c == '(' or c == '[': depth++
    if c == ')' or c == ']': depth--
    if c == '{' and depth == 0:
      end = i
      break
  // Line comments between the clauses are not part of them.
  header := ((text[at..end].split "\n").map: | line/string |
    c := line.index-of "//"
    c >= 0 ? line[..c] : line).join "\n"
  req := header.index-of "\n    requires"
  ens := header.index-of "\n    ensures"
  // `requires X,` on the signature line itself.
  if req < 0: req = header.index-of " requires "
  if ens < 0: ens = header.index-of " ensures"
  result := {"requires": [], "ensures": []}
  if req >= 0:
    stop := ens >= 0 ? ens : header.size
    from := (header.index-of "requires" req) + 8
    result["requires"] = split-top header[from..stop] ","
  if ens >= 0:
    from := (header.index-of "ensures" ens) + 7
    result["ensures"] = split-top header[from..] ","
  return result

/** The requires and ensures conjuncts of the prototype of $name in the rendering $path. */
verifast-clauses path/string name/string -> Map:
  lines := (file.read-contents path).to-string.split "\n"
  start := -1
  lines.size.repeat: | i |
    l := lines[i]
    if start < 0 and l.ends-with ");" and (l.contains " $name(" or l.contains "*$name("): start = i
  if start < 0: throw "no prototype of $name in $path"
  ghost := []
  i := start + 1
  in-block := false
  while i < lines.size:
    l := lines[i].trim
    if in-block:
      ghost.add (l.replace "@*/" "")
      if l.contains "@*/": in-block = false
    else if l.starts-with "//@":
      ghost.add l[3..]
    else if l.starts-with "/*@":
      rest := l[3..]
      if rest.contains "@*/": ghost.add (rest.replace "@*/" "")
      else:
        ghost.add rest
        in-block = true
    else:
      break
    i++
  text := normalize (ghost.join " ")
  result := {:}
  ["requires", "ensures"].do: | kind |
    k := text.index-of "$kind "
    if k < 0: throw "no $kind in the contract of $name in $path"
    e := text.index-of ";" k
    result[kind] = split-top text[k + kind.size + 1..e] "&*&"
  return result

same a/List b/List -> bool:
  if a.size != b.size: return false
  a.size.repeat: if a[it] != b[it]: return false
  return true

main args:
  command := cli.Command "contract_check"
      --help="Checks verified/CONTRACTS.toml against the Verus and the VeriFast sources."
      --options=[
        cli.Option "root" --default=(fs.dirname (fs.dirname system.program-path))
            --help="The verified/ directory.",
      ]
      --run=:: run it["root"]
  command.run args

run root/string:
  table := parse-toml (file.read-contents "$root/CONTRACTS.toml").to-string
  contracts := table["contract"]
  clauses := table["clause"]
  bridges := table["bridge"]
  failures := 0
  gaps := []
  contracts.do: | c/Map |
    name := c["name"]
    mine := clauses.filter: it["contract"] == name
    problems := []
    mine.do: | cl/Map |
      b := cl.get "bridge"
      if b and not bridges.contains b: problems.add "clause `$cl["name"]`: no bridge `$b`"
      if cl["verus"] == "MISSING" or (cl.get "verifast") == "MISSING":
        gaps.add "$name, $cl["side"] `$cl["name"]`: $(cl["verus"] == "MISSING" ? "not in the Verus contract" : "not in the VeriFast contract") ($(cl.get "verifast" --if-absent=: "") $(cl.get "note" --if-absent=: ""))"
    e1 := catch --trace:
      verus := verus-clauses "$root/$c["verus_file"]" c["verus_fn"]
      ["requires", "ensures"].do: | side |
        want := ((mine.filter: it["side"] == side and it["verus"] != "MISSING").map: normalize it["verus"])
        have := verus[side]
        if not (same want have):
          problems.add "Verus $side of $c["verus_fn"] ($c["verus_file"]):\n      table:  $(want.join " | ")\n      source: $(have.join " | ")"
    if e1: problems.add "reading the Verus source: $e1"
    if c["rendering"] != "":
      e2 := catch --trace:
        vf := verifast-clauses "$root/$c["rendering"]" c["cxx_fn"]
        ["requires", "ensures"].do: | side |
          want := []
          (mine.filter: it["side"] == side and (it.get "verifast") != "MISSING" and (it.get "verifast" --if-absent=: "") != "").do: | cl |
            want.add-all (split-top cl["verifast"] "&*&")
          have := vf[side]
          if not (same want have):
            problems.add "VeriFast $side of $c["cxx_fn"] ($c["rendering"]):\n      table:  $(want.join " &*& ")\n      source: $(have.join " &*& ")"
      if e2: problems.add "reading the rendering: $e2"
    if problems.is-empty:
      print "ok    contract $name: $c["status"]"
    else:
      failures++
      print "FAIL  contract $name:"
      problems.do: print "    $it"
  gaps.do: print "gap   $it"
  exit (failures == 0 ? 0 : 1)
