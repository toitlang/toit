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

#include "../top.h"

#include <string.h>

#include "symbol.h"
#include "token.h"

#include "../utils.h"

namespace toit {
namespace compiler {

Symbol Symbol::synthetic(const uint8* from, const uint8* to) {
  int n = to - from;
  char* s = unvoid_cast<char*>(malloc(n + 1));
  strncpy(s, char_cast(from), n);
  s[n] = '\0';

  return Symbol::synthetic(s);
}

Symbol Symbol::synthetic(const std::string& str) {
  int n = static_cast<int>(str.size());
  char* s = unvoid_cast<char*>(malloc(n + 1));
  strncpy(s, str.c_str(), n);
  s[n] = '\0';

  return Symbol::synthetic(s);
}

Symbol Symbol::for_invoke(Opcode opcode) {
  switch (opcode) {
    case INVOKE_EQ: return Token::symbol(Token::EQ);
    case INVOKE_LT: return Token::symbol(Token::LT);
    case INVOKE_GT: return Token::symbol(Token::GT);
    case INVOKE_LTE: return Token::symbol(Token::LTE);
    case INVOKE_GTE: return Token::symbol(Token::GTE);
    case INVOKE_BIT_OR: return Token::symbol(Token::BIT_OR);
    case INVOKE_BIT_XOR: return Token::symbol(Token::BIT_XOR);
    case INVOKE_BIT_AND: return Token::symbol(Token::BIT_AND);
    case INVOKE_BIT_SHL: return Token::symbol(Token::BIT_SHL);
    case INVOKE_BIT_SHR: return Token::symbol(Token::BIT_SHR);
    case INVOKE_BIT_USHR: return Token::symbol(Token::BIT_USHR);
    case INVOKE_ADD: return Token::symbol(Token::ADD);
    case INVOKE_SUB: return Token::symbol(Token::SUB);
    case INVOKE_MUL: return Token::symbol(Token::MUL);
    case INVOKE_DIV: return Token::symbol(Token::DIV);
    case INVOKE_MOD: return Token::symbol(Token::MOD);
    case INVOKE_AT: return Symbols::index;
    case INVOKE_AT_PUT: return Symbols::index_put;
    default: return Symbol::invalid();
  }
}

} // namespace toit::compiler
} // namespace toit
