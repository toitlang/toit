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

#pragma once

#include "token.h"
#include "trie.h"

namespace toit {
namespace compiler {

class SymbolCanonicalizer {
 public:
  struct TokenSymbol {
    Token::Kind kind;
    Symbol symbol;
  };

  SymbolCanonicalizer();

  // Returns a TokenSymbol.
  //
  // Keywords have their tokens set to the corresponding token.
  // All other identifiers are Token::IDENTIFIER.
  TokenSymbol canonicalize_identifier(const uint8* from, const uint8* to);
  Symbol canonicalize_number(const uint8* from, const uint8* to);

 private:
  // Identifiers, keywords, and numbers are canonicalized
  // through two separate trie structures.
  Trie identifier_trie_;
  Trie number_trie_;

  // Copy of canonicalized syntax for identifiers and numbers.
  ListBuilder<const uint8*> syntax_;
};

} // namespace toit::compiler
} // namespace toit
