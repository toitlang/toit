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

#include <functional>
#include <stddef.h>
#include <string>

#include "list.h"
#include "../bytecodes.h"

namespace toit {
namespace compiler {

class Symbol {
 public:
  constexpr static Symbol invalid() { return Symbol(null); }

  // When using synthetic variables, ensure that the `name` variable is
  // pointing to the same memory-location, as otherwise resolution won't work.
  //
  // The given [str] is retained, and must stay valid.
  constexpr static Symbol synthetic(const char* str) { return Symbol(str); }

  // Creates a Symbol consisting of the string [from] to [to]. Makes a copy of
  // the characters.
  static Symbol synthetic(const uint8* from, const uint8* to);
  static Symbol synthetic(const std::string& str);

  static Symbol fresh() { return fresh(unsigned_cast("")); }
  static Symbol fresh(Symbol name) { return fresh(unsigned_cast(name.c_str())); }
  static Symbol fresh(const uint8* name) { return synthetic(strdup(char_cast(name))); }

  static Symbol for_invoke(Opcode opcode);

  const char* c_str() const {
    ASSERT(is_valid());
    // We can't use `"<invalid>"` as `str_`, as the constexpr and dynamic string constants
    // are not necessarily the same.
    // Returning `<invalid>` here makes the compiler more stable. We should generally not
    // need it, but when it happens we don't crash as easily.
    if (!is_valid()) return "<invalid>";
    return str_;
  }

  // Tells weather this symbol is a private identifier, ends with '_'.
  bool is_private_identifier() {
    if (!is_valid()) return false;
    int len = strlen(str_);
    if (len <= 1) return false;
    return str_[len-1] == '_';
  }

  bool operator==(const Symbol& other) const {
    return str_ == other.str_;
  }

  bool operator!=(const Symbol& other) const {
    return str_ != other.str_;
  }

  bool is_valid() const { return str_ != null; }

  size_t hash() const {
    if (!is_valid()) return 29542603;  // Random number.
    std::hash<const char*> c_str_hash;
    return c_str_hash(c_str());
  }

 private:
  constexpr explicit Symbol(const char* name) : str_(name) { }

  friend class ListBuilder<Symbol>;
  Symbol() { }

  const char* str_;
};

} // namespace toit::compiler
} // namespace toit

namespace std {
  template <> struct hash<::toit::compiler::Symbol> {
    std::size_t operator()(const ::toit::compiler::Symbol& symbol) const {
      return symbol.hash();
    }
  };
  template <> struct less<::toit::compiler::Symbol> {
    bool operator()(const ::toit::compiler::Symbol& symbol, const ::toit::compiler::Symbol& other) const {
      std::less<const char*> c_str_less;
      return c_str_less(symbol.c_str(), other.c_str());
    }
  };
}  // namespace std
