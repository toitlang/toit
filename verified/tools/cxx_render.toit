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
Mechanical C rendering of VM C++ functions for VeriFast.

VeriFast's C++ front end rejects every pointer cast, so the residual C++ is
  verified on a C rendering. This tool makes that rendering from the real
  sources, so it cannot drift: for each function a sidecar (`*.render`)
  names, it reads Clang's JSON AST of the function (clang-ast.sh), prints
  it as C by the fixed rules below, and weaves in the hand-written VeriFast
  annotations the sidecar holds. The sidecar holds, for every rendered
  function, a copy of its C++ text with the annotations (`//@ ...`,
  block comments opening with an at sign) inserted between statements: the copy is compared token by
  token (comments and whitespace aside) with the function in the current
  sources, and any difference fails (drift). The annotations are anchored
  at the token that follows them.

Rendering rules (see verified/cxx/annotated/README.md, "The rendering"):
* `T C::m(args)` is `T C_m(C *self, args)`; a static member `C_m(args)`;
  a constructor `C_ctor(C *self, args)`, a destructor `C_dtor(C *self)`.
  A member listed with `@overloaded` gets the argument count appended.
* `this` is `self`; a field `f` of `this` is `self->f`; a call of member
  `m` on an object of static class C is `C_m(object, ...)`.
* A qualified name `C::N` is `C_N`; an unqualified constant `N` inside
  class C is `C_N` when the constant table has it, else `N`. Every constant
  must be in the constant table; its value is checked against the C++ at
  the place of use (static_assert, 64- and 32-bit, `--check-constants`).
* Implicit conversions are written out as casts, except lvalue-to-rvalue,
  no-op, decay and derived-to-base ones (all classes are one struct in the
  model) and an integer literal's conversion (the value is unchanged).
  Integer to bool is `!= 0`; nullptr is 0.
* Braces around every branch and loop body. `return e;` followed by
  annotations (or leaving the scope of a local with a destructor) is
  `{ T result = e; <annotations>; <destructors>; return result; }`.
* A local of a class listed with `@raii` gets its destructor call at
  every exit from its scope.
* The release `ASSERT(c)` (`while (false && (c)) {}`) is a comment: its
  condition is never evaluated.
* The closure rules: a lambda is a struct of its captures and a function
  of it, a function template instance taking it (rendered with the
  option `lambda=ENCLOSING[#K]`) one C function per instance (see `Closure`, with
  the checks that make a copy of a captured value what the reference is).
Anything else in the AST (an expression or statement kind not listed, a
  cast of an unknown kind) is an error: the tool never guesses.

Usage:
  toit run verified/tools/cxx_render.toit -- [--check] [--target T]... SIDECAR...
With --check the generated files must equal the committed ones; without,
  they are (re)written. Exit status 1 on drift, on an unsupported construct
  or on a mismatching generated file.
*/

import cli
import encoding.json
import fs
import host.directory
import host.file
import host.pipe
import system

// ---------------------------------------------------------------------------
// Tokens.

class Token:
  text/string
  offset/int
  ghost/bool
  constructor .text .offset --.ghost=false:

PUNCT3 ::= {"<<=", ">>=", "...", "->*"}
PUNCT2 ::= {"::", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&",
            "||", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", ".*", "##"}

is-ident-start c/int -> bool:
  return ('a' <= c and c <= 'z') or ('A' <= c and c <= 'Z') or c == '_'

is-digit c/int -> bool:
  return '0' <= c and c <= '9'

is-ident-char c/int -> bool:
  return (is-ident-start c) or (is-digit c)

/**
Tokenizes C++ text. Comments and whitespace are dropped, except ghost
  comments (line or block comments that start with an at sign) when $keep-ghosts.
*/
tokenize text/string --keep-ghosts/bool=false -> List:
  result := []
  n := text.size
  i := 0
  while i < n:
    c := text.at --raw i
    if c == ' ' or c == '\t' or c == '\n' or c == '\r':
      i++
      continue
    if c == '/' and i + 1 < n and (text.at --raw i + 1) == '/':
      end := text.index-of "\n" i
      if end < 0: end = n
      if keep-ghosts and i + 2 < n and (text.at --raw i + 2) == '@':
        result.add (Token text[i..end] i --ghost)
      i = end
      continue
    if c == '/' and i + 1 < n and (text.at --raw i + 1) == '*':
      end := text.index-of "*/" (i + 2)
      if end < 0: throw "unterminated comment at offset $i"
      end += 2
      if keep-ghosts and i + 2 < n and (text.at --raw i + 2) == '@':
        result.add (Token text[i..end] i --ghost)
      i = end
      continue
    start := i
    if is-ident-start c:
      while i < n and (is-ident-char (text.at --raw i)): i++
    else if (is-digit c) or (c == '.' and i + 1 < n and (is-digit (text.at --raw i + 1))):
      i++
      while i < n:
        d := text.at --raw i
        if (is-ident-char d) or d == '.':
          i++
        else if (d == '+' or d == '-') and ((text.at --raw i - 1) == 'e' or (text.at --raw i - 1) == 'E'):
          i++
        else:
          break
    else if c == '"' or c == '\'':
      i++
      while i < n and (text.at --raw i) != c:
        if (text.at --raw i) == '\\': i++
        i++
      i++
    else if i + 3 <= n and PUNCT3.contains text[i..i + 3]:
      i += 3
    else if i + 2 <= n and PUNCT2.contains text[i..i + 2]:
      i += 2
    else:
      i++
    result.add (Token text[start..i] start)
  return result

line-of text/string offset/int -> int:
  line := 1
  for i := 0; i < offset and i < text.size; i++:
    if (text.at --raw i) == '\n': line++
  return line

// ---------------------------------------------------------------------------
// Errors.

class RenderError:
  message/string
  constructor .message:
  stringify -> string: return message

fail message/string:
  throw (RenderError message)

// ---------------------------------------------------------------------------
// The sidecar.

class Section:
  kind/string        // "verbatim", "render" or "prototypes".
  args/List          // The directive's words after the kind.
  text/string        // The lines up to the next directive.
  line/int           // Line of the directive in the sidecar.
  constructor .kind .args .text .line:

/**
A sidecar: a sequence of sections, each opened by a directive line (a
  line that starts with `@`):
* `@verbatim`: C and VeriFast text, copied (to the header when there is
  one). `@verbatim-c`: copied to the C file only.
* `@prototypes`: the prototypes, with their contracts, of every function
  the sidecar renders (to the header when there is one).
* `@render FILE QUALIFIED-NAME [tu=FILE] [params=N] [type=T] [trusted] [truncating] [unsigned-word-conversion]`:
  the section holds the annotated copy of the function. `trusted`: only
  the prototype and contract are emitted (the body is not verified, but
  still compared with the sources). `type=T` picks an overload by its
  Clang type with the spaces removed. `truncating`: the implicit
  conversions of a word or a uword to int and of a uword to word are VeriFast's
  truncating casts (the modular conversions GCC and Clang define and
  C++20 standardizes), for code that checks the result; so is an
  explicit static_cast narrowing a signed integer (os_localtime's
  `static_cast<time_t>`). Explicit casts between int64 and uint64 and a
  uint64 left shift by a literal in [0, 63] (also `<<=` on a plain
  variable) also use modular arithmetic, and so does a uint64 left shift
  of an explicitly converted value by a run-time count (VeriFast checks
  the count; Utils::wrapping_shift_left). An explicit uint8-to-int8
  conversion and a conversion (implicit or explicit) of an int64 to a byte are
  modular; an int64 `>>=` by a literal on a plain variable is the
  arithmetic shift (GCC's and Clang's, C++20's), written without a shift
  of a negative value. An annotated operand of a cast, a shift or an
  additive operator is parenthesized (VeriFast's parser).
  A plain uword variable’s `+=` uses the same modular sum as `+`.
  `unsigned-word-conversion` renders an implicit conversion from
  `word` to `uword` modulo the target word size, and one from `int` to
  `unsigned int` modulo 2^32.
  A statement-level `static_assert` is checked again using the rendered types.
  A discarded relaxed fetch_add on std::atomic<uint64> with a uword charge
  maps to the modeled atomic operation.
  A `do S while (false)` (a macro's wrapper) is S
  as a block (no break or continue may leave it); an object of a struct
  spelled with its tag (`struct tm`) is constructed by `tm_ctor`.
Configuration: `@raii CLASS`, `@overloaded CLASS::NAME`,
  `@modular-arguments CLASS::CLASS` (the implicit integral conversions of
  the constructor's arguments to an unsigned parameter are the modular
  ones C++ defines: VeriFast's truncating cast), `@nested-type NAME
  OUTER::NAME` (a class spelled NAME in a sibling nested class, as Clang's
  AST gives it, is the C struct OUTER_NAME), `@expand-typedef NAME`
  (the typedef is written as the type it stands for on the rendering's
  target, e.g. `uhalf_word`), `@constants FILE`
  (the constant table), `@header FILE` (also write a header), `@include
  FILE` (read the configuration directives of another file).
*/
class Sidecar:
  path/string
  sections/List := []
  raii/Set := {}
  overloaded/Set := {}
  static-members/Set := {}
  modular/Set := {}
  nested-types/Map := {:}
  expanded/Set := {}
  constants-path/string? := null
  header/string? := null

  constructor .path:
    lines := (file.read-contents path).to-string.split "\n"
    kind := "verbatim"
    args := []
    start := 1
    body := []
    flush := :
      sections.add (Section kind args ((body.join "\n") + "\n") start)
      body = []
    lines.size.repeat: | index |
      line := lines[index]
      if is-directive line:
        words := (line[1..].split " ").filter: it != ""
        directive := words[0]
        if directive == "verbatim" or directive == "verbatim-c" or directive == "render" or directive == "prototypes":
          flush.call
          kind = directive
          args = words[1..]
          start = index + 1
        else if not (configure directive words (fs.dirname path)):
          fail "$path:$(index + 1): unknown directive @$directive"
      else:
        body.add line
    flush.call

  configure directive/string words/List dir/string -> bool:
    if directive == "raii":
      raii.add words[1]
    else if directive == "expand-typedef":
      expanded.add words[1]
    else if directive == "static-member":
      static-members.add words[1]
    else if directive == "overloaded":
      overloaded.add words[1]
    else if directive == "modular-arguments":
      modular.add words[1]
    else if directive == "nested-type":
      if words.size != 3 or (words[1].contains ":") or not (words[2].ends-with "::$words[1]"):
        fail "@nested-type NAME OUTER::NAME, not $(words[1..].join " ")"
      nested-types[words[1]] = words[2].replace --all "::" "_"
    else if directive == "constants":
      constants-path = "$dir/$words[1]"
    else if directive == "header":
      header = words[1]
    else if directive == "include":
      included := "$dir/$words[1]"
      ((file.read-contents included).to-string.split "\n").do: | line/string |
        if is-directive line:
          ws := (line[1..].split " ").filter: it != ""
          if not (configure ws[0] ws (fs.dirname included)):
            fail "$included: @$ws[0] not allowed in an included file"
    else:
      return false
    return true

// A directive line: an at sign and a letter (a line with the at-sign-star-slash closes an annotation).
is-directive line/string -> bool:
  return line.size > 1 and (line.at --raw 0) == '@' and (is-ident-start (line.at --raw 1))

// ---------------------------------------------------------------------------
// The constant table:`#define NAME VALUE` lines of a C header, VALUE
// valid both in C and in C++ (inside namespace toit).

class Constants:
  values/Map := {:}   // Rendered name -> value text.

  constructor path/string?:
    if path:
      ((file.read-contents path).to-string.split "\n").do: | line/string |
        line = line.trim
        if line.starts-with "#define ":
          rest := line[8..]
          comment := rest.index-of "//"
          if comment >= 0: rest = rest[..comment]
          rest = rest.trim
          space := rest.index-of " "
          if space > 0:
            values[rest[..space]] = rest[space + 1..].trim

class ConstantUse:
  cls/string?      // The class whose member function uses it, or null.
  spelling/string  // As written in the C++.
  rendered/string
  is-enum/bool
  constructor .cls .spelling .rendered .is-enum:
  key -> string: return "$cls|$spelling"

// ---------------------------------------------------------------------------
// Clang's AST.

/**
The ASTs of the translation units, one Clang run per unit and target: the
  declarations of namespace toit, as Clang prints them one after the other
  (a class with its members). Only the pieces a lookup needs are parsed.
*/
class AstCache:
  repo/string
  annotated-dir/string
  scratch/string
  signatures/Map
  units_ := {:}    // "tu|target" -> List of [top-level name, text].
  parsed_ := {:}   // "tu|target|index" -> Map.

  ast-ready/bool

  constructor .repo .annotated-dir .scratch .signatures --.ast-ready=false:

  pieces_ tu/string target/string? filter/string -> List:
    key := "$tu|$target|$filter"
    return units_.get key --init=:
      out := "$scratch/ast-$(fs.basename tu)-$(target or "host")-$((filter.replace --all "::" "").replace --all "/" "_").json"
      args := ["bash", "$annotated-dir/clang-ast.sh", "--repo", repo]
      if target: args += ["--target", target]
      args += [tu, filter, out]
      // With --ast-ready, prefetch-ast.sh has made the dumps (in parallel).
      if not (ast-ready and file.is-file out and file.is-file "$(out).index"):
        status := pipe.run-program args
        if status != 0: fail "clang-ast.sh failed ($status) for $tu"
      texts_[key] = file.read-contents out
      // clang-ast.sh's index: name, first byte, end byte of each top-level
      // declaration.
      result := []
      ((file.read-contents "$(out).index").to-string.split "\n").do: | line/string |
        words := line.split " "
        if words.size == 2 and words[0].starts-with "@":
          (owners_.get key --init=: {:})[words[0][1..]] = words[1]
        else if words.size == 3:
          result.add [words[0], int.parse words[1], int.parse words[2]]
      result

  texts_ := {:}
  owners_ := {:}  // "tu|target|filter" -> (declaration id -> top-level name).

  // The top-level declaration (the class) each member id of the unit belongs to.
  owners tu/string target/string? qname/string -> Map:
    filter := (qname.starts-with "toit::") ? "toit::" : qname
    pieces_ tu target filter
    return owners_.get "$tu|$target|$filter" --if-absent=: {:}

  parse_ tu/string target/string? filter/string index/int -> Map:
    key := "$tu|$target|$filter|$index"
    return parsed_.get key --init=:
      piece := (pieces_ tu target filter)[index]
      decl := json.decode (texts_["$tu|$target|$filter"] as ByteArray)[piece[1]..piece[2]]
      collect-typedefs decl signatures
      decl

  /**
  The declarations of $qname (`toit::A::m`, `toit::f`) in $tu: members found
    in their class, and out-of-line definitions (returned with
    `out-of-line` set; the caller checks their spelling).
  */
  find tu/string target/string? qname/string -> List:
    path := qname.split "::"
    if path[0] == "toit": path = path[1..]
    name := path.last
    result := []
    filter := (qname.starts-with "toit::") ? "toit::" : qname
    pieces := pieces_ tu target filter
    // Read direct members individually when the index lists them. Decoding the
    // enclosing class can exhaust the JSON decoder's stack on an unrelated
    // initializer. Keep out-of-line definitions in the same candidate list.
    member := path.size == 2 and path.first != name ? (path.join "::") : null
    indexed := member and (pieces.any: it[0] == member)
    pieces.size.repeat: | i |
      top := pieces[i][0]
      if indexed and top == member:
        result.add (parse_ tu target filter i)
        continue.repeat
      if indexed and top == path.first: continue.repeat
      if path.size == 1 and top == name:
        result.add (parse_ tu target filter i)
      else if path.size > 1 and top == path[0] and top == name and (parse_ tu target filter i)["kind"] != "CXXRecordDecl":
        // An out-of-line constructor (`C::C`): named like its class.
        decl := parse_ tu target filter i
        decl["out-of-line"] = true
        result.add decl
      else if path.size > 1 and top == path[0]:
        node := parse_ tu target filter i
        level := [node]
        path[1..].do: | component |
          next := []
          level.do: | n/Map |
            (inner n).do: | k |
              if k is Map and (k.get "name") == component: next.add k
          level = next
        result.add-all level
      else if path.size > 1 and top == name:
        decl := parse_ tu target filter i
        decl["out-of-line"] = true
        result.add decl
    // An out-of-line definition does not repeat `static`: take it from the
    // declaration in the class (same AST, so the same ids).
    result.do: | d/Map |
      if (d.get "out-of-line") == true and d.contains "previousDecl":
        result.do: | other/Map |
          if other["id"] == d["previousDecl"] and other.contains "storageClass":
            d["storageClass"] = other["storageClass"]
    return result

/**
Records every typedef Clang resolved (`qualType` -> `desugaredQualType`)
  in $table under "typedef:NAME", so that the parameter types of function
  types, which Clang does not desugar, can be compared canonically.
*/
collect-typedefs node table/Map -> none:
  if node is Map:
    t := node.get "type"
    if t is Map and t.contains "desugaredQualType" and not (t["qualType"].contains "<") and not (t["qualType"].contains "&"):
      table["typedef:$(c-type t["qualType"])"] = c-type t["desugaredQualType"]
    node.do --values: collect-typedefs it table
  else if node is List:
    node.do: collect-typedefs it table

begin-offset node/Map -> int?:
  range := node.get "range"
  if not range: return null
  return loc-offset range["begin"]

end-offset node/Map -> int?:
  range := node.get "range"
  if not range: return null
  return loc-offset range["end"]

loc-offset loc/Map -> int?:
  if loc.contains "expansionLoc": return loc["expansionLoc"].get "offset"
  return loc.get "offset"

end-token-length node/Map -> int:
  end := node["range"]["end"]
  if end.contains "expansionLoc": return end["expansionLoc"].get "tokLen" --if-absent=: 0
  return end.get "tokLen" --if-absent=: 0

is-macro-range node/Map -> bool:
  range := node.get "range"
  if not range: return true
  return range["begin"].contains "spellingLoc" or range["end"].contains "spellingLoc"

inner node/Map -> List:
  return node.get "inner" --if-absent=: []

is-empty node -> bool:
  return node is Map and not (node as Map).contains "kind"

// ---------------------------------------------------------------------------
// Closures (the closure rules; README, "The rendering").
//
// A lambda `[&]() -> R { body }` of a rendered function is rendered as a
// struct of its captures (`struct F_lambdaK`, F the C name of the enclosing
// function, K its position in it) and a function `R F_lambdaK_call(struct
// F_lambdaK *closure)` whose body is the lambda's, a captured variable `v`
// being `closure->v`. Where the lambda is created, a local of the struct
// (declared at the start of the block, its address is taken) gets the
// captured values (`closureK.v = v;`, just before the statement) and the
// lambda expression is `&closureK`. A function template instantiated with
// the closure type (`v2_allocate<F>`, rendered with `lambda=ENCLOSING[#K]`)
// is one C function per instance, `name__F_lambdaK`, its closure parameter
// a pointer to the caller's struct, and a call `f()` of it is
// `F_lambdaK_call(f)`.
//
// A capture by reference is rendered as a copy of the value. That is the
// same only because the translator checks that nothing can tell them
// apart: the lambda only reads its captures (every use is an
// lvalue-to-rvalue conversion), takes no parameters and is not `mutable`;
// it is created as an argument of a call (only temporaries and the move
// into the parameter in between), so it does not outlive the call; the
// captured variables are locals or parameters of the enclosing function
// whose address is never taken and that are not references, and the
// statement that creates the lambda does not assign them (outside the
// lambda), so no code can change them while the closure lives; the
// template instance only calls its closure parameter (no copy escapes).
// Anything else is an error.

// Clang's spelling of a closure type -> the C name of its struct.
LAMBDA-NAMES ::= {:}

class Closure:
  name/string          // The struct; the function is `$(name)_call`.
  spelling/string      // `(lambda at FILE:LINE:COL)`.
  node/Map             // The LambdaExpr.
  body/Map             // Its body (a CompoundStmt).
  captures/List        // [name, C type] in the order of the struct's fields.
  local/string         // The enclosing function's local of the struct.
  result-type/string
  ghosts/List := []    // The annotations inside the lambda (its contract at the body's `{`).
  constructor .name .spelling .node .body .captures .local .result-type:

// The lambdas of a function body, in source order: [LambdaExpr, the
// statement it is created in]. That statement must be a declaration, a
// return or an expression statement of a block (the closure is
// initialized just before it); a lambda in a condition, a loop header or
// a branch without braces, or inside a lambda, is an error.
collect-lambdas node out/List --statement/Map?=null --parent-kind/string="" --in-lambda/bool=false -> none:
  if node is List:
    (node as List).do: collect-lambdas it out --statement=statement --parent-kind=parent-kind --in-lambda=in-lambda
    return
  if node is not Map: return
  m := node as Map
  kind := m.get "kind"
  if not kind: return
  if kind == "LambdaExpr":
    if in-lambda: fail "a lambda inside a lambda is not supported$(line-of-node m)"
    if not statement: fail "a lambda outside a declaration, return or expression statement of a block$(line-of-node m)"
    out.add [m, statement]
    collect-lambdas (inner m) out --statement=statement --parent-kind=kind --in-lambda
    return
  if in-lambda:
    collect-lambdas (inner m) out --statement=statement --parent-kind=kind --in-lambda
    return
  if parent-kind == "CompoundStmt" and (kind == "DeclStmt" or kind == "ReturnStmt" or kind == "ExprWithCleanups" or kind.ends-with "Expr" or kind.ends-with "Operator"):
    statement = m
  else if kind.ends-with "Stmt":
    statement = null
  collect-lambdas (inner m) out --statement=statement --parent-kind=kind

// The 1-based line and column of a byte offset (Clang's columns count bytes).
line-col source/string offset/int -> string:
  line := 1
  col := 1
  for i := 0; i < offset; i++:
    if (source.at --raw i) == '\n':
      line++
      col = 1
    else:
      col++
  return "$line:$col"

// The trailing return type of a lambda's call operator, `auto () const -> R`.
lambda-result-type method-type/string -> string:
  arrow := method-type.index-of "->"
  if arrow < 0: fail "a lambda without a trailing return type (write `[&]() -> T { ... }`)"
  if not method-type[..arrow].contains "const": fail "a mutable lambda is not supported"
  return c-type method-type[arrow + 2..].trim

// Checks the uses of the variables $ids in $node (outside lambdas when
// $skip-lambdas): each must be a read (the operand of an lvalue-to-rvalue
// conversion) or, with $writes, the target of an assignment, compound
// assignment, increment or decrement. So the address of such a variable
// is never taken and no reference is bound to it. $what names the place
// for the error.
check-uses node ids/Set parent/Map? what/string --writes/bool=false --skip-lambdas/bool=false -> none:
  if node is List:
    (node as List).do: check-uses it ids parent what --writes=writes --skip-lambdas=skip-lambdas
    return
  if node is not Map: return
  m := node as Map
  if skip-lambdas and (m.get "kind") == "LambdaExpr": return
  if (m.get "kind") == "DeclRefExpr" and (ids.contains m["referencedDecl"]["id"]):
    ok := parent and parent["kind"] == "ImplicitCastExpr" and parent["castKind"] == "LValueToRValue"
    if writes and parent and (inner parent).size > 0 and (inner parent)[0] == m:
      pk := parent["kind"]
      if pk == "CompoundAssignOperator" or (pk == "BinaryOperator" and parent["opcode"] == "="): ok = true
      if pk == "UnaryOperator" and (parent["opcode"] == "++" or parent["opcode"] == "--"): ok = true
    if not ok:
      fail "closure rules: $what uses the captured $m["referencedDecl"]["name"] other than by $(writes ? "reading or assigning" : "reading") it$(line-of-node m)"
  (inner m).do: check-uses it ids m what --writes=writes --skip-lambdas=skip-lambdas

// ` (line N)` when Clang's JSON gives the node's line (it omits a line
// that equals the previous location's).
line-of-node m/Map -> string:
  loc := m.get "loc"
  if loc is Map and loc.contains "line": return " (line $loc["line"])"
  return ""

// Checks that every use of the parameter $id in $node is the object of a
// call of its call operator (`f()`), so the closure does not escape.
only-called node id/string parent/Map? grand/Map? -> none:
  if node is List:
    (node as List).do: only-called it id parent grand
    return
  if node is not Map: return
  m := node as Map
  if (m.get "kind") == "DeclRefExpr" and m["referencedDecl"]["id"] == id:
    ok := parent and parent["kind"] == "ImplicitCastExpr" and parent["castKind"] == "NoOp"
        and grand and grand["kind"] == "CXXOperatorCallExpr" and (inner grand).size == 2 and (inner grand)[1] == parent
    if not ok: fail "the closure parameter $m["referencedDecl"]["name"] is used other than called"
  (inner m).do: only-called it id m parent

// ---------------------------------------------------------------------------
// Types.

/**
Normalizes a C++ type spelling to C: drops `toit::`, `const`, `volatile`,
  `class`/`struct` keywords stay, references are rejected.
*/
// The nested classes a sidecar names with `@nested-type NAME OUTER::NAME`
// (the sidecar being rendered): a type spelled NAME is OUTER_NAME.
NESTED-TYPES/Map := {:}

c-type t/string -> string:
  // A lambda's closure type (Clang: `(lambda at FILE:LINE:COL)`) is a
  // pointer to its closure struct (the closure rules, `Closure`).
  lambda-at := t.index-of "(lambda at "
  if lambda-at >= 0:
    close := t.index-of ")" lambda-at
    spelling := t[lambda-at..close + 1]
    name := LAMBDA-NAMES.get spelling
    if not name: fail "the closure type $spelling is not a lambda of a function this unit renders (@render ... lambda=ENCLOSING)"
    rest := (t[..lambda-at] + t[close + 1..]).replace --all "const" ""
    if rest.trim != "": fail "closure type $t not supported (only the closure itself, by value)"
    return "struct $name *"
  t = t.replace --all "toit::" ""
  // Clang 20 names the type of sizeof `__size_t` (a builtin alias).
  if t == "__size_t": t = "size_t"
  // A nested class `A::B` is the C struct `A_B`.
  t = t.replace --all "::" "_"
  // A const reference is passed by value (the rendering rule for
  // parameters such as bit_cast's `const From&`); another reference is a
  // pointer (`T&` is `T *`; the argument is passed by address, a use of
  // the parameter is `(*p)`: see `is-reference`). Rvalue references are
  // not supported.
  if t.contains "&":
    if t.contains "&&" or not t.ends-with "&": fail "reference type not supported: $t"
    if t.starts-with "const ": t = t[..t.size - 1]
    else: t = t[..t.size - 1] + "*"
  words := []
  current := ""
  t.size.repeat: | i |
    c := t.at --raw i
    if c == '*' or c == ' ' or c == '(' or c == ')' or c == ',' or c == '[' or c == ']':
      if current != "": words.add current
      current = ""
      if c != ' ': words.add (string.from-rune c)
    else:
      current += string.from-rune c
  if current != "": words.add current
  words = words.filter: it != "const" and it != "volatile"
  if not NESTED-TYPES.is-empty: words = words.map: NESTED-TYPES.get it --if-absent=: it
  result := ""
  words.do: | w |
    if w == "*":
      result = result.ends-with "*" ? "$result*" : "$result *"
    else if result == "" or result.ends-with "(":
      result += w
    else:
      result += " $w"
  result = result.replace --all "_Bool" "bool"
  return result.trim

/** Whether a C++ type is a reference rendered as a pointer (not a const one). */
is-reference t/string -> bool:
  return t.ends-with "&" and not t.starts-with "const " and not t.contains "&&"

/** The class of a pointer-to-class type, e.g. `const toit::Array *` -> `Array`. */
class-of-pointer t/string -> string:
  c := c-type t
  if not c.ends-with "*": fail "not a pointer to a class: $t"
  return c[..c.size - 1].trim

// The return type of a function type spelling `R (P...) const`.
return-type fn-type/string -> string:
  depth := 0
  fn-type.size.repeat: | i |
    c := fn-type.at --raw i
    if c == '(' and depth == 0: return c-type fn-type[..i]
    if c == '<': depth++
    if c == '>': depth--
  fail "not a function type: $fn-type"
  unreachable

// ---------------------------------------------------------------------------
// The renderer.

PREC-PRIMARY ::= 16
PREC-UNARY ::= 15
PREC-COND ::= 3
PREC-ASSIGN ::= 2

BINARY-PREC ::= {
  "*": 13, "/": 13, "%": 13, "+": 12, "-": 12, "<<": 11, ">>": 11,
  "<": 10, "<=": 10, ">": 10, ">=": 10, "==": 9, "!=": 9, "&": 8, "^": 7,
  "|": 6, "&&": 5, "||": 4, "=": 2, "+=": 2, "-=": 2, "*=": 2, "/=": 2,
  "%=": 2, "&=": 2, "|=": 2, "^=": 2, "<<=": 2, ">>=": 2, ",": 1,
}

ELIDED-CASTS ::= {"LValueToRValue", "NoOp", "FunctionToPointerDecay",
                  "ArrayToPointerDecay", "DerivedToBase",
                  "UncheckedDerivedToBase", "BaseToDerived"}
// The source types of a `truncating` word-to-int conversion (typedefs resolved).
TRUNCATED ::= {"long", "int", "word", "intptr_t", "long long"}
// The source types (typedefs resolved) and target types (as written) of a
// `truncating` unsigned-to-signed conversion.
UNSIGNED-WORDS ::= {"uword", "unsigned long", "unsigned int", "uintptr_t", "uint64", "unsigned long long"}
SIGNED-TARGETS ::= {"word", "int64"}
// The target types (typedefs resolved) of a `truncating` explicit signed
// narrowing.
SIGNED-INTEGERS ::= {"short", "int", "long", "long long", "word", "intptr_t", "int64"}
WRITTEN-CASTS ::= {"IntegralCast", "IntegralToPointer", "PointerToIntegral",
                   "BitCast", "IntegralToFloating", "FloatingToIntegral",
                   "FloatingCast", "ToVoid"}

class Ghost:
  anchor/int
  text/string
  emitted := false
  constructor .anchor .text:

class Expr:
  text/string
  prec/int
  constructor .text .prec:

class Renderer:
  sidecar/Sidecar
  constants/Constants
  source/string       // The text of the file the function is in.
  source-path/string
  cls/string?         // The class of the function (`A_B` for a nested class A::B), or null.
  cxx-cls/string? := null  // Its C++ name (`A::B`).
  class-decl/Lambda? := null  // Qualified class name -> its declaration in the AST, or null.
  truncating/bool := false  // `@render ... truncating`: word-to-int conversions are modular.
  unsigned-word-conversion/bool := false
  decls-of/Lambda? := null  // Qualified name -> its declarations (in the class and out of line).
  ghosts/List
  uses/Map            // key -> ConstantUse, shared by the unit.
  signatures/Map      // C name -> parameter types, shared by all units.
  lines := []
  locals := {}
  local-names := {:}  // VarDecl id -> its C name (local-name).
  name-scopes := []   // The C names of the locals of each enclosing block.
  param-names := {}
  reference-params := {}  // Parameters of a reference type (pointers in C).
  hoisted := {}  // The ids of the locals declared at the start of their block.
  // A stack of scopes, each a list of [class, name] of locals with a
  // destructor.
  raii-scopes := []
  result-type/string := "void"
  temp-count := 0
  // The closure rules: in a lambda's function, captured name -> its
  // rendering (`closure->v`); in the enclosing function, its closures and
  // where each is created.
  captures := {:}
  closures := []
  lambda-locals := {:}  // LambdaExpr id -> the local of its closure struct.
  lambda-at := {:}      // Statement id -> the closures created in it.

  owners/Map         // Declaration id -> its top-level declaration (class).

  constructor .sidecar .constants .source .source-path .cls .ghosts .uses .signatures .owners:

  where node/Map -> string:
    offset := begin-offset node
    if offset: return "$source-path:$(line-of source offset)"
    return source-path

  emit indent/int text/string:
    lines.add ("  " * indent) + text

  // Emits the ghosts anchored at or before $offset.
  ghosts-up-to offset/int indent/int:
    ghosts.do: | g/Ghost |
      if not g.emitted and g.anchor <= offset:
        g.emitted = true
        first := true
        (g.text.split "\n").do: | l/string |
          if first: emit indent l
          else: lines.add l
          first = false

  has-ghosts-up-to offset/int -> bool:
    ghosts.do: | g/Ghost |
      if not g.emitted and g.anchor <= offset: return true
    return false

  spelling node/Map -> string?:
    if is-macro-range node: return null
    b := begin-offset node
    e := end-offset node
    if not b or not e: return null
    return source[b..e + (end-token-length node)]

  // The ABI check for Method requires a trivially copyable pointer-sized value.
  is-method-copy node/Map -> bool:
    if node["kind"] != "CXXConstructExpr" or node["type"]["qualType"] != "Method": return false
    ctor := node["ctorType"]["qualType"]
    return (inner node).size == 1 and node["constructionKind"] == "complete"
        and (ctor == "void (const Method &) noexcept" or ctor == "void (Method &&) noexcept")

  // --- Names.

  // $param-types: the C types of the parameters. An overloaded member gets
  // them in its name (`C_m__T1_T2`, `*` as `p`), so that two overloads are
  // never one C function, except const overloads (same parameters).
  mangle-member class-name/string name/string param-types/List -> string:
    // Clang names the instantiated list base for an inherited FIFO method.
    if class-name == "List<uint8>": class-name = "BytecodeList"
    if class-name == "LinkedList<Process , 2>": class-name = "LinkedList_SchedulerProcess"
    if class-name == "LinkedList<FinalizerNode>": class-name = "LinkedList_FinalizerNode"
    if class-name == "Program_Table<Object * >": class-name = "Program_ObjectTable"
    base/string := ?
    if name.starts-with "~": base = "$(class-name)_dtor"
    else if name == class-name or class-name.ends-with "_$name": base = "$(class-name)_ctor"
    else: base = "$(class-name)_$name"
    if sidecar.overloaded.contains "$class-name::$name":
      suffix := (param-types.map: (it.replace --all " " "").replace --all "*" "p").join "_"
      return "$(base)__$suffix"
    return base

  // Records that C function $c-name is called (or defined) with parameters
  // of these C++ types: one C name must always be one C++ function.
  note-signature c-name/string param-types/List node/Map:
    sig := (param-types.map: resolve it).join ", "
    old := signatures.get c-name
    if old == null:
      signatures[c-name] = sig
    else if old != sig:
      fail "$(where node): $c-name is used with parameters ($sig) and ($old): an overload; add @overloaded"

  // The canonical spelling of a type (typedefs resolved), for comparing
  // signatures: C++ overloads by canonical types.
  canonical t/Map -> string:
    return t.get "desugaredQualType" --if-absent=: t["qualType"]

  // A C type with the typedefs Clang resolved elsewhere replaced.
  resolve c/string -> string:
    stars := ""
    while c.ends-with "*":
      stars += "*"
      c = c[..c.size - 1].trim
    c = signatures.get "typedef:$c" --if-absent=: c
    return stars == "" ? c : "$c $stars"

  // The type of an expression as written, unless that is a template
  // expression (e.g. `enable_if<...>::type`): then the desugared one.
  expr-type node/Map -> string:
    t := node["type"]
    q := t["qualType"]
    if q.contains "<" and t.contains "desugaredQualType": return t["desugaredQualType"]
    return q

  // The parameter types of a call, from its arguments (after the implicit
  // conversions Clang inserts, an argument has its parameter's type).
  arg-types args/List -> List:
    return args.map: | a/Map |
      a.contains "type" ? (c-type (expr-type a)) : "?"

  // The parameter types of a function type spelling `R (P1, P2) const`.
  fn-param-types fn-type/string -> List:
    return (fn-param-types-raw fn-type).map: c-type it

  fn-param-types-raw fn-type/string -> List:
    // The parameter list is the last parenthesized group (the return type
    // can contain parentheses, e.g. an enable_if condition).
    close := fn-type.index-of --last ")"
    open := close
    level := 0
    for j := close; j >= 0; j--:
      c := fn-type.at --raw j
      if c == ')': level++
      if c == '(':
        level--
        if level == 0:
          open = j
          break
    inside := fn-type[open + 1..close].trim
    if inside == "" or inside == "void": return []
    result := []
    depth := 0
    current := ""
    inside.size.repeat: | i |
      c := inside.at --raw i
      if c == '<' or c == '(': depth++
      if c == '>' or c == ')': depth--
      if c == ',' and depth == 0:
        result.add current.trim
        current = ""
      else:
        current += string.from-rune c
    result.add current.trim
    return result

  // A qualified spelling `A::B<T>::c` -> `A_B_T_c`.
  mangle-spelling s/string -> string:
    s = s.replace --all "toit::" ""
    s = s.replace --all " " ""
    if s.starts-with "::": s = s[2..]
    s = s.replace --all "::" "_"
    s = s.replace --all "<" "_"
    s = s.replace --all ">" ""
    s = s.replace --all "*" "p"
    s = s.replace --all "," "_"
    return s

  constant node/Map ref/Map -> string:
    name := ref["name"]
    s := spelling node
    is-enum := ref["kind"] == "EnumConstantDecl"
    rendered/string := ?
    spelled/string := ?
    context/string? := null
    owner := owners.get ref["id"]
    if s and s.contains "::":
      spelled = s.replace --all "toit::" ""
      rendered = mangle-spelling s
    else if not s and owner and owner != name and constants.values.contains "$(owner)_$name":
      // Spelled inside a macro: named by the class that declares it.
      spelled = "$owner::$name"
      rendered = "$(owner)_$name"
    else if not (cls and constants.values.contains "$(cls)_$name") and not (constants.values.contains name)
        and owner and owner != name and constants.values.contains "$(owner)_$name":
      // A member of an enclosing class (used inside a nested class): named
      // and checked by the class that declares it.
      spelled = "$owner::$name"
      rendered = "$(owner)_$name"
    else:
      spelled = name
      if cls and constants.values.contains "$(cls)_$name":
        rendered = "$(cls)_$name"
      else:
        rendered = name
      context = cxx-cls
    if not constants.values.contains rendered:
      uses["missing:$rendered"] = "$(where node): $spelled ($rendered)"
      return rendered
    use := ConstantUse context spelled rendered is-enum
    uses[use.key] = use
    return rendered

  // --- Expressions.

  wrap e/Expr min/int -> string:
    if e.prec < min: return "($e.text)"
    return e.text

  // As $wrap, and an expression that starts with a VeriFast annotation (a
  // modular operation, `/*@truncating@*/(...)`) is parenthesized too:
  // VeriFast parses one only where an expression starts, not as the
  // operand of a cast or of a binary operator.
  annotated-operand e/Expr min/int -> string:
    if e.text.starts-with "/*@": return "($e.text)"
    return wrap e min

  // As $wrap, for the operand of a binary operator: VeriFast does not parse
  // an annotated expression (`/*@truncating@*/(T)x`, `/*@truncating@*/(a +
  // b)`) as an operand of a shift, additive or multiplicative operator
  // (precedence $min of 11 and more; it does as one of a comparison, a
  // bitwise or a logical operator), so there it is parenthesized.
  binary-operand e/Expr min/int op-prec/int -> string:
    if (e.text.starts-with "/*@") and op-prec >= BINARY-PREC["<<"]: return "($e.text)"
    return wrap e min

  callee-name node/Map -> string:
    while node["kind"] == "ImplicitCastExpr" or node["kind"] == "ParenExpr":
      node = (inner node)[0]
    if node["kind"] != "DeclRefExpr": fail "$(where node): call of a $node["kind"]"
    ref := node["referencedDecl"]
    name := ref["name"]
    // A call through a function pointer held in a local or a parameter
    // (`entry(process, args)`, a primitive's entry): the C call through
    // the pointer, whose contract is its function type's.
    if (ref["kind"] == "VarDecl" or ref["kind"] == "ParmVarDecl") and locals.contains name:
      if not (c-type ref["type"]["qualType"]).ends-with "*": fail "$(where node): call of $name, not a function pointer"
      return name
    s := spelling node
    params := fn-param-types ref["type"]["qualType"]
    c-name/string := ?
    if ref["kind"] == "CXXMethodDecl":
      if s and s.contains "::":
        parts := ((s.replace --all "toit::" "").replace --all " " "").split "::"
        if parts.size != 2: fail "$(where node): call of $s"
        c-name = mangle-member parts[0] parts[1] params
      else if not s and owners.contains ref["id"]:
        // Spelled inside a macro: named by the class that declares it.
        c-name = mangle-member owners[ref["id"]] name params
      else:
        if not cls: fail "$(where node): static member call outside a class"
        c-name = mangle-member cls name params
    else if ref["kind"] == "FunctionDecl":
      c-name = (s ? (mangle-spelling s) : name) + (instance-suffix ref["type"]["qualType"])
      if sidecar.overloaded.contains name:
        c-name = "$(c-name)__$((params.map: (it.replace --all " " "").replace --all "*" "p").join "_")"
    else:
      fail "$(where node): call of a $ref["kind"]"
      unreachable
    note-signature c-name (fn-param-types (canonical ref["type"])) node
    return c-name

  args-of nodes/List -> string:
    return (nodes.map: wrap (expr it) PREC-ASSIGN).join ", "

  is-implicit-this node/Map -> bool:
    while node["kind"] == "ImplicitCastExpr": node = (inner node)[0]
    return node["kind"] == "CXXThisExpr"

  // A variable, or a field of `this` or of a variable: an lvalue whose
  // evaluation has no side effects.
  is-pure-lvalue node/Map -> bool:
    node = strip-parens node
    if node["kind"] == "DeclRefExpr": return true
    if node["kind"] == "MemberExpr":
      base := (inner node)[0]
      return (is-implicit-this base) or (is-pure-lvalue base)
    if node["kind"] == "ImplicitCastExpr" and node["castKind"] == "LValueToRValue":
      return is-pure-lvalue (inner node)[0]
    return false

  expr node/Map -> Expr:
    kind := node["kind"]
    kids := inner node
    if kind == "ParenExpr":
      return Expr "($((expr kids[0]).text))" PREC-PRIMARY
    if kind == "ExprWithCleanups" or kind == "MaterializeTemporaryExpr" or kind == "ConstantExpr" or kind == "CXXBindTemporaryExpr":
      return expr kids[0]
    if kind == "ImplicitCastExpr":
      cast := node["castKind"]
      if (ELIDED-CASTS.contains cast) or (node.get "isPartOfExplicitCast") == true: return expr kids[0]
      if cast == "IntegralCast" and truncating and (c-type node["type"]["qualType"]) == "int" and ((TRUNCATED.contains (resolve (c-type kids[0]["type"]["qualType"]))) or (UNSIGNED-WORDS.contains (resolve (c-type kids[0]["type"]["qualType"])))):
        // `truncating`: the narrowing conversion of a word (or an unsigned
        // word: an id read as a cardinal) to int is the
        // modular one (GCC, Clang, C++20), for code that checks it.
        return Expr "/*@truncating@*/(int)$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
      target-type := c-type node["type"]["qualType"]
      if unsigned-word-conversion and cast == "IntegralCast" and target-type == "uword" and (c-type kids[0]["type"]["qualType"]) == "word":
        return Expr "/*@truncating@*/(uword)$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
      if unsigned-word-conversion and cast == "IntegralCast" and target-type == "unsigned int" and (c-type kids[0]["type"]["qualType"]) == "int" and (strip-parens kids[0])["kind"] != "IntegerLiteral":
        // The same for an int converted to unsigned (modulo 2^32).
        return Expr "/*@truncating@*/(unsigned int)$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
      if cast == "IntegralCast" and truncating and (target-type == "uint8" or target-type == "unsigned char")
          and (c-type kids[0]["type"]["qualType"]) == "int64"
          and (strip-parens kids[0])["kind"] != "IntegerLiteral":
        // `truncating`: the conversion of an int64 to a byte (a store of
        // its low byte, put_uint_*) is modulo 2^8, as C++ defines it for
        // every unsigned target. (Narrower sources, blit's int bytes, stay
        // checked for range.)
        return Expr "/*@truncating@*/(uint8)$(annotated-operand (expr kids[0]) PREC-UNARY)" PREC-UNARY
      if cast == "IntegralCast" and truncating and (SIGNED-TARGETS.contains target-type) and (UNSIGNED-WORDS.contains (resolve (c-type kids[0]["type"]["qualType"]))):
        // `truncating`: so is the conversion of an unsigned word or 64-bit
        // integer to word or int64 (a value above the signed range becomes
        // negative), for code that checks the value afterwards.
        return Expr "/*@truncating@*/($target-type)$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
      if cast == "IntegralCast" and (strip-parens kids[0])["kind"] == "IntegerLiteral":
        return expr kids[0]
      if cast == "IntegralToBoolean" or cast == "PointerToBoolean":
        return Expr "$(wrap (expr kids[0]) 10) != 0" 9
      if cast == "NullToPointer":
        return Expr "0" PREC-PRIMARY
      if WRITTEN-CASTS.contains cast:
        return Expr "($(c-type node["type"]["qualType"]))$(annotated-operand (expr kids[0]) PREC-UNARY)" PREC-UNARY
      fail "$(where node): implicit conversion $cast not supported"
    if kind == "CStyleCastExpr" or kind == "CXXStaticCastExpr" or kind == "CXXReinterpretCastExpr" or kind == "CXXFunctionalCastExpr" or kind == "CXXConstCastExpr":
      // (Clang puts the conversion of a static_cast to a typedef into an
      // implicit IntegralCast under a NoOp.)
      operand := kids[0]
      if node["castKind"] == "NoOp" and operand["kind"] == "ImplicitCastExpr" and operand["castKind"] == "IntegralCast":
        operand = (inner operand)[0]
      else if node["castKind"] != "IntegralCast":
        operand = null
      if kind == "CXXStaticCastExpr" and truncating and operand:
        // CRC treats signed integer arguments as 64-bit bit patterns and
        // converts the finished checksum back to a signed VM integer.
        to := c-type node["type"]["qualType"]
        from := c-type operand["type"]["qualType"]
        if (to == "uint64" and from == "int64") or (to == "int64" and from == "uint64"):
          return Expr "/*@truncating@*/($to)$(annotated-operand (expr operand) PREC-UNARY)" PREC-UNARY
        if (to == "int8" and from == "uint8") or (to == "signed char" and from == "unsigned char"):
          // A byte read as a signed one (the sign extension of the signed
          // integer readers): the modular conversion, a value above 127
          // becomes negative.
          return Expr "/*@truncating@*/($to)$(annotated-operand (expr operand) PREC-UNARY)" PREC-UNARY
      if (kind == "CStyleCastExpr" or kind == "CXXStaticCastExpr") and truncating and operand
          and (c-type node["type"]["qualType"]) == "uint8" and (c-type operand["type"]["qualType"]) == "int64":
        // An explicit conversion of an int64 to a byte (byte_array_at_put's
        // `(uint8) value`): modulo 2^8, as the implicit one above.
        return Expr "/*@truncating@*/(uint8)$(annotated-operand (expr operand) PREC-UNARY)" PREC-UNARY
      if kind == "CXXStaticCastExpr" and truncating and operand
          and (SIGNED-INTEGERS.contains (resolve (c-type (node["type"].get "desugaredQualType" --if-absent=: node["type"]["qualType"]))))
          and (TRUNCATED.contains (resolve (c-type (operand["type"].get "desugaredQualType" --if-absent=: operand["type"]["qualType"])))):
        // `truncating`: an explicit narrowing of a signed integer is the
        // modular conversion too (os_localtime's `static_cast<time_t>` on a
        // 32-bit time_t, the round trip checked).
        return Expr "/*@truncating@*/($(c-type node["type"]["qualType"]))$(wrap (expr operand) PREC-UNARY)" PREC-UNARY
      return Expr "($(c-type node["type"]["qualType"]))$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
    if kind == "CXXDefaultArgExpr":
      // A default argument: its value, written out. It is spelled in the
      // callee's declaration (another file), so only literals, rendered
      // from their values, are supported.
      value := strip-parens kids[0]
      while value["kind"] == "ImplicitCastExpr": value = strip-parens (inner value)[0]
      if value["kind"] == "CXXBoolLiteralExpr": return Expr (value["value"] ? "true" : "false") PREC-PRIMARY
      if value["kind"] == "IntegerLiteral": return Expr "$value["value"]" PREC-PRIMARY
      if value["kind"] == "CXXNullPtrLiteralExpr": return Expr "0" PREC-PRIMARY
      fail "$(where node): default argument $value["kind"] not supported"
    if kind == "IntegerLiteral" or kind == "CharacterLiteral" or kind == "FloatingLiteral":
      s := spelling node
      if s: return Expr s PREC-PRIMARY
      return Expr "$node["value"]" PREC-PRIMARY
    if kind == "StringLiteral":
      return Expr node["value"] PREC-PRIMARY
    if kind == "CXXBoolLiteralExpr":
      return Expr (node["value"] ? "true" : "false") PREC-PRIMARY
    if kind == "CXXNullPtrLiteralExpr":
      return Expr "0" PREC-PRIMARY
    if kind == "CXXThisExpr":
      return Expr "self" PREC-PRIMARY
    if kind == "CXXDeleteExpr":
      // `delete p` (not an array): the destructor (virtual or not) and the
      // deallocation, a function the sidecar declares for p's static class
      // (`T_delete`).
      if (node.get "isArrayAsWritten") == true or (node.get "isArray") == true: fail "$(where node): delete[] not supported"
      operand := kids[0]
      while operand["kind"] == "ImplicitCastExpr" and operand["castKind"] == "LValueToRValue": operand = (inner operand)[0]
      return Expr "$(class-of-pointer kids[0]["type"]["qualType"])_delete($(wrap (expr kids[0]) PREC-ASSIGN))" PREC-PRIMARY
    if kind == "LambdaExpr":
      local := lambda-locals.get node["id"]
      if not local: fail "$(where node): a lambda the closure rules did not prepare"
      return Expr "&$local" PREC-UNARY
    if is-method-copy node: return expr kids[0]
    if kind == "CXXConstructExpr" and (node["type"]["qualType"].contains "(lambda at ") and kids.size == 1:
      // The move of the closure into a by-value parameter: the closure itself.
      return expr kids[0]
    if kind == "CXXOperatorCallExpr" and kids.size == 2:
      callee := kids[0]
      while callee["kind"] == "ImplicitCastExpr": callee = (inner callee)[0]
      if callee["kind"] == "DeclRefExpr" and callee["referencedDecl"]["name"] == "operator()":
        // A call of a closure: its function on the closure struct.
        closure-type := c-type kids[1]["type"]["qualType"]
        fn := "$(closure-type[7..closure-type.size - 1].trim)_call"
        return Expr "$fn($(wrap (expr kids[1]) PREC-ASSIGN))" PREC-PRIMARY
      fail "$(where node): operator call $(callee.get "referencedDecl")"
    if kind == "DeclRefExpr":
      ref := node["referencedDecl"]
      rk := ref["kind"]
      name := ref["name"]
      if captures.contains ref["id"]:
        return Expr captures[ref["id"]] PREC-PRIMARY
      if rk == "ParmVarDecl" and reference-params.contains name:
        return Expr "(*$name)" PREC-PRIMARY
      if local-names.contains ref["id"]: return Expr local-names[ref["id"]] PREC-PRIMARY
      if (rk == "ParmVarDecl" or rk == "VarDecl") and locals.contains name:
        return Expr name PREC-PRIMARY
      if rk == "VarDecl" and cls and sidecar.static-members.contains "$cxx-cls::$name":
        // Verify the storage declaration before referring to its modeled C global.
        record := class-decl.call "toit::$cxx-cls"
        if record:
          members := (inner record).filter: | d | (d.get "name") == name and (d.get "storageClass") == "static"
          if (members.any: it["id"] == ref["id"]): return Expr "$(cls)_$name" PREC-PRIMARY
          // The reference may name the definition outside the class.
          (decls-of.call "toit::$cxx-cls::$name").do: | d/Map |
            if d["id"] == ref["id"] and (members.any: it["id"] == (d.get "previousDecl")):
              return Expr "$(cls)_$name" PREC-PRIMARY
      if rk == "VarDecl" or rk == "EnumConstantDecl":
        return Expr (constant node ref) PREC-PRIMARY
      fail "$(where node): reference to a $rk ($name)"
    if kind == "MemberExpr":
      name := node["name"]
      if is-implicit-this kids[0]: return Expr "self->$name" PREC-PRIMARY
      op := node["isArrow"] ? "->" : "."
      return Expr "$(wrap (expr kids[0]) PREC-PRIMARY)$op$name" PREC-PRIMARY
    if kind == "CallExpr":
      args := kids[1..]
      return Expr "$(callee-name kids[0])($(args-of args))" PREC-PRIMARY
    if kind == "CXXMemberCallExpr":
      member := kids[0]
      if member["kind"] != "MemberExpr": fail "$(where node): member call through a $member["kind"]"
      base := (inner member)[0]
      args := kids[1..]
      base-text/string := ?
      class-name/string := ?
      if member["isArrow"]:
        class-name = class-of-pointer base["type"]["qualType"]
        base-text = (is-implicit-this base) ? "self" : (wrap (expr base) PREC-ASSIGN)
      else:
        class-name = c-type base["type"]["qualType"]
        base-text = "&$(wrap (expr base) PREC-UNARY)"
        // A field of a nested class can have an unqualified type spelling
        // inside its enclosing class. Match the actual selected declaration.
        member-id := member.get "referencedMemberDecl"
        if cxx-cls and base["kind"] == "MemberExpr" and (owners.get member-id) == (cxx-cls.split "::").first:
          nested := "$cxx-cls::$class-name::$member["name"]"
          if ((decls-of.call "toit::$nested").any: | d | d["id"] == member-id and not (d.contains "out-of-line")):
            class-name = "$(cls)_$class-name"
      // ChunkList is the VM typedef for this specialization.
      if class-name == "DoubleLinkedList<Chunk>": class-name = "ChunkList"
      types := arg-types args
      // An overloaded member is named by its declared parameter types (as
      // its definition is), not by the argument types, which differ between
      // targets where a typedef is the type of a literal (word on ILP32).
      if sidecar.overloaded.contains "$class-name::$member["name"]" and class-decl:
        declared := declared-param-types class-name member
        if declared: types = declared
      name := mangle-member class-name member["name"] types
      note-signature name (args.map: c-type (canonical it["type"])) node
      all := [base-text]
      args.do: all.add (wrap (expr it) PREC-ASSIGN)
      return Expr "$name($(all.join ", "))" PREC-PRIMARY
    if kind == "CompoundAssignOperator" and (canonical node["computeLHSType"]) != (canonical node["type"]):
      // `a op= b` computed in another type than a's (`cursor_ +=
      // sizeof(uint32)`: an unsigned long sum for a word): C++ converts a,
      // computes, and converts back; VeriFast wants the conversions
      // written: `a = (A)((C)a op b)`. `a` is evaluated twice, so it must
      // be free of side effects.
      lhs := kids[0]
      if not (is-pure-lvalue lhs): fail "$(where node): compound assignment in another type to a $lhs["kind"]"
      op := node["opcode"]
      binop := op[..op.size - 1]
      p := BINARY-PREC.get binop --if-absent=: fail "$(where node): operator $op"
      a := (expr lhs).text
      computed := "($(c-type (canonical node["computeLHSType"])))$(wrap (expr lhs) PREC-UNARY) $binop $(wrap (expr kids[1]) p + 1)"
      return Expr "$a = ($(c-type node["type"]["qualType"]))($computed)" PREC-ASSIGN
    if kind == "BinaryOperator" or kind == "CompoundAssignOperator":
      op := node["opcode"]
      p := BINARY-PREC.get op --if-absent=: fail "$(where node): operator $op"
      if op == "-" and (kids.every: | child | {"uint8 *", "unsigned char *"}.contains (c-type child["type"]["qualType"])):
        // Both pointee types have unit size. VeriFast implements pointer differences for char pointers.
        return Expr "(char *)$(wrap (expr kids[0]) PREC-UNARY) - (char *)$(wrap (expr kids[1]) PREC-UNARY)" p
      if truncating and op == "<<" and (c-type node["type"]["qualType"]) == "uint64" and kids[1]["kind"] == "IntegerLiteral":
        // An unsigned 64-bit shift discards high bits. The literal must
        // be a valid shift count before the modular rendering applies.
        count := int.parse kids[1]["value"]
        if 0 <= count and count < 64:
          return Expr "/*@truncating@*/($(wrap (expr kids[0]) p) << $count)" PREC-PRIMARY
      if truncating and op == "<<" and (c-type node["type"]["qualType"]) == "uint64" and kids[1]["kind"] != "IntegerLiteral"
          and (strip-parens kids[0])["kind"] == "CXXStaticCastExpr":
        // The same shift by a count computed at run time, of an explicitly
        // converted value (the bit pattern of a signed integer:
        // Utils::wrapping_shift_left): VeriFast checks that the count is in
        // [0, 63] (a shift by a negative count or by the width or more is
        // undefined), the shift itself is modular. (Other shifts by a
        // variable count stay checked for overflow: crc's mask.)
        return Expr "/*@truncating@*/($(binary-operand (expr kids[0]) p p) << $(wrap (expr kids[1]) p + 1))" PREC-PRIMARY
      if truncating and op == "-" and (c-type node["type"]["qualType"]) == "uword":
        // Unsigned address differences wrap at the target word width.
        return Expr "/*@truncating@*/($(binary-operand (expr kids[0]) p p) - $(binary-operand (expr kids[1]) (p + 1) p))" PREC-PRIMARY
      if truncating and op == ">>=" and kids[0]["kind"] == "DeclRefExpr" and (c-type node["type"]["qualType"]) == "int64" and kids[1]["kind"] == "IntegerLiteral":
        // An arithmetic right shift of a signed value (put_uint_*'s
        // `value >>= 8`): implementation-defined in C++11 for a negative
        // value, sign-extending in GCC and Clang (and standardized so in
        // C++20); VeriFast refuses it. Written as the same floor division
        // without it: `x >> c` for x >= 0, `-1 - ((-1 - x) >> c)` below
        // (no overflow: -1 - x is in [0, INT64_MAX]). A plain variable:
        // the lvalue is evaluated more than once.
        count := int.parse kids[1]["value"]
        if 0 <= count and count < 64:
          v := (expr kids[0]).text
          return Expr "$v = $v >= 0 ? $v >> $count : -1 - ((-1 - $v) >> $count)" PREC-ASSIGN
      if truncating and op == "<<=" and kids[0]["kind"] == "DeclRefExpr" and (c-type node["type"]["qualType"]) == "uint64" and kids[1]["kind"] == "IntegerLiteral":
        // The compound form of the modular uint64 shift by a literal (a
        // plain variable: the lvalue is evaluated twice).
        count := int.parse kids[1]["value"]
        if 0 <= count and count < 64:
          lhs := (expr kids[0]).text
          return Expr "$lhs = /*@truncating@*/($lhs << $count)" PREC-ASSIGN
      if truncating and op == "+=" and kids[0]["kind"] == "DeclRefExpr" and (c-type node["type"]["qualType"]) == "uword" and (canonical node["computeResultType"]) == (canonical node["type"]):
        // Expanding a plain word variable preserves evaluation of the lvalue and the modular sum.
        lhs := (expr kids[0]).text
        rhs := wrap (expr kids[1]) (BINARY-PREC["+"] + 1)
        return Expr "$lhs = /*@truncating@*/($lhs + $rhs)" PREC-ASSIGN
      if truncating and op == "+" and {"uint64", "uword"}.contains (c-type node["type"]["qualType"]):
        // Unsigned sums wrap at their declared width, including biased metadata addresses.
        sum := "/*@truncating@*/($(binary-operand (expr kids[0]) p p) + $(binary-operand (expr kids[1]) (p + 1) p))"
        return Expr sum p
      if p == PREC-ASSIGN:
        return Expr "$(wrap (expr kids[0]) PREC-UNARY) $op $(wrap (expr kids[1]) PREC-ASSIGN)" p
      return Expr "$(binary-operand (expr kids[0]) p p) $op $(binary-operand (expr kids[1]) (p + 1) p)" p
    if kind == "UnaryOperator":
      op := node["opcode"]
      if node.get "isPostfix": return Expr "$(wrap (expr kids[0]) PREC-PRIMARY)$op" PREC-PRIMARY
      return Expr "$op$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
    if kind == "ConditionalOperator":
      return Expr "$(wrap (expr kids[0]) PREC-COND + 1) ? $(wrap (expr kids[1]) PREC-ASSIGN) : $(wrap (expr kids[2]) PREC-COND)" PREC-COND
    if kind == "ArraySubscriptExpr":
      return Expr "$(wrap (expr kids[0]) PREC-PRIMARY)[$((expr kids[1]).text)]" PREC-PRIMARY
    if kind == "UnaryExprOrTypeTraitExpr":
      if node["name"] != "sizeof": fail "$(where node): $node["name"]"
      if node.contains "argType": return Expr "sizeof($(c-type node["argType"]["qualType"]))" PREC-PRIMARY
      return Expr "sizeof($((expr kids[0]).text))" PREC-PRIMARY
    fail "$(where node): expression kind $kind not supported"
    unreachable

  strip-parens node/Map -> Map:
    while node["kind"] == "ParenExpr": node = (inner node)[0]
    return node

  // --- Statements.

  live-destructors -> List:
    result := []
    raii-scopes.do --reversed: | scope/List |
      scope.do --reversed: | entry/List | result.add "$(entry[0])_dtor(&$(entry[1]));"
    return result

  // Renders $node as a block body (braces added by the caller).
  body node/Map indent/int:
    if node["kind"] == "CompoundStmt":
      block-contents node indent
    else:
      ghosts-up-to (begin-offset node) indent
      stmt node indent null

  // VeriFast wants a local whose address is taken declared at the start of
  // its block: such a declaration (and an object constructed in place, whose
  // constructor gets its address) moves there; its initialization stays
  // where it was. Declaring earlier changes nothing in C.
  hoist kids/List block/Map indent/int:
    kids.do: | k/Map |
      (lambda-at.get k["id"] --if-absent=: []).do: | c/Closure |
        emit indent "struct $c.name $c.local;"
      if k["kind"] == "DeclStmt":
        (inner k).do: | d/Map |
          if d["kind"] == "VarDecl":
            init := (inner d).is-empty ? null : (strip-cleanups (inner d)[0])
            if (init and init["kind"] == "CXXConstructExpr") or (address-taken block d["id"]):
              hoisted.add d["id"]
              emit indent "$(declarator (c-type d["type"]["qualType"]) (local-name d));"

  address-taken node id/string -> bool:
    if node is List:
      (node as List).do: if address-taken it id: return true
      return false
    if node is not Map: return false
    m := node as Map
    if (m.get "kind") == "UnaryOperator" and (m.get "opcode") == "&":
      target := (inner m)[0]
      while target["kind"] == "ParenExpr" or target["kind"] == "ImplicitCastExpr": target = (inner target)[0]
      if target["kind"] == "DeclRefExpr" and target["referencedDecl"]["id"] == id: return true
    return address-taken (inner m) id

  block-contents node/Map indent/int:
    name-scopes.add {}
    raii-scopes.add []
    kids := inner node
    hoist kids node indent
    end := end-offset node
    kids.size.repeat: | i |
      next := i + 1 < kids.size ? (begin-offset kids[i + 1]) : end
      ghosts-up-to (begin-offset kids[i]) indent
      stmt kids[i] indent next
    ghosts-up-to end indent
    scope := raii-scopes.remove-last
    if not scope.is-empty and not (kids.size > 0 and kids.last["kind"] == "ReturnStmt"):
      scope.do --reversed: | entry/List | emit indent "$(entry[0])_dtor(&$(entry[1]));"
    name-scopes.remove-last

  // $next: the offset where the statement after $node starts (or the end
  // of the enclosing block), or null when $node is a branch on its own.
  stmt node/Map indent/int next/int?:
    kind := node["kind"]
    kids := inner node
    // The closures this statement creates get their captured values first
    // (nothing in the statement assigns them: checked by the closure rules).
    (lambda-at.get node["id"] --if-absent=: []).do: | c/Closure |
      c.captures.do: | cap/List | emit indent "$c.local.$cap[0] = $cap[0];"
    if kind == "CompoundStmt":
      emit indent "{"
      block-contents node indent + 1
      emit indent "}"
    else if kind == "DeclStmt":
      kids.do: | decl/Map |
        if decl["kind"] == "StaticAssertDecl":
          // Clang checks the specialization. Also check the condition against the rendered types.
          emit indent "//@ assert $((expr (inner decl)[0]).text);"
        else:
          var-decl decl indent
    else if kind == "CXXMemberCallExpr" and kids.size == 3 and (kids[0].get "name") == "fetch_add" and
        ((canonical (inner kids[0])[0]["type"]).starts-with "std::__atomic_base<"):
      // A discarded relaxed uint64 fetch_add issues one atomic charge, including on ILP32.
      base := (inner kids[0])[0]
      amount := kids[1]
      order := kids[2]
      width := canonical node["type"]
      if base["kind"] != "ImplicitCastExpr" or base["castKind"] != "UncheckedDerivedToBase" or
          (canonical base["type"]) != "std::__atomic_base<$width>" or
          (inner base)[0]["type"]["qualType"] != "std::atomic<uint64>" or
          (canonical (inner base)[0]["type"]) != "std::atomic<$width>" or
          (canonical amount["type"]) != width or order["kind"] != "DeclRefExpr" or
          order["type"]["qualType"] != "std::memory_order" or order["referencedDecl"]["name"] != "memory_order_relaxed":
        fail "$(where node): unsupported atomic fetch_add"
      if amount["kind"] == "ImplicitCastExpr" and amount["castKind"] == "IntegralCast": amount = (inner amount)[0]
      if amount["type"]["qualType"] != "uword": fail "$(where node): expected word-sized atomic charge"
      emit indent "atomic_uint64_add_relaxed(&$(wrap (expr (inner base)[0]) PREC-UNARY), $(wrap (expr amount) PREC-ASSIGN));"
    else if kind == "CXXOperatorCallExpr" and kids.size == 3 and kids[1]["kind"] == "ImplicitCastExpr" and kids[1]["castKind"] == "UncheckedDerivedToBase":
      // Discarded compound updates on std::atomic<uword> are single atomic operations.
      receiver := (inner kids[1])[0]
      callee := kids[0]
      if callee["kind"] == "ImplicitCastExpr": callee = (inner callee)[0]
      value-type := canonical kids[2]["type"]
      if callee["kind"] != "DeclRefExpr" or
          receiver["type"]["qualType"] != "std::atomic<uword>" or
          (canonical receiver["type"]) != "std::atomic<$value-type>" or
          (canonical kids[1]["type"]) != "std::__atomic_base<$value-type>":
        fail "$(where node): unsupported overloaded operator statement"
      operator := callee["referencedDecl"]["name"]
      if operator != "operator-=" and operator != "operator+=": fail "$(where node): unsupported atomic update $operator"
      operation := operator == "operator+=" ? "add" : "subtract"
      emit indent "atomic_uword_$operation(&$(wrap (expr receiver) PREC-UNARY), $(wrap (expr kids[2]) PREC-ASSIGN));"
    else if kind == "ReturnStmt":
      after := next != null and (has-ghosts-up-to next)
      dtors := live-destructors
      if kids.is-empty:
        if after: ghosts-up-to next indent
        dtors.do: emit indent it
        emit indent "return;"
      else if not after and dtors.is-empty:
        emit indent "return $((expr kids[0]).text);"
      else:
        name := "result$(temp-count++)"
        emit indent "{"
        emit (indent + 1) "$result-type $name = $(wrap (expr kids[0]) PREC-ASSIGN);"
        if after: ghosts-up-to next (indent + 1)
        dtors.do: emit (indent + 1) it
        emit (indent + 1) "return $name;"
        emit indent "}"
    else if kind == "IfStmt":
      if node.get "hasInit" or node.get "hasVar": fail "$(where node): if with an initializer"
      if-chain node indent "if"
    else if kind == "CXXForRangeStmt":
      linked-range node indent
    else if kind == "ForStmt":
      init := kids[0]
      if not is-empty kids[1]: fail "$(where node): for with a condition variable"
      // The loop variable's scope is the loop.
      name-scopes.add {}
      init-text := ""
      if not is-empty init:
        if init["kind"] == "DeclStmt":
          decls := inner init
          if decls.size != 1: fail "$(where node): several loop variables"
          init-text = var-decl-text decls[0]
        else:
          init-text = (expr init).text
      cond-text := is-empty kids[2] ? "" : (expr kids[2]).text
      inc-text := is-empty kids[3] ? "" : (expr kids[3]).text
      emit indent "for ($init-text; $cond-text; $inc-text)"
      loop-body kids[4] indent
      name-scopes.remove-last
    else if kind == "WhileStmt":
      if node.get "hasVar":
        // A fresh pointer is initialized and tested on each iteration.
        decls := inner kids[0]
        if kids.size != 3 or kids[0]["kind"] != "DeclStmt" or decls.size != 1 or
            not (canonical decls[0]["type"]).ends-with "*":
          fail "$(where node): expected a single pointer condition variable"
        name-scopes.add {}
        emit indent "while (true)"
        ghosts-up-to (begin-offset kids[2]) indent
        emit indent "{"
        var-decl decls[0] (indent + 1)
        emit (indent + 1) "if (!($((expr kids[1]).text))) break;"
        body kids[2] (indent + 1)
        emit indent "}"
        name-scopes.remove-last
        return
      cond := strip-parens kids[0]
      if is-release-assert cond:
        emit indent "// ASSERT($((expr (strip-parens (inner cond)[1])).text)): release build, not evaluated."
        ghosts.do: | g/Ghost |
          if g.anchor > (begin-offset node) and g.anchor <= (end-offset node): g.emitted = true
        return
      emit indent "while ($((expr kids[0]).text))"
      loop-body kids[1] indent
    else if kind == "DoStmt":
      // `do S while (false)` (a macro's statement wrapper): S once, as a
      // block, when no break or continue of S leaves the do.
      cond := strip-parens kids[1]
      while cond["kind"] == "ImplicitCastExpr": cond = strip-parens (inner cond)[0]
      if cond["kind"] != "CXXBoolLiteralExpr" or cond["value"] != false:
        fail "$(where node): do-while loop with a condition other than false"
      if has-loop-exit kids[0] false: fail "$(where node): break or continue in a do-while (false)"
      if kids[0]["kind"] == "CompoundStmt":
        stmt kids[0] indent next
      else:
        emit indent "{"
        body kids[0] (indent + 1)
        emit indent "}"
    else if kind == "SwitchStmt":
      // `switch (c) { case V: ... default: ... }`: the labels as written
      // (a label's statement and the statements after it, up to the next
      // label, follow it), the values from the constant table.
      if node.get "hasInit" or node.get "hasVar": fail "$(where node): switch with an initializer"
      sw-body := kids.last
      if sw-body["kind"] != "CompoundStmt": fail "$(where node): switch without a block"
      emit indent "switch ($((expr kids[0]).text)) {"
      items := inner sw-body
      end := end-offset sw-body
      items.size.repeat: | i |
        item-next := i + 1 < items.size ? (begin-offset items[i + 1]) : end
        ghosts-up-to (begin-offset items[i]) (indent + 1)
        switch-item items[i] (indent + 1) item-next
      ghosts-up-to end (indent + 1)
      emit indent "}"
    else if kind == "BreakStmt":
      emit indent "break;"
    else if kind == "ContinueStmt":
      emit indent "continue;"
    else if kind == "NullStmt":
      null  // An empty statement: nothing to render.
    else if is-assign-call (strip-cleanups node):
      class-assignment (strip-cleanups node) indent
    else if kind.ends-with "Expr" or kind.ends-with "Operator" or kind == "ExprWithCleanups":
      emit indent "$((expr node).text);"
    else:
      fail "$(where node): statement kind $kind not supported"

  // A statement of a switch's block: a label (with its statement, which
  // may be another label) or a statement under the last label.
  switch-item node/Map indent/int next/int:
    kind := node["kind"]
    if kind == "CaseStmt":
      kids := inner node
      if kids.size != 2: fail "$(where node): case range or empty case"
      emit indent "case $((expr kids[0]).text):"
      ghosts-up-to (begin-offset kids[1]) (indent + 1)
      switch-item kids[1] indent next
    else if kind == "DefaultStmt":
      emit indent "default:"
      sub := (inner node)[0]
      ghosts-up-to (begin-offset sub) (indent + 1)
      switch-item sub indent next
    else:
      stmt node (indent + 1) next

  // Whether $node has a break or continue that leaves the statement it is
  // in (not one of a nested loop; a break of a nested switch neither, when
  // $in-switch).
  has-loop-exit node in-switch/bool -> bool:
    if node is List:
      (node as List).do: if has-loop-exit it in-switch: return true
      return false
    if node is not Map: return false
    kind := (node as Map).get "kind"
    if kind == "ContinueStmt": return true
    if kind == "BreakStmt": return not in-switch
    if kind == "ForStmt" or kind == "WhileStmt" or kind == "DoStmt": return false
    return has-loop-exit (inner node) (in-switch or kind == "SwitchStmt")

  is-release-assert cond/Map -> bool:
    if cond["kind"] != "BinaryOperator" or cond["opcode"] != "&&": return false
    left := strip-parens (inner cond)[0]
    return left["kind"] == "CXXBoolLiteralExpr" and left["value"] == false

  // Lower the cursors checked by chunk_iterator.cc, gc_root_iterator.cc and
  // scheduler_target_queue.cc. The accepted statements fall through to the
  // implicit increment. Closing-brace annotations run after it.
  linked-range node/Map indent/int:
    kids := inner node
    if kids.size != 8 or not (is-empty kids[0]): fail "$(where node): unsupported range initializer"
    range := (inner (inner kids[1])[0])[0]
    decl := (inner kids[6])[0]
    block := kids[7]
    statements := inner block
    range-type := range["type"].get "desugaredQualType"
    element-type := "Chunk"
    list-type := "ChunkList"
    scheduler-workers := range-type == "LinkedList<toit::SchedulerThread>"
    process-groups := range-type == "DoubleLinkedList<toit::ProcessGroup>"
    group-members := range-type == "LinkedList<toit::Process>"
    scheduler-targets := range-type == "LinkedFifo<toit::Process, 2>"
    if range-type == "DoubleLinkedList<toit::HeapRoot>":
      element-type = "HeapRoot"
      list-type = "HeapRootList"
    else if range-type == "DoubleLinkedList<toit::ObjectNotifier>":
      element-type = "ObjectNotifier"
      list-type = "ObjectNotifierList"
    else if scheduler-workers:
      element-type = "SchedulerThread"
      list-type = "SchedulerThreadList"
    else if process-groups:
      element-type = "ProcessGroup"
      list-type = "ProcessGroupList"
    else if group-members:
      element-type = "Process"
      list-type = "ProcessListFromProcessGroup"
    else if scheduler-targets:
      element-type = "Process"
      list-type = "ProcessListFromScheduler"
    else if range-type != "const DoubleLinkedList<toit::Chunk>" and range-type != "DoubleLinkedList<toit::Chunk>":
      fail "$(where node): unsupported linked-list range type"
    pointer-type := (decl["type"]["qualType"] as string).replace --all "toit::" ""
    expected := range-type == "const DoubleLinkedList<toit::Chunk>" ? "const Chunk *" : "$(element-type) *"
    body-size := (scheduler-targets or scheduler-workers) ? 2 : 1
    // A range reached through a cast or a call (e.g. a const_cast that
    // makes a const method's list mutable) is not lowered.
    if not (is-pure-lvalue range): fail "$(where node): the linked-list range is not a variable or member"
    if pointer-type != expected: fail "$(where node): linked-list element of type $pointer-type, expected $expected"
    if block["kind"] != "CompoundStmt" or statements.size != body-size:
      fail "$(where node): unexpected linked-list range body"
    body-kinds := element-type == "Chunk" ? ["CompoundAssignOperator", "CallExpr"] : ["CXXMemberCallExpr"]
    if range-type == "DoubleLinkedList<toit::Chunk>": body-kinds = ["IfStmt", "BinaryOperator"]
    if scheduler-workers: body-kinds = ["DeclStmt"]
    if process-groups: body-kinds = ["CXXForRangeStmt"]
    if group-members: body-kinds = ["IfStmt"]
    if not (body-kinds.contains statements[0]["kind"]): fail "$(where node): unsupported linked-list range body"
    if scheduler-workers:
      decls := inner statements[0]
      if decls.size != 1 or decls[0]["type"]["qualType"] != "Process *" or statements[1]["kind"] != "IfStmt":
        fail "$(where node): unexpected preemption loop body"
      branch := inner statements[1]
      if branch.size != 2 or branch[1]["kind"] != "CompoundStmt": fail "$(where node): unexpected preemption condition"
      actions := inner branch[1]
      if actions.size != 2 or actions[0]["kind"] != "CXXMemberCallExpr" or actions[1]["kind"] != "UnaryOperator":
        fail "$(where node): expected a preemption request and counter update"
    if group-members:
      // A conditional append falls through to the implicit iterator increment.
      branch := inner statements[0]
      if branch.size != 2 or branch[1]["kind"] != "CompoundStmt": fail "$(where node): unexpected group member condition"
      actions := inner branch[1]
      if actions.size != 1 or actions[0]["kind"] != "CXXMemberCallExpr": fail "$(where node): expected a conditional member call"
    if scheduler-targets and statements[1]["kind"] != "UnaryOperator": fail "$(where node): expected a scan counter update"
    // Clang resolves the three overloaded operators in the implicit header.
    [4, 5, 6].do: | index |
      op := index == 6 ? (inner decl)[0] : kids[index]
      name := ["operator!=", "operator++", "operator*"][index - 4]
      if op["kind"] != "CXXOperatorCallExpr" or ((inner (inner op)[0])[0]["referencedDecl"].get "name") != name:
        fail "$(where node): unexpected range operator"
    range-name := local-name (inner kids[1])[0]
    cursor := local-name (inner kids[2])[0]
    end := local-name (inner kids[3])[0]
    element := local-name decl
    emit indent "$list-type *$range-name = &$(wrap (expr range) PREC-UNARY);"
    // A process has separate intrusive links for membership and scheduling.
    link := group-members ? "member_next_" : "next_"
    emit indent "$element-type *$cursor = $range-name->anchor_.$link;"
    end-value := (scheduler-targets or group-members or scheduler-workers) ? "0" : "&$range-name->anchor_"
    emit indent "$element-type *$end = $end-value;"
    emit indent "while ($cursor != $end)"
    ghosts-up-to (begin-offset block) indent
    emit indent "{"
    emit (indent + 1) "$element-type *$element = $cursor;"
    statements.do: | statement |
      ghosts-up-to (begin-offset statement) (indent + 1)
      stmt statement (indent + 1) null
    emit (indent + 1) "$cursor = $cursor->$link;"
    ghosts-up-to (end-offset block) (indent + 1)
    emit indent "}"

  loop-body node/Map indent/int:
    // Annotations anchored at the body's `{` are the loop invariant; for a
    // body without braces, those anchored at its first token.
    ghosts-up-to (begin-offset node) indent
    emit indent "{"
    body node indent + 1
    emit indent "}"

  if-chain node/Map indent/int keyword/string:
    kids := inner node
    emit indent "$keyword ($((expr kids[0]).text)) {"
    body kids[1] indent + 1
    if kids.size > 2:
      else-node := kids[2]
      if else-node["kind"] == "IfStmt" and not (has-ghosts-up-to (begin-offset else-node)):
        if-chain-else else-node indent
        return
      emit indent "} else {"
      body else-node indent + 1
    emit indent "}"

  if-chain-else node/Map indent/int:
    kids := inner node
    emit indent "} else if ($((expr kids[0]).text)) {"
    body kids[1] indent + 1
    if kids.size > 2:
      else-node := kids[2]
      if else-node["kind"] == "IfStmt" and not (has-ghosts-up-to (begin-offset else-node)):
        if-chain-else else-node indent
        return
      emit indent "} else {"
      body else-node indent + 1
    emit indent "}"

  // The C name of a local: its own, or, when it hides another local of the
  // function (a nested block's `encoder`; VeriFast rejects hiding), the
  // name with a suffix. References find it by the declaration's id.
  local-name decl/Map -> string:
    id := decl["id"]
    if local-names.contains id: return local-names[id]
    name := decl["name"]
    visible := : | n/string | (param-names.contains n) or (name-scopes.any: | s/Set | s.contains n)
    if visible.call name:
      n := 1
      while visible.call "$(name)_$n": n++
      name = "$(name)_$n"
    locals.add name
    if not name-scopes.is-empty: (name-scopes.last as Set).add name
    local-names[id] = name
    return name

  var-decl-text decl/Map -> string:
    name := local-name decl
    type := c-type decl["type"]["qualType"]
    kids := inner decl
    if kids.is-empty: return declarator type name
    init := kids[0]
    if init["kind"] == "CXXConstructExpr": fail "$(where decl): object construction in a loop header"
    return "$(declarator type name) = $(wrap (expr init) PREC-ASSIGN)"

  var-decl decl/Map indent/int:
    if decl["kind"] != "VarDecl": fail "$(where decl): declaration kind $decl["kind"]"
    if decl.get "storageClass": fail "$(where decl): $decl["storageClass"] local"
    kids := inner decl
    init := kids.is-empty ? null : (strip-cleanups kids[0])
    if init and init["kind"] == "InitListExpr" and decl["type"]["qualType"] == "struct timespec":
      fields := inner init
      if fields.size != 2 or not (fields.every: it["kind"] == "ImplicitValueInitExpr" and (canonical it["type"]) == "long"):
        fail "$(where decl): expected two zero-initialized long fields in timespec"
      name := local-name decl
      if not hoisted.contains decl["id"]: emit indent "struct timespec $name;"
      emit indent "$(name).tv_sec = 0;"
      emit indent "$(name).tv_nsec = 0;"
      return
    if init and init["kind"] == "CXXConstructExpr" and not (is-method-copy init):
      name := local-name decl
      type := c-type decl["type"]["qualType"]
      if not hoisted.contains decl["id"]: emit indent "$(declarator type name);"
      construct name type init indent
      if sidecar.raii.contains type: raii-scopes.last.add [type, name]
      return
    new-init := init
    while new-init and new-init["kind"] == "ImplicitCastExpr" and (new-init["castKind"] == "NoOp" or new-init["castKind"] == "DerivedToBase"):
      new-init = (inner new-init)[0]
    if new-init and new-init["kind"] == "CXXNewExpr":
      // `T* v = new (std::nothrow) T(args);` (the `_new` of src/top.h):
      // the allocation, a function the sidecar declares (`T_new_nothrow`:
      // null, or the fields of a fresh T), then the constructor on success
      // only. The arguments are evaluated after the allocation (C++17's
      // order; C++11 leaves it open), so they must not assign anything.
      nk := inner new-init
      placement := nk.size == 2 ? (strip-parens nk[1]) : null
      while placement and placement["kind"] == "ImplicitCastExpr": placement = (inner placement)[0]
      if not (new-init.get "isPlacement") or not placement or placement["kind"] != "DeclRefExpr"
          or placement["referencedDecl"]["name"] != "nothrow" or nk[0]["kind"] != "CXXConstructExpr":
        fail "$(where decl): only `new (std::nothrow) T(args)` is supported"
      if modifies-anything nk[0]: fail "$(where decl): the arguments of a new-expression must not assign anything"
      if hoisted.contains decl["id"]: fail "$(where decl): a new-expression into a local whose address is taken"
      name := local-name decl
      type := c-type decl["type"]["qualType"]
      cls-type := c-type nk[0]["type"]["qualType"]
      emit indent "$(declarator type name) = $(cls-type)_new_nothrow();"
      emit indent "if ($name != 0) {"
      construct-into name cls-type nk[0] (indent + 1)
      emit indent "}"
      return
    if hoisted.contains decl["id"]:
      name := local-name decl
      if init: emit indent "$name = $(wrap (expr init) PREC-ASSIGN);"
      return
    emit indent "$(var-decl-text decl);"

  // Whether $node has an assignment, compound assignment, increment,
  // decrement or new-expression.
  modifies-anything node -> bool:
    if node is List:
      (node as List).do: if modifies-anything it: return true
      return false
    if node is not Map: return false
    m := node as Map
    kind := m.get "kind"
    if kind == "CompoundAssignOperator" or kind == "CXXNewExpr": return true
    if kind == "BinaryOperator" and m["opcode"] == "=": return true
    if kind == "UnaryOperator" and (m["opcode"] == "++" or m["opcode"] == "--"): return true
    return modifies-anything (inner m)

  // The constructor call of $init (a CXXConstructExpr or a
  // CXXTemporaryObjectExpr) for the object $name of C type $type.
  construct name/string type/string init/Map indent/int:
    construct-into "&$name" type init indent

  // The constructor call of $init for the object at $target (`&name`, or
  // `self` for a delegating constructor).
  construct-into target/string type/string init/Map indent/int:
    // A non-const reference parameter of the constructor is a pointer.
    ctor-params := fn-param-types-raw init["ctorType"]["qualType"]
    args := []
    modular := sidecar.modular.contains "$type::$type"
    (inner init).size.repeat: | i |
      a := (inner init)[i]
      by-ref := i < ctor-params.size and (is-reference ctor-params[i])
      if modular and not by-ref and a["kind"] == "ImplicitCastExpr" and a["castKind"] == "IntegralCast":
        // `@modular-arguments`: the argument's conversion is the modular
        // one C and C++ define for an unsigned target (a negative tag).
        if not (c-type a["type"]["qualType"]).starts-with "u": fail "$(where a): @modular-arguments for a signed parameter"
        args.add "/*@truncating@*/($(c-type a["type"]["qualType"]))$(wrap (expr (inner a)[0]) PREC-UNARY)"
      else:
        args.add (by-ref ? "&$(wrap (expr a) PREC-UNARY)" : (wrap (expr a) PREC-ASSIGN))
    // A struct of a C header (`struct tm`): named by its tag.
    ctor-cls := type.starts-with "struct " ? type[7..] : type
    ctor-name := mangle-member ctor-cls ctor-cls (ctor-params.map: c-type it)
    note-signature ctor-name (ctor-params.map: c-type it) init
    emit indent "$ctor-name($(([target] + args).join ", "));"

  /**
  `a = b` for objects of a class whose assignment operator is the implicit
    one (checked in Clang's AST): member-wise assignment, which is what the
    implicit copy and move assignments do. A temporary on the right
    (`a = C(x)`) is constructed first, into a local.
  */
  class-assignment node/Map indent/int:
    kids := inner node
    callee := kids[0]
    while callee["kind"] == "ImplicitCastExpr": callee = (inner callee)[0]
    ref := callee["referencedDecl"]
    lhs := kids[1]
    rhs := kids[2]
    cls-name := c-type lhs["type"]["qualType"]
    decl := class-decl.call "toit::$(cls-name.replace --all "_" "::")"
    if not decl: fail "$(where node): no class $cls-name in the AST"
    implicit := false
    fields := []
    (inner decl).do: | m/Map |
      if m["kind"] == "CXXMethodDecl" and m["id"] == ref["id"] and (m.get "isImplicit") == true: implicit = true
      if m["kind"] == "FieldDecl": fields.add m["name"]
    if not implicit: fail "$(where node): $cls-name::operator= is not the implicit one"
    target := wrap (expr lhs) PREC-PRIMARY
    while rhs["kind"] == "MaterializeTemporaryExpr" or rhs["kind"] == "ExprWithCleanups" or rhs["kind"] == "CXXBindTemporaryExpr":
      rhs = (inner rhs)[0]
    emit indent "{"
    source-text/string := ?
    if rhs["kind"] == "CXXTemporaryObjectExpr" or rhs["kind"] == "CXXConstructExpr":
      source-text = "tmp$(temp-count++)"
      emit (indent + 1) "$(declarator cls-name source-text);"
      construct source-text cls-name rhs (indent + 1)
    else:
      source-text = wrap (expr rhs) PREC-PRIMARY
    fields.do: | f | emit (indent + 1) "($target).$f = $source-text.$f;"
    emit indent "}"

  // The C parameter types of the member a MemberExpr refers to, from its
  // declaration in the class (null when not found).
  declared-param-types class-name/string member/Map -> List?:
    id := member.get "referencedMemberDecl"
    if not id: return null
    // The member in its class, or its out-of-line definition (a call can
    // refer to either).
    found := null
    (decls-of.call "toit::$(class-name.replace --all "_" "::")::$member["name"]").do: | m/Map |
      if m["id"] == id and m.contains "type": found = fn-param-types m["type"]["qualType"]
    return found

  is-assign-call node/Map -> bool:
    if node["kind"] != "CXXOperatorCallExpr": return false
    callee := (inner node)[0]
    while callee["kind"] == "ImplicitCastExpr": callee = (inner callee)[0]
    return callee["kind"] == "DeclRefExpr" and callee["referencedDecl"]["name"] == "operator="

  strip-cleanups node/Map -> Map:
    while node["kind"] == "ExprWithCleanups": node = (inner node)[0]
    return node

  // --- Functions.

  signature decl/Map -> string:
    kind := decl["kind"]
    name := decl["name"]
    params := (inner decl).filter: it["kind"] == "ParmVarDecl"
    ps := []
    is-member := (kind == "CXXMethodDecl" or kind == "CXXConstructorDecl" or kind == "CXXDestructorDecl") and (decl.get "storageClass") != "static"
    if is-member: ps.add "$cls *self"
    types := []
    params.size.repeat: | i |
      p := params[i]
      pname := p.get "name" --if-absent=: "p$i"
      locals.add pname
      if is-reference p["type"]["qualType"]: reference-params.add pname
      param-names.add pname
      t := c-type p["type"]["qualType"]
      types.add t
      ps.add (declarator t pname)
    if ps.is-empty: ps.add "void"
    fname := cls ? (mangle-member cls name types) : name + (instance-suffix decl["type"]["qualType"])
    note-signature fname (params.map: c-type (canonical it["type"])) decl
    result-type = (kind == "CXXConstructorDecl" or kind == "CXXDestructorDecl") ? "void" : (return-type decl["type"]["qualType"])
    return declarator result-type "$fname($(ps.join ", "))"

  c-name decl/Map -> string:
    params := (inner decl).filter: it["kind"] == "ParmVarDecl"
    types := params.map: c-type it["type"]["qualType"]
    return cls ? (mangle-member cls decl["name"] types) : decl["name"] + (instance-suffix decl["type"]["qualType"])

  // A function template instance taking a closure (the closure rules) is
  // named after the lambda: `name__F_lambdaK`.
  instance-suffix fn-type/string -> string:
    at := fn-type.index-of "(lambda at "
    if at < 0: return ""
    close := fn-type.index-of ")" at
    lambda := LAMBDA-NAMES.get fn-type[at..close + 1]
    if not lambda: fail "$fn-type: a closure type of no rendered function"
    return "__$lambda"

  // The function of a closure (the closure rules), rendered by a renderer
  // whose `captures` name the struct's fields.
  lambda-function c/Closure --prototype/bool=false:
    result-type = c.result-type
    fn := "$(c.name)_call"
    note-signature fn ["struct $c.name *"] c.node
    lines.add (declarator c.result-type "$fn(struct $c.name *closure)") + (prototype ? ";" : "")
    ghosts-up-to (begin-offset c.body) 0
    if prototype: return
    lines.add "{"
    block-contents c.body 1
    lines.add "}"

  function decl/Map body-node/Map --prototype/bool=false:
    sig := signature decl
    lines.add sig + (prototype ? ";" : "")
    // Annotations anchored at the body's `{`: the contract.
    ghosts-up-to (begin-offset body-node) 0
    if prototype: return
    lines.add "{"
    (inner decl).do: | init/Map |
      if init["kind"] == "CXXCtorInitializer":
        if init.contains "delegatingInit":
          // A delegating constructor: the target constructor on self.
          construct-into "self" cls (inner init)[0] 1
        else if init.contains "baseInit":
          // The base subobject uses the receiver representation of the sidecar.
          // Forward its constructor arguments with the usual conversion rules.
          base-ctor := (inner init)[0]
          if base-ctor["kind"] != "CXXConstructExpr" or (base-ctor.get "constructionKind") != "non-virtual base":
            fail "$(where decl): expected a non-virtual base constructor"
          construct-into "self" (c-type init["baseInit"]["qualType"]) base-ctor 1
        else if not init.contains "anyInit":
          fail "$(where decl): a base-class initializer"
        else:
          field := init["anyInit"]["name"]
          value := (inner init)[0]
          if value["kind"] == "CXXConstructExpr":
            // Construct the embedded object in its own storage.
            construct-into "&self->$field" (c-type value["type"]["qualType"]) value 1
          else if value["kind"] == "CXXDefaultInitExpr":
            // A default member initializer, spelled in the class (another
            // file): its value, written out (default-init-value).
            emit 1 "self->$field = $(default-init-value value);"
          else:
            emit 1 "self->$field = $(wrap (expr value) PREC-ASSIGN);"
    block-contents body-node 1
    lines.add "}"

  /**
  The value of a default member initializer (Clang's CXXDefaultInitExpr
    with the initializer as its child). Its expression is spelled in the
    class definition, usually another file than the function's, so it is
    rendered from the AST's values, never from source text: integer and
    boolean literals, null (a null pointer conversion), and enumerators,
    named and checked through the constant table like any constant (by
    their declared name, in the class's scope). Anything else is an error.
  */
  default-init-value node/Map -> string:
    kids := inner node
    if kids.is-empty: fail "$(where node): a default member initializer without its expression (Clang too old?)"
    value := strip-parens kids[0]
    while value["kind"] == "ImplicitCastExpr" or value["kind"] == "ConstantExpr":
      if value["kind"] == "ImplicitCastExpr" and value["castKind"] == "NullToPointer": return "0"
      if value["kind"] == "ImplicitCastExpr" and not (["IntegralCast", "NoOp", "LValueToRValue"].contains value["castKind"]):
        fail "$(where node): default member initializer with a $value["castKind"] conversion"
      value = strip-parens (inner value)[0]
    if value["kind"] == "CXXBoolLiteralExpr": return value["value"] ? "true" : "false"
    if value["kind"] == "IntegerLiteral": return "$value["value"]"
    if value["kind"] == "UnaryOperator" and value["opcode"] == "-" and (strip-parens (inner value)[0])["kind"] == "IntegerLiteral":
      // A negative literal (`problematic_class_id_ = -1`).
      return "-$((strip-parens (inner value)[0])["value"])"
    if value["kind"] == "CXXNullPtrLiteralExpr": return "0"
    if value["kind"] == "DeclRefExpr" and value["referencedDecl"]["kind"] == "EnumConstantDecl":
      name := value["referencedDecl"]["name"]
      rendered := (cls and constants.values.contains "$(cls)_$name") ? "$(cls)_$name" : name
      if not constants.values.contains rendered:
        uses["missing:$rendered"] = "$(where node): $name ($rendered)"
        return rendered
      use := ConstantUse cxx-cls name rendered true
      uses[use.key] = use
      return rendered
    fail "$(where node): default member initializer $value["kind"] not supported"
    unreachable

/** Replaces the identifier $name (whole words only) in $text. */
replace-word text/string name/string by/string -> string:
  out := []
  i := 0
  while true:
    j := text.index-of name i
    if j < 0: break
    before-ok := j == 0 or not (is-ident-char (text.at --raw j - 1))
    after := j + name.size
    after-ok := after >= text.size or not (is-ident-char (text.at --raw after))
    out.add text[i..j]
    out.add ((before-ok and after-ok) ? by : name)
    i = after
  out.add text[i..]
  return out.join ""

/** `T name`, without a space after a `*`. */
declarator type/string name/string -> string:
  // Fixed-size local byte arrays retain their bound, including for sizeof.
  if ((type.starts-with "uint8 [ ") or (type.starts-with "char [ ")) and type.ends-with " ]":
    bracket := type.index-of "["
    element := type[..bracket].trim
    count := type[bracket + 1..type.size - 2].trim
    bound := int.parse count
    return "$element $(name)[$bound]"
  if type.ends-with "*": return "$type$name"
  return "$type $name"

// ---------------------------------------------------------------------------
// One unit: a sidecar and its generated files.

class Prepared:
  section/Section
  renderer/Renderer
  decl/Map
  body/Map
  path/string
  source/string
  trusted/bool
  c-name/string
  closures/List := []  // [Closure, its Renderer] of the lambdas in the function.
  constructor .section .renderer .decl .body .path .source .trusted .c-name:

class Unit:
  sidecar/Sidecar
  repo/string
  cache/AstCache
  constants/Constants
  uses := {:}
  tus := {}  // The translation units the rendered functions come from.

  constructor .sidecar .repo .cache:
    constants = Constants sidecar.constants-path

  base-path -> string:
    p := sidecar.path
    if p.ends-with ".render": p = p[..p.size - 7]
    return p

  c-path -> string: return "$(base-path).gen.c"
  header-path -> string?:
    if not sidecar.header: return null
    return "$(fs.dirname sidecar.path)/$sidecar.header"
  constants-check-path -> string: return "$(base-path).gen.constants.cc"

  banner -> List:
    return [
      "// GENERATED by verified/tools/cxx_render.toit from $(fs.basename sidecar.path): do not edit.",
      "// The C++ functions are rendered from their current sources, the",
      "// annotations come from the sidecar: verified/cxx/annotated/README.md.",
      "",
    ]

  ghost-text r/Prepared lines/List -> string:
    return lines.join "\n"

  // The typedefs named by `@expand-typedef`, as the type they stand for on
  // the target of this rendering (from Clang's AST: a typedef that differs
  // between targets, like `uhalf_word`, cannot be one C typedef).
  expand-typedefs text/string -> string:
    sidecar.expanded.do: | name/string |
      if (replace-word text name "") == text: continue.do  // Not used.
      target-type := cache.signatures.get "typedef:$name"
      if not target-type: fail "@expand-typedef $name: no use of the typedef in the AST resolves it"
      text = replace-word text name target-type
    return text

  prototype r/Prepared -> string:
    ren := r.renderer
    ren.lines = []
    ren.locals = {}
    ren.local-names = {:}
    ren.ghosts.do: | g/Ghost | g.emitted = false
    ren.function r.decl r.body --prototype
    text := expand-typedefs (ren.lines.join "\n")
    ren.ghosts.do: | g/Ghost | g.emitted = false
    ren.locals = {}
    ren.local-names = {:}
    return text

  definition r/Prepared -> string:
    ren := r.renderer
    ren.lines = []
    ren.function r.decl r.body
    leftover := ren.ghosts.filter: not it.emitted
    if not leftover.is-empty:
      fail "$sidecar.path:$r.section.line: annotation not at a statement boundary: $((leftover[0] as Ghost).text)"
    return expand-typedefs (ren.lines.join "\n")

  // The prototype or the definition of a closure's function.
  lambda-text pair/List --prototype/bool=false -> string:
    cl := pair[0] as Closure
    ren := pair[1] as Renderer
    ren.lines = []
    ren.locals = {}
    ren.local-names = {:}
    cl.ghosts.do: | g/Ghost | g.emitted = false
    ren.lambda-function cl --prototype=prototype
    if not prototype:
      leftover := cl.ghosts.filter: not it.emitted
      if not leftover.is-empty:
        fail "$sidecar.path: annotation not at a statement boundary of the lambda $cl.name: $((leftover[0] as Ghost).text)"
    cl.ghosts.do: | g/Ghost | g.emitted = false
    return expand-typedefs (ren.lines.join "\n")

  /**
  Renders the unit for one target. Returns [C text, header text or null].
  */
  render target/string? -> List:
    prepared := []
    sidecar.sections.do: | s/Section |
      if s.kind == "render": prepared.add (prepare s target)
    c := banner
    h := header-path ? banner : null
    if h:
      guard := ((fs.basename header-path).replace --all "." "_").to-ascii-upper
      h.add "#ifndef $guard"
      h.add "#define $guard"
      h.add ""
      c.add "#include \"$sidecar.header\""
      c.add ""
    shared := h or c
    // The closure structs and the closures' functions come first: the
    // template instances' prototypes name the structs.
    closure-prototypes := []
    prepared.do: | r/Prepared |
      r.closures.do: | pair/List |
        cl := pair[0] as Closure
        fields := cl.captures.map: | cap/List | "$(declarator cap[1] cap[0]);"
        closure-prototypes.add "// C++: the lambda at $cl.spelling[11..cl.spelling.size - 1] (the closure rules)"
        closure-prototypes.add "struct $cl.name { $(fields.join " ") };"
        closure-prototypes.add (lambda-text pair --prototype)
        closure-prototypes.add ""
    // One C function per C name: const overloads must render the same.
    seen := {:}
    index := 0
    sidecar.sections.do: | s/Section |
      if s.kind == "verbatim":
        shared.add (s.text.trim --right)
      else if s.kind == "verbatim-c":
        c.add (s.text.trim --right)
      else if s.kind == "prototypes":
        shared.add-all closure-prototypes
        done := {}
        prepared.do: | r/Prepared |
          if not done.contains r.c-name:
            done.add r.c-name
            shared.add "// C++: $r.path $r.section.args[1]$(r.trusted ? " (trusted: contract only)" : "")"
            shared.add (prototype r)
            shared.add ""
        if s.text.trim != "": shared.add (s.text.trim --right)
      else:
        r := prepared[index++] as Prepared
        text := r.trusted ? null : (definition r)
        if seen.contains r.c-name:
          if seen[r.c-name] != text:
            fail "$sidecar.path:$s.line: $r.c-name renders differently from its other overload; give them different names with @overloaded"
        else:
          seen[r.c-name] = text
          r.closures.do: | pair/List |
            cl := pair[0] as Closure
            c.add "// C++: the lambda at $cl.spelling[11..cl.spelling.size - 1] (the closure rules)"
            c.add (lambda-text pair)
            c.add ""
          if text:
            c.add "// C++: $r.path $s.args[1]"
            c.add text
            c.add ""
    if h:
      h.add "#endif"
    missing := uses.keys.filter: it.starts-with "missing:"
    if not missing.is-empty:
      fail "constants not in the constant table: $((missing.map: uses[it]).join "; ")"
    return [(c.join "\n") + "\n", h ? ((h.join "\n") + "\n") : null]

  // Finds the function, checks the sidecar's copy against it.
  prepare s/Section target/string? -> Prepared:
    if s.args.size < 2: fail "$sidecar.path:$s.line: @render FILE QUALIFIED-NAME [tu=FILE] [params=N] [type=T] [trusted]"
    path := s.args[0]
    qname := s.args[1]
    tu := path
    params := -1
    type/string? := null
    trusted := false
    truncating := false
    unsigned-word-conversion := false
    lambda-of/string? := null
    s.args[2..].do: | a/string |
      if a.starts-with "tu=": tu = a[3..]
      else if a.starts-with "params=": params = int.parse a[7..]
      else if a.starts-with "type=": type = a[5..]
      else if a.starts-with "lambda=": lambda-of = a[7..]
      else if a == "trusted": trusted = true
      else if a == "truncating": truncating = true
      else if a == "unsigned-word-conversion": unsigned-word-conversion = true
      else: fail "$sidecar.path:$s.line: unknown option $a"
    // A function template instance with a closure type (the closure rules).
    instance-spelling := lambda-of ? (resolve-lambda tu target path lambda-of) : null
    parts := qname.split "::"
    name := parts.last
    // The class, for a nested one `A::B` the C name `A_B`.
    cls := parts.size >= 3 ? (parts[1..parts.size - 1].join "_") : null
    cxx-cls := parts.size >= 3 ? (parts[1..parts.size - 1].join "::") : null
    tus.add tu
    decls := cache.find tu target qname
    source := (file.read-contents "$repo/$path").to-string
    candidates := []
    decls.do: | d/Map |
      if instance-spelling:
        // The instance of the template with that closure type.
        if d["kind"] == "FunctionTemplateDecl":
          (inner d).do: | f/Map |
            if f["kind"] == "FunctionDecl" and (f["type"]["qualType"].contains instance-spelling):
              bodies := (inner f).filter: it["kind"] == "CompoundStmt"
              if not bodies.is-empty: candidates.add [f, bodies[0]]
        continue.do
      if type and d["kind"] == "FunctionTemplateDecl":
        // Select an instantiated method by its concrete Clang signature.
        (inner d).do: | f/Map |
          if f["kind"] != "CXXMethodDecl": continue.do
          if not ((inner f).any: it["kind"] == "TemplateArgument"): continue.do
          // A typedef can instantiate different primitive types on the two ABIs.
          if not ((type.split "|").contains (f["type"]["qualType"].replace --all " " "")): continue.do
          bodies := (inner f).filter: it["kind"] == "CompoundStmt"
          if not bodies.is-empty: candidates.add [f, bodies[0]]
        continue.do
      if (d.get "out-of-line") == true:
        // An out-of-line definition: `C::name` must be how it is spelled.
        db := begin-offset d
        de := end-offset d
        if cls and not (db and de and de <= source.size and source[db..de].contains "$(parts[parts.size - 2])::$name"):
          continue.do
      if (d.get "name") == name:
        bodies := (inner d).filter: it["kind"] == "CompoundStmt"
        nparams := ((inner d).filter: it["kind"] == "ParmVarDecl").size
        dtype := ((d.get "type" --if-absent=: {:}).get "qualType" --if-absent=: "").replace --all " " ""
        if not bodies.is-empty and (params < 0 or params == nparams) and (not type or type == dtype):
          candidates.add [d, bodies[0]]
    if candidates.size != 1:
      fail "$sidecar.path:$s.line: $(candidates.size) definitions of $qname in $tu (pick one with params=N or type=T)"
    decl := candidates[0][0]
    body-node := candidates[0][1]
    b := begin-offset decl
    e := (end-offset decl) + (end-token-length decl)
    if b == null or e == null or e > source.size:
      fail "$sidecar.path:$s.line: $qname is not in $path"
    real := tokenize source[b..e]
    annotated := tokenize s.text --keep-ghosts
    ghosts := []
    k := 0
    pending := []
    annotated.do: | t/Token |
      if t.ghost:
        pending.add t
      else:
        if k >= real.size or (real[k] as Token).text != t.text:
          report-drift s path source b real annotated k
        anchor := b + (real[k] as Token).offset
        pending.do: ghosts.add (Ghost anchor it.text)
        pending = []
        k++
    if k != real.size: report-drift s path source b real annotated k
    if not pending.is-empty: fail "$sidecar.path:$s.line: annotation after the end of $qname"
    renderer := Renderer sidecar constants source path cls ghosts uses cache.signatures (cache.owners tu target qname)
    renderer.cxx-cls = cxx-cls
    renderer.truncating = truncating
    renderer.unsigned-word-conversion = unsigned-word-conversion
    renderer.decls-of = :: | q/string | cache.find tu target q
    renderer.class-decl = :: | q/string |
      found := (cache.find tu target q).filter: | d/Map | d["kind"] == "CXXRecordDecl" and not (inner d).is-empty
      found.is-empty ? null : found[0]
    if instance-spelling:
      // The instance only calls its closure parameters: no copy escapes.
      ((inner decl).filter: it["kind"] == "ParmVarDecl" and (it["type"]["qualType"].contains "(lambda at ")).do: | p/Map |
        only-called body-node p["id"] null null
    result := Prepared s renderer decl body-node path source trusted (renderer.c-name decl)
    // The lambdas of the function (the closure rules). A trusted function's
    // body is not rendered (only compared with the source): no closures.
    lambdas := []
    if not trusted: collect-lambdas body-node lambdas
    if not lambdas.is-empty:
      if tu != path: fail "$sidecar.path:$s.line: lambdas are supported in the translation unit itself only"
      fname := renderer.c-name decl
      lambdas.size.repeat: | i |
        node := lambdas[i][0] as Map
        statement := lambdas[i][1] as Map
        spelling := "(lambda at $path:$(line-col source (begin-offset node)))"
        lname := "$(fname)_lambda$(i + 1)"
        LAMBDA-NAMES[spelling] = lname
        cl := make-closure node lname "closure$(i + 1)" spelling body-node statement
        // The annotations inside the lambda are the lambda function's.
        lb := begin-offset node
        le := end-offset node
        cl.ghosts = ghosts.filter: | g/Ghost | lb < g.anchor and g.anchor <= le
        ghosts.filter --in-place: | g/Ghost | not (lb < g.anchor and g.anchor <= le)
        lren := Renderer sidecar constants source path cls cl.ghosts uses cache.signatures (cache.owners tu target qname)
        lren.cxx-cls = cxx-cls
        lren.truncating = truncating
        lren.unsigned-word-conversion = unsigned-word-conversion
        lren.decls-of = renderer.decls-of
        lren.class-decl = renderer.class-decl
        cl.captures.do: | cap/List | lren.captures[cap[2]] = "closure->$cap[0]"
        renderer.lambda-locals[node["id"]] = cl.local
        (renderer.lambda-at.get statement["id"] --init=: []).add cl
        result.closures.add [cl, lren]
    return result

  /**
  The closure of the LambdaExpr $node (the closure rules), with the checks
    that make a copy of each captured value what the C++ reference is.
  */
  make-closure node/Map name/string local/string spelling/string body/Map statement/Map -> Closure:
    kids := inner node
    record := kids[0]
    lambda-body := kids.last
    if record["kind"] != "CXXRecordDecl" or lambda-body["kind"] != "CompoundStmt": fail "$spelling: unexpected lambda shape"
    methods := (inner record).filter: it["kind"] == "CXXMethodDecl" and it["name"] == "operator()"
    if methods.size != 1: fail "$spelling: a generic lambda is not supported"
    method := methods[0]
    if not ((inner method).filter: it["kind"] == "ParmVarDecl").is-empty: fail "$spelling: a lambda with parameters is not supported"
    result-type := lambda-result-type method["type"]["qualType"]
    fields := (inner record).filter: it["kind"] == "FieldDecl"
    inits := kids[1..kids.size - 1]
    if fields.size != inits.size: fail "$spelling: captures and fields differ"
    captures := []
    ids := {}
    inits.size.repeat: | i |
      init := inits[i]
      by-ref := fields[i]["type"]["qualType"].ends-with "&"
      ref := init
      if not by-ref and ref["kind"] == "ImplicitCastExpr" and ref["castKind"] == "LValueToRValue": ref = (inner ref)[0]
      if ref["kind"] != "DeclRefExpr": fail "$spelling: capture of a $ref["kind"] (only locals and parameters, no `this`, no objects by copy)"
      decl := ref["referencedDecl"]
      if decl["kind"] != "VarDecl" and decl["kind"] != "ParmVarDecl": fail "$spelling: capture of a $decl["kind"]"
      if decl["type"]["qualType"].contains "&": fail "$spelling: capture of the reference $decl["name"]"
      captures.add [decl["name"], c-type ref["type"]["qualType"], decl["id"]]
      ids.add decl["id"]
    // The lambda only reads its captures; the enclosing function only reads
    // and assigns them (never takes their address or binds a reference);
    // the statement that creates the lambda only reads them.
    check-uses lambda-body ids null "the lambda $spelling"
    check-uses body ids null "the enclosing function" --writes --skip-lambdas
    check-uses statement ids null "the statement creating $spelling" --skip-lambdas
    // The lambda is an argument of a call: only temporaries and the move
    // into the by-value parameter between them.
    if not (is-call-argument statement node): fail "$spelling: a lambda that is not the argument of a call (it must not outlive the statement)"
    return Closure name spelling node lambda-body captures local result-type

  // Whether the LambdaExpr $lambda is an argument of a call in $node, with
  // only MaterializeTemporaryExpr, CXXConstructExpr (the closure's move),
  // CXXBindTemporaryExpr and no-op conversions in between.
  is-call-argument node lambda/Map -> bool:
    if node is List:
      (node as List).do: if is-call-argument it lambda: return true
      return false
    if node is not Map: return false
    m := node as Map
    if (m.get "kind") == "CallExpr":
      (inner m)[1..].do: | a/Map |
        while true:
          k := a["kind"]
          if k == "MaterializeTemporaryExpr" or k == "CXXBindTemporaryExpr" or (k == "CXXConstructExpr" and (inner a).size == 1)
              or (k == "ImplicitCastExpr" and a["castKind"] == "NoOp"):
            a = (inner a)[0]
          else:
            break
        if a["id"] == lambda["id"]: return true
    return is-call-argument (inner m) lambda

  /**
  The closure type of the lambda $spec (`ENCLOSING` or `ENCLOSING#K`, K
    from 1 in source order) of a function in $path: registers its struct
    name and returns Clang's spelling of the type.
  */
  resolve-lambda tu/string target/string? path/string spec/string -> string:
    if tu != path: fail "lambda=: the template and the lambda must be in the translation unit itself"
    hash := spec.index-of "#"
    enclosing := hash < 0 ? spec : spec[..hash]
    k := hash < 0 ? 0 : (int.parse spec[hash + 1..])
    found := (cache.find tu target enclosing).filter: | d/Map | not ((inner d).filter: it["kind"] == "CompoundStmt").is-empty
    if found.size != 1: fail "lambda=$spec: $(found.size) definitions of $enclosing"
    body := ((inner found[0]).filter: it["kind"] == "CompoundStmt")[0]
    lambdas := []
    collect-lambdas body lambdas
    if k == 0 and lambdas.size != 1: fail "lambda=$spec: $enclosing has $(lambdas.size) lambdas (name one: lambda=$enclosing#K)"
    index := k == 0 ? 0 : k - 1
    if index < 0 or index >= lambdas.size: fail "lambda=$spec: no such lambda"
    source := (file.read-contents "$repo/$path").to-string
    spelling := "(lambda at $path:$(line-col source (begin-offset lambdas[index][0])))"
    parts := enclosing.split "::"
    if parts[0] == "toit": parts = parts[1..]
    LAMBDA-NAMES[spelling] = "$(parts.join "_")_lambda$(index + 1)"
    return spelling

  report-drift s/Section path/string source/string base/int real/List annotated/List k/int:
    plain := annotated.filter: not it.ghost
    have := k < real.size ? (real[k] as Token) : null
    want := k < plain.size ? (plain[k] as Token).text : "<end>"
    at := have ? "$path:$(line-of source base + have.offset)" : "$path (end of the function)"
    context := []
    for i := (max 0 k - 3); i < (min real.size k + 4); i++:
      context.add (real[i] as Token).text
    fail "DRIFT: $sidecar.path:$s.line ($s.args[1]): the C++ has `$(have ? have.text : "<end>")` at $at where the sidecar has `$want` (C++ tokens: $(context.join " ")); update the sidecar's copy and re-check its annotations"

  // The static_asserts that check every constant use against the C++.
  constants-check -> string:
    out := banner
    out.add "// Each constant the rendering uses, with the value of the model's"
    out.add "// constant table, evaluated by the C++ compiler at the place of use."
    out.add "#include <stdint.h>"
    out.add "#include <type_traits>"
    out.add "#include <top.h>"
    out.add "#include <objects.h>"
    // The translation units of the rendered functions: constants such as
    // the message tags are defined in them.
    // (A unit outside src/, the translator's self-test, is next to its sidecar.)
    tus.do: out.add ((it.starts-with "src/") ? "#include <$(it[4..])>" : "#include \"$(fs.basename it)\"")
    out.add "namespace toit {"
    out.add "template <typename A, typename B> struct vf_same {"
    out.add "  static const bool value = std::is_same<typename std::decay<A>::type, typename std::decay<B>::type>::value;"
    out.add "};"
    i := 0
    keys := uses.keys.sort
    keys.do: | key |
      u := uses[key] as ConstantUse
      v := constants.values[u.rendered]
      checks := ["static_assert(($u.spelling) == ($v), \"$u.rendered\");"]
      if not u.is-enum:
        checks.add "static_assert(vf_same<decltype($u.spelling), decltype($v)>::value, \"type of $u.rendered\");"
      if u.cls:
        out.add "struct vf_probe_$(i++) : $u.cls { $(checks.join " ") };"
      else:
        checks.do: out.add it
    out.add "}  // namespace toit"
    return (out.join "\n") + "\n"

// ---------------------------------------------------------------------------

main args:
  command := cli.Command "cxx_render"
      --help="Renders VM C++ functions as C for VeriFast and checks the sidecars against the sources."
      --options=[
        cli.Flag "check" --help="Fail if a generated file differs from the committed one.",
        cli.Flag "ast-ready" --help="Use the AST dumps prefetch-ast.sh made, if there.",
        cli.Option "repo" --help="The repository root (default: from the program path).",
        cli.Option "scratch" --help="Directory for the AST dumps." --default="/tmp",
        cli.Option "target" --multi --help="TRIPLE=DIR: also render for this Clang target (e.g. i686-linux-gnu), into DIR.",
      ]
      --rest=[cli.Option "sidecar" --multi --required --help="A .render file."]
      --run=:: run it
  command.run args

run invocation/cli.Invocation:
  check := invocation["check"]
  ast-ready := invocation["ast-ready"]
  repo := invocation["repo"] or (fs.dirname (fs.dirname (fs.dirname system.program-path)))
  annotated-dir := "$repo/verified/cxx/annotated"
  scratch := invocation["scratch"]
  targets := invocation["target"]
  failures := 0
  // All units share one signature table: a C name is one C++ function
  // across the model and every target.
  cache := AstCache repo annotated-dir scratch {:} --ast-ready=ast-ready
  target-caches := {:}
  invocation["sidecar"].do: | path/string |
    exception := catch --trace=(: it is not RenderError) --unwind=(: it is not RenderError):
      sidecar := Sidecar path
      NESTED-TYPES = sidecar.nested-types
      unit := Unit sidecar repo cache
      texts := unit.render null
      // Other targets: the implicit conversions differ (on a 32-bit target
      // an int is a word), so each target gets its own rendering, written
      // under DIR with the sidecar's relative path.
      targets.do: | spec/string |
        eq := spec.index-of "="
        if eq < 0: fail "--target wants TRIPLE=DIR, not $spec"
        t := spec[..eq]
        dir := spec[eq + 1..]
        target-cache := target-caches.get t --init=: AstCache repo annotated-dir scratch {:} --ast-ready=ast-ready
        other-unit := Unit sidecar repo target-cache
        other := other-unit.render t
        out-c := "$dir/$other-unit.c-path"
        directory.mkdir --recursive (fs.dirname out-c)
        file.write-contents other[0] --path=out-c
        if other[1]: file.write-contents other[1] --path="$dir/$other-unit.header-path"
      outputs := [[unit.c-path, texts[0]]]
      if texts[1]: outputs.add [unit.header-path, texts[1]]
      if sidecar.constants-path: outputs.add [unit.constants-check-path, unit.constants-check]
      outputs.do: | o/List |
        out-path := o[0]
        if check:
          old := file.is-file out-path ? (file.read-contents out-path).to-string : ""
          if old != o[1]:
            fail "$out-path is not what $path generates (run cxx_render.toit without --check and review the diff)"
        else:
          file.write-contents o[1] --path=out-path
      print "ok    $path"
    if exception:
      print "FAIL  $path: $exception"
      failures++
  exit (failures == 0 ? 0 : 1)
