// Copyright (C) 2018 Toitware ApS.
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

#include "symbol_canonicalizer.h"

#include "token.h"

namespace toit {
namespace compiler {

static const Token::Kind keywords[] = {
#define T(n, s, p) Token::n,
KEYWORDS(T)
#undef T
};

static Symbol identifiers[] = {
#define I(n) Symbols:: n,
#define IN(n, s) Symbols:: n,
IDENTIFIERS(I, IN)
#undef IN
#undef I
#define E(n, lib_name, a) Symbols:: n,
ENTRY_POINTS(E)
#undef E
};

SymbolCanonicalizer::SymbolCanonicalizer()
      : identifier_trie_(0), number_trie_(0) {
  for (unsigned i = 0; i < ARRAY_SIZE(keywords); i++) {
    Token::Kind kind = keywords[i];
    const uint8* syntax = unsigned_cast(Token::symbol(kind).c_str());
    Trie* trie = identifier_trie_.get(syntax);
    trie->kind = kind;
    trie->data = Symbol::invalid();
  }
  for (unsigned i = 0; i < ARRAY_SIZE(identifiers); i++) {
    Symbol symbol = identifiers[i];
    const uint8* syntax = unsigned_cast(symbol.c_str());
    Trie* trie = identifier_trie_.get(syntax);
    trie->kind = Token::IDENTIFIER;
    ASSERT(i == static_cast<unsigned>(syntax_.length()));
    syntax_.add(syntax);
    trie->data = symbol;
  }
}

SymbolCanonicalizer::TokenSymbol SymbolCanonicalizer::canonicalize_identifier(const uint8* from, const uint8* to) {
  Trie* trie = identifier_trie_.get(from, to);
  if (trie->kind == 0) {
    trie->kind = Token::IDENTIFIER;
    trie->data = Symbol::synthetic(from, to);
  }
  return {
    .kind = trie->kind,
    .symbol = trie->data,
  };
}

Symbol SymbolCanonicalizer::canonicalize_number(const uint8* from, const uint8* to) {
  Trie* trie = number_trie_.get(from, to);
  if (trie->kind == 0) {
    // We are arbitrarily using 'integer' as token here.
    // It's not important, and only serves as an indication that we have already seen
    // the symbol.
    trie->kind = Token::INTEGER;
    trie->data = Symbol::synthetic(from, to);
  }
  return trie->data;
}

} // namespace toit::compiler
} // namespace toit

