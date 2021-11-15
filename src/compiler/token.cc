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

#include "token.h"

namespace toit {
namespace compiler {

Precedence Token::precedence_[] = {
#define T(n, s, p) p,
TOKENS(T)
#undef T
};

const char* Token::syntax_[] = {
#define T(n, s, p) s,
TOKENS(T)
#undef T
};

#define I(n) const Symbol Symbols:: n = Symbol::synthetic(#n);
#define IN(n, s) const Symbol Symbols:: n = Symbol::synthetic(s);
IDENTIFIERS(I, IN)
#undef IN
#undef I

#define E(n, lib_name, a) const Symbol Symbols:: n = Symbol::synthetic(#lib_name);
ENTRY_POINTS(E)
#undef E

} // namespace toit::compiler
} // namespace toit
