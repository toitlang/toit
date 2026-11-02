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

#pragma once

#include <sstream>
#include <string>
#include <vector>

#include "../top.h"

namespace toit {
namespace compiler {

inline void append(std::ostream&) {}

template<typename T, typename... Rest>
void append(std::ostream& out, const T& first, const Rest&... rest) {
  out << first;
  append(out, rest...);
}

// Concatenates strings and numbers.
template<typename... Parts>
std::string cat(const Parts&... parts) {
  std::ostringstream out;
  append(out, parts...);
  return out.str();
}

// Expressions in the generated code.
inline std::string stack_at(int index) { return cat("STACK_AT(", index, ")"); }
inline std::string smi(word value) { return cat("native_smi(", value, ")"); }
inline std::string field_of(const std::string& object, int index) { return cat("native_field(", object, ", ", index, ")"); }
inline std::string address_of(const std::string& label) { return "NATIVE_ADDRESS(" + label + ")"; }
inline std::string return_address(const std::string& label) { return "NATIVE_OBJECT(&" + label + ")"; }
inline std::string boolean(const std::string& condition) { return "NATIVE_BOOLEAN(" + condition + ")"; }

// Writes a line of generated code at the given column. Long lines are broken
// after the least nested comma or operator that fits, and the rest is aligned
// with the opening parenthesis around it.
static const int COLUMN_LIMIT = 100;

inline void write_wrapped(std::ostream& out, std::string text, int column) {
  while (column + static_cast<int>(text.size()) > COLUMN_LIMIT) {
    std::vector<int> parentheses;
    int best_end = -1;
    int best_depth = 0;
    int best_column = 0;
    for (int i = 0; column + i < COLUMN_LIMIT && i < static_cast<int>(text.size()); i++) {
      char ch = text[i];
      if (ch == '(') parentheses.push_back(i);
      if (ch == ')' && !parentheses.empty()) parentheses.pop_back();
      bool is_comma = ch == ',' && text[i + 1] == ' ';
      bool is_and = text.compare(i, 4, " && ") == 0;
      if (!is_comma && !is_and) continue;
      int depth = parentheses.size();
      if (best_end >= 0 && depth > best_depth) continue;
      best_end = i + (is_and ? 3 : 1);
      best_depth = depth;
      best_column = parentheses.empty() ? column + 4 : column + parentheses.back() + 1;
    }
    if (best_end < 0) break;
    out << text.substr(0, best_end) << "\n" << std::string(best_column, ' ');
    text = text.substr(best_end + 1);
    column = best_column;
  }
  out << text;
}

// Writes C++ code that looks like it has been through a code formatter.
class NativeCodeWriter {
 protected:
  std::stringstream out_;

  // Writing generated code. Everything goes through line, which keeps track of
  // the indentation, so the blocks can nest without knowing where they end up.
  int indentation_ = 0;
  void line(const std::string& text) {
    if (!text.empty()) {
      // Namespaces don't indent what's in them.
      bool is_namespace = text.rfind("namespace", 0) == 0 || text.rfind("}  // namespace", 0) == 0;
      if (text[0] == '}' && !is_namespace) indentation_--;
      out_ << std::string(indentation_ * 2, ' ');
      write_wrapped(out_, text, indentation_ * 2);
      if (text.back() == '{' && !is_namespace) indentation_++;
    }
    out_ << "\n";
  }

  // The entries of initializer lists are indented by the width of a continuation.
  void entry(const std::string& text) { line("  " + text + ","); }

  template<typename Body>
  void block(const std::string& header, Body body) {
    line(header + " {");
    body();
    line("}");
  }
  template<typename Body>
  void function(const std::string& name, Body body) {
    std::string header = "static void " + name + "(NATIVE_PARAMS)";
    std::stringstream code;
    out_.swap(code);
    indentation_++;
    body();
    indentation_--;
    out_.swap(code);
    std::string text = code.str();
    bool is_single_line = text.find('\n') == text.size() - 1;
    std::string statement = is_single_line ? text.substr(2, text.size() - 3) : "";
    if (is_single_line && header.size() + statement.size() + 5 <= COLUMN_LIMIT) {
      line(header + " { " + statement + " }");
    } else {
      line(header + " {");
      out_ << text;
      line("}");
    }
    line("");
  }
  template<typename Body> void scope(Body body) {
    line("{");
    body();
    line("}");
  }
  template<typename Body> void if_(const std::string& condition, Body body) { block("if (" + condition + ")", body); }
  template<typename Body> void if_likely(const std::string& condition, Body body) { if_("NATIVE_LIKELY(" + condition + ")", body); }
  template<typename Body> void if_unlikely(const std::string& condition, Body body) { if_("NATIVE_UNLIKELY(" + condition + ")", body); }
};

}  // namespace compiler
}  // namespace toit
