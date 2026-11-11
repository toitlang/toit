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
* `@render FILE QUALIFIED-NAME [tu=FILE] [params=N] [type=T] [trusted] [truncating]`:
  the section holds the annotated copy of the function. `trusted`: only
  the prototype and contract are emitted (the body is not verified, but
  still compared with the sources). `type=T` picks an overload by its
  Clang type with the spaces removed.
Configuration: `@raii CLASS`, `@overloaded CLASS::NAME`, `@expand-typedef NAME`
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
    else if directive == "overloaded":
      overloaded.add words[1]
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
    pieces.size.repeat: | i |
      top := pieces[i][0]
      if path.size == 1 and top == name:
        result.add (parse_ tu target filter i)
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
// Types.

/**
Normalizes a C++ type spelling to C: drops `toit::`, `const`, `volatile`,
  `class`/`struct` keywords stay, references are rejected.
*/
c-type t/string -> string:
  t = t.replace --all "toit::" ""
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
  decls-of/Lambda? := null  // Qualified name -> its declarations (in the class and out of line).
  ghosts/List
  uses/Map            // key -> ConstantUse, shared by the unit.
  signatures/Map      // C name -> parameter types, shared by all units.
  lines := []
  locals := {}
  reference-params := {}  // Parameters of a reference type (pointers in C).
  hoisted := {}  // The ids of the locals declared at the start of their block.
  // A stack of scopes, each a list of [class, name] of locals with a
  // destructor.
  raii-scopes := []
  result-type/string := "void"
  temp-count := 0

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

  // --- Names.

  // $param-types: the C types of the parameters. An overloaded member gets
  // them in its name (`C_m__T1_T2`, `*` as `p`), so that two overloads are
  // never one C function, except const overloads (same parameters).
  mangle-member class-name/string name/string param-types/List -> string:
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

  callee-name node/Map -> string:
    while node["kind"] == "ImplicitCastExpr" or node["kind"] == "ParenExpr":
      node = (inner node)[0]
    if node["kind"] != "DeclRefExpr": fail "$(where node): call of a $node["kind"]"
    ref := node["referencedDecl"]
    name := ref["name"]
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
      c-name = s ? (mangle-spelling s) : name
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
      if cast == "IntegralCast" and truncating and (c-type node["type"]["qualType"]) == "int" and (TRUNCATED.contains (resolve (c-type kids[0]["type"]["qualType"]))):
        // `truncating`: the narrowing conversion of a word to int is the
        // modular one (GCC, Clang, C++20), for code that checks it.
        return Expr "/*@truncating@*/(int)$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
      if cast == "IntegralCast" and (strip-parens kids[0])["kind"] == "IntegerLiteral":
        return expr kids[0]
      if cast == "IntegralToBoolean" or cast == "PointerToBoolean":
        return Expr "$(wrap (expr kids[0]) 10) != 0" 9
      if cast == "NullToPointer":
        return Expr "0" PREC-PRIMARY
      if WRITTEN-CASTS.contains cast:
        return Expr "($(c-type node["type"]["qualType"]))$(wrap (expr kids[0]) PREC-UNARY)" PREC-UNARY
      fail "$(where node): implicit conversion $cast not supported"
    if kind == "CStyleCastExpr" or kind == "CXXStaticCastExpr" or kind == "CXXReinterpretCastExpr" or kind == "CXXFunctionalCastExpr" or kind == "CXXConstCastExpr":
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
    if kind == "DeclRefExpr":
      ref := node["referencedDecl"]
      rk := ref["kind"]
      name := ref["name"]
      if rk == "ParmVarDecl" and reference-params.contains name:
        return Expr "(*$name)" PREC-PRIMARY
      if (rk == "ParmVarDecl" or rk == "VarDecl") and locals.contains name:
        return Expr name PREC-PRIMARY
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
    if kind == "BinaryOperator" or kind == "CompoundAssignOperator":
      op := node["opcode"]
      p := BINARY-PREC.get op --if-absent=: fail "$(where node): operator $op"
      if p == PREC-ASSIGN:
        return Expr "$(wrap (expr kids[0]) PREC-UNARY) $op $(wrap (expr kids[1]) PREC-ASSIGN)" p
      return Expr "$(wrap (expr kids[0]) p) $op $(wrap (expr kids[1]) p + 1)" p
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
      if k["kind"] == "DeclStmt":
        (inner k).do: | d/Map |
          if d["kind"] == "VarDecl":
            init := (inner d).is-empty ? null : (strip-cleanups (inner d)[0])
            if (init and init["kind"] == "CXXConstructExpr") or (address-taken block d["id"]):
              hoisted.add d["id"]
              emit indent "$(declarator (c-type d["type"]["qualType"]) d["name"]);"

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

  // $next: the offset where the statement after $node starts (or the end
  // of the enclosing block), or null when $node is a branch on its own.
  stmt node/Map indent/int next/int?:
    kind := node["kind"]
    kids := inner node
    if kind == "CompoundStmt":
      emit indent "{"
      block-contents node indent + 1
      emit indent "}"
    else if kind == "DeclStmt":
      kids.do: | decl/Map | var-decl decl indent
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
    else if kind == "ForStmt":
      init := kids[0]
      if not is-empty kids[1]: fail "$(where node): for with a condition variable"
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
    else if kind == "WhileStmt":
      if node.get "hasVar": fail "$(where node): while with a condition variable"
      cond := strip-parens kids[0]
      if is-release-assert cond:
        emit indent "// ASSERT($((expr (strip-parens (inner cond)[1])).text)): release build, not evaluated."
        ghosts.do: | g/Ghost |
          if g.anchor > (begin-offset node) and g.anchor <= (end-offset node): g.emitted = true
        return
      emit indent "while ($((expr kids[0]).text))"
      loop-body kids[1] indent
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

  is-release-assert cond/Map -> bool:
    if cond["kind"] != "BinaryOperator" or cond["opcode"] != "&&": return false
    left := strip-parens (inner cond)[0]
    return left["kind"] == "CXXBoolLiteralExpr" and left["value"] == false

  loop-body node/Map indent/int:
    // Annotations anchored at the body's `{` are the loop invariant.
    if node["kind"] == "CompoundStmt":
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

  var-decl-text decl/Map -> string:
    name := decl["name"]
    locals.add name
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
    if init and init["kind"] == "CXXConstructExpr":
      name := decl["name"]
      locals.add name
      type := c-type decl["type"]["qualType"]
      if not hoisted.contains decl["id"]: emit indent "$(declarator type name);"
      construct name type init indent
      if sidecar.raii.contains type: raii-scopes.last.add [type, name]
      return
    if hoisted.contains decl["id"]:
      locals.add decl["name"]
      if init: emit indent "$decl["name"] = $(wrap (expr init) PREC-ASSIGN);"
      return
    emit indent "$(var-decl-text decl);"

  // The constructor call of $init (a CXXConstructExpr or a
  // CXXTemporaryObjectExpr) for the object $name of C type $type.
  construct name/string type/string init/Map indent/int:
    // A non-const reference parameter of the constructor is a pointer.
    ctor-params := fn-param-types-raw init["ctorType"]["qualType"]
    args := []
    (inner init).size.repeat: | i |
      a := (inner init)[i]
      by-ref := i < ctor-params.size and (is-reference ctor-params[i])
      args.add (by-ref ? "&$(wrap (expr a) PREC-UNARY)" : (wrap (expr a) PREC-ASSIGN))
    ctor-name := mangle-member type type (ctor-params.map: c-type it)
    note-signature ctor-name (ctor-params.map: c-type it) init
    emit indent "$ctor-name($((["&$name"] + args).join ", "));"

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
      t := c-type p["type"]["qualType"]
      types.add t
      ps.add (declarator t pname)
    if ps.is-empty: ps.add "void"
    fname := cls ? (mangle-member cls name types) : name
    note-signature fname (params.map: c-type (canonical it["type"])) decl
    result-type = (kind == "CXXConstructorDecl" or kind == "CXXDestructorDecl") ? "void" : (return-type decl["type"]["qualType"])
    return declarator result-type "$fname($(ps.join ", "))"

  c-name decl/Map -> string:
    params := (inner decl).filter: it["kind"] == "ParmVarDecl"
    types := params.map: c-type it["type"]["qualType"]
    return cls ? (mangle-member cls decl["name"] types) : decl["name"]

  function decl/Map body-node/Map --prototype/bool=false:
    sig := signature decl
    lines.add sig + (prototype ? ";" : "")
    // Annotations anchored at the body's `{`: the contract.
    ghosts-up-to (begin-offset body-node) 0
    if prototype: return
    lines.add "{"
    (inner decl).do: | init/Map |
      if init["kind"] == "CXXCtorInitializer":
        field := init["anyInit"]["name"]
        value := inner init
        emit 1 "self->$field = $(wrap (expr value[0]) PREC-ASSIGN);"
    block-contents body-node 1
    lines.add "}"

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
    ren.ghosts.do: | g/Ghost | g.emitted = false
    ren.function r.decl r.body --prototype
    text := expand-typedefs (ren.lines.join "\n")
    ren.ghosts.do: | g/Ghost | g.emitted = false
    ren.locals = {}
    return text

  definition r/Prepared -> string:
    ren := r.renderer
    ren.lines = []
    ren.function r.decl r.body
    leftover := ren.ghosts.filter: not it.emitted
    if not leftover.is-empty:
      fail "$sidecar.path:$r.section.line: annotation not at a statement boundary: $((leftover[0] as Ghost).text)"
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
    // One C function per C name: const overloads must render the same.
    seen := {:}
    index := 0
    sidecar.sections.do: | s/Section |
      if s.kind == "verbatim":
        shared.add (s.text.trim --right)
      else if s.kind == "verbatim-c":
        c.add (s.text.trim --right)
      else if s.kind == "prototypes":
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
    s.args[2..].do: | a/string |
      if a.starts-with "tu=": tu = a[3..]
      else if a.starts-with "params=": params = int.parse a[7..]
      else if a.starts-with "type=": type = a[5..]
      else if a == "trusted": trusted = true
      else if a == "truncating": truncating = true
      else: fail "$sidecar.path:$s.line: unknown option $a"
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
    renderer.decls-of = :: | q/string | cache.find tu target q
    renderer.class-decl = :: | q/string |
      found := (cache.find tu target q).filter: | d/Map | d["kind"] == "CXXRecordDecl" and not (inner d).is-empty
      found.is-empty ? null : found[0]
    return Prepared s renderer decl body-node path source trusted (renderer.c-name decl)

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
