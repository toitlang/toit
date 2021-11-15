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

#include "symbol.h"
#include "sources.h"
#include "../entry_points.h"

namespace toit {
namespace compiler {

enum Precedence {
  PRECEDENCE_NONE,
  PRECEDENCE_CONDITIONAL,
  PRECEDENCE_OR,
  PRECEDENCE_AND,
  PRECEDENCE_NOT,
  PRECEDENCE_CALL,
  PRECEDENCE_ASSIGNMENT,
  PRECEDENCE_EQUALITY,
  PRECEDENCE_RELATIONAL,
  PRECEDENCE_BIT_OR,
  PRECEDENCE_BIT_XOR,
  PRECEDENCE_BIT_AND,
  PRECEDENCE_BIT_SHIFT,
  PRECEDENCE_ADDITIVE,
  PRECEDENCE_MULTIPLICATIVE,
  PRECEDENCE_POSTFIX
};

// List of keywords.
#define KEYWORDS(T)                                            \
  T(AS, "as", PRECEDENCE_RELATIONAL)                           \
  T(ABSTRACT, "abstract", PRECEDENCE_NONE)                     \
  T(AZZERT, "assert", PRECEDENCE_NONE)                         \
  T(BREAK, "break", PRECEDENCE_NONE)                           \
  T(CLASS, "class", PRECEDENCE_NONE)                           \
  T(CONTINUE, "continue", PRECEDENCE_NONE)                     \
  T(ELSE, "else", PRECEDENCE_NONE)                             \
  T(FALSE, "false", PRECEDENCE_NONE)                           \
  T(FINALLY, "finally", PRECEDENCE_NONE)                       \
  T(FOR, "for", PRECEDENCE_NONE)                               \
  T(IF, "if", PRECEDENCE_NONE)                                 \
  T(IMPORT, "import", PRECEDENCE_NONE)                         \
  T(EXPORT, "export", PRECEDENCE_NONE)                         \
  T(NULL_, "null", PRECEDENCE_NONE)                            \
  T(RETURN, "return", PRECEDENCE_NONE)                         \
  T(STATIC, "static", PRECEDENCE_NONE)                         \
  T(TRUE, "true", PRECEDENCE_NONE)                             \
  T(TRY, "try", PRECEDENCE_NONE)                               \
  T(WHILE, "while", PRECEDENCE_NONE)                           \
  T(LOGICAL_OR, "or", PRECEDENCE_OR)                           \
  T(LOGICAL_AND, "and", PRECEDENCE_AND)                        \
  T(NOT, "not", PRECEDENCE_NOT)                                \

// List of tokens.
#define TOKENS(T)                                                        \
  T(EOS, "<eos>", PRECEDENCE_NONE)                                       \
  T(ILLEGAL, "<illegal>", PRECEDENCE_NONE)                               \
  T(INDENT, "<indent>", PRECEDENCE_NONE)                                 \
  T(DEDENT, "<dedent>", PRECEDENCE_NONE)                                 \
  T(NEWLINE, "<newline>", PRECEDENCE_NONE)                               \
                                                                         \
  T(INTEGER, "<integer>", PRECEDENCE_NONE)                               \
  T(DOUBLE, "<double>", PRECEDENCE_NONE)                                 \
  T(IDENTIFIER, "<identifier>", PRECEDENCE_NONE)                         \
  T(CHARACTER, "<character>", PRECEDENCE_NONE)                           \
  T(STRING, "<string>", PRECEDENCE_NONE)                                 \
  T(STRING_PART, "<string part>", PRECEDENCE_NONE)                       \
  T(STRING_END, "<string end>", PRECEDENCE_NONE)                         \
  T(STRING_MULTI_LINE, "<string multi line>", PRECEDENCE_NONE)           \
  T(STRING_PART_MULTI_LINE, "<string part multi line>", PRECEDENCE_NONE) \
  T(STRING_END_MULTI_LINE, "<string end multi line>", PRECEDENCE_NONE)   \
  T(COMMENT_SINGLE_LINE, "<comment single line>", PRECEDENCE_NONE)       \
  T(COMMENT_MULTI_LINE, "<comment multi line>", PRECEDENCE_NONE)         \
  T(COMMA, ",", PRECEDENCE_NONE)                                         \
  T(RARROW, "->", PRECEDENCE_NONE)                                       \
  T(PRIMITIVE, "#primitive", PRECEDENCE_NONE)                            \
                                                                         \
  T(LSHARP_BRACK, "#[", PRECEDENCE_NONE)                                 \
  T(SLICE, "..", PRECEDENCE_NONE)                                        \
                                                                         \
  T(LPAREN, "(", PRECEDENCE_NONE)                                        \
  T(RPAREN, ")", PRECEDENCE_NONE)                                        \
  T(LBRACK, "[", PRECEDENCE_POSTFIX)                                     \
  T(RBRACK, "]", PRECEDENCE_NONE)                                        \
  T(LBRACE, "{", PRECEDENCE_NONE)                                        \
  T(RBRACE, "}", PRECEDENCE_NONE)                                        \
  T(COLON, ":", PRECEDENCE_NONE)                                         \
  T(DOUBLE_COLON, "::", PRECEDENCE_NONE)                                 \
  T(SEMICOLON, ";", PRECEDENCE_NONE)                                     \
  T(PERIOD, ".", PRECEDENCE_POSTFIX)                                     \
                                                                         \
  T(BIT_NOT, "~", PRECEDENCE_NONE)                                       \
  T(INCREMENT, "++", PRECEDENCE_POSTFIX)                                 \
  T(DECREMENT, "--", PRECEDENCE_POSTFIX)                                 \
                                                                         \
  /* Assignment operators. */                                            \
  T(ASSIGN, "=", PRECEDENCE_ASSIGNMENT)                                  \
  T(DEFINE, ":=", PRECEDENCE_ASSIGNMENT)                                 \
  T(DEFINE_FINAL, "::=", PRECEDENCE_ASSIGNMENT)                          \
                                                                         \
  T(ASSIGN_ADD, "+=", PRECEDENCE_ASSIGNMENT)                             \
  T(ASSIGN_SUB, "-=", PRECEDENCE_ASSIGNMENT)                             \
  T(ASSIGN_MUL, "*=", PRECEDENCE_ASSIGNMENT)                             \
  T(ASSIGN_DIV, "/=", PRECEDENCE_ASSIGNMENT)                             \
  T(ASSIGN_MOD, "%=", PRECEDENCE_ASSIGNMENT)                             \
                                                                         \
  T(ASSIGN_BIT_OR,  "|=", PRECEDENCE_ASSIGNMENT)                         \
  T(ASSIGN_BIT_XOR, "^=", PRECEDENCE_ASSIGNMENT)                         \
  T(ASSIGN_BIT_AND, "&=", PRECEDENCE_ASSIGNMENT)                         \
  T(ASSIGN_BIT_SHL, "<<=", PRECEDENCE_ASSIGNMENT)                        \
  T(ASSIGN_BIT_SHR, ">>=", PRECEDENCE_ASSIGNMENT)                        \
  T(ASSIGN_BIT_USHR, ">>>=", PRECEDENCE_ASSIGNMENT)                      \
                                                                         \
  /* Special operators. */                                               \
  T(CONDITIONAL, "?", PRECEDENCE_CONDITIONAL)                            \
                                                                         \
  /* Binary operators. */                                                \
  T(NE, "!=", PRECEDENCE_EQUALITY)                                       \
  T(EQ, "==", PRECEDENCE_EQUALITY)                                       \
  T(LT, "<", PRECEDENCE_RELATIONAL)                                      \
  T(GT, ">", PRECEDENCE_RELATIONAL)                                      \
  T(LTE, "<=", PRECEDENCE_RELATIONAL)                                    \
  T(GTE, ">=", PRECEDENCE_RELATIONAL)                                    \
  T(IS, "is", PRECEDENCE_RELATIONAL)                                     \
  T(IS_NOT, "is not", PRECEDENCE_RELATIONAL)                             \
  T(BIT_OR, "|", PRECEDENCE_BIT_OR)                                      \
  T(BIT_XOR, "^", PRECEDENCE_BIT_XOR)                                    \
  T(BIT_AND, "&", PRECEDENCE_BIT_AND)                                    \
  T(BIT_SHL, "<<", PRECEDENCE_BIT_SHIFT)                                 \
  T(BIT_SHR, ">>", PRECEDENCE_BIT_SHIFT)                                 \
  T(BIT_USHR, ">>>", PRECEDENCE_BIT_SHIFT)                               \
  T(ADD, "+", PRECEDENCE_ADDITIVE)                                       \
  T(SUB, "-", PRECEDENCE_ADDITIVE)                                       \
  T(MUL, "*", PRECEDENCE_MULTIPLICATIVE)                                 \
  T(DIV, "/", PRECEDENCE_MULTIPLICATIVE)                                 \
  T(MOD, "%", PRECEDENCE_MULTIPLICATIVE)                                 \
                                                                         \
  KEYWORDS(T)                                                            \

// List of predefined identifiers.
#define IDENTIFIERS(I, IN)                                     \
  I(__throw__)                                                 \
  I(__halt__)                                                  \
  I(__exit__)                                                  \
  I(__yield__)                                                 \
  I(__deep_sleep__)                                            \
  I(__invoke_lambda__)                                         \
  I(__invoke_initializer__)                                    \
  I(__store_global_with_id__)                                  \
  I(Object)                                                    \
  I(Interface_)                                                \
  I(Task_)                                                     \
  I(LargeArray_)                                               \
  I(Class_)                                                    \
  I(Stack_)                                                    \
  I(__Monitor__)                                               \
  I(lambda_)                                                   \
  I(interpolate_strings_)                                      \
  I(simple_interpolate_strings_)                               \
  I(stringify)                                                 \
  I(lookup_failure_)                                           \
  I(as_check_failure_)                                         \
  I(primitive_lookup_failure_)                                 \
  I(uninitialized_global_failure_)                             \
  I(program_failure_)                                          \
  I(locked_)                                                   \
  IN(throw_, "throw")                                          \
  IN(rethrow, "rethrow")                                       \
  IN(stack_, "<stack>")                                        \
  I(Array_)                                                    \
  I(Box_)                                                      \
  I(LazyInitializer_)                                          \
  I(SmallArray_)                                               \
  I(ByteArray)                                                 \
  I(ByteArray_)                                                \
  I(CowByteArray_)                                             \
  I(ByteArraySlice_)                                           \
  I(List_)                                                     \
  I(Tombstone_)                                                \
  I(create_array_)                                             \
  I(create_byte_array_)                                        \
  I(create_list_literal_from_array_)                           \
  I(create_cow_byte_array_)                                    \
  I(Set)                                                       \
  I(Map)                                                       \
  I(it)                                                        \
  I(call)                                                      \
  I(identical)                                                 \
  I(no)                                                        \
  I(add)                                                       \
  I(show)                                                      \
  IN(one, "1")                                                 \
  I(main)                                                      \
  I(String)                                                    \
  I(String_)                                                   \
  I(StringSlice_)                                              \
  I(LargeInteger_)                                             \
  I(False_)                                                    \
  I(Null_)                                                     \
  I(SmallInteger_)                                             \
  I(True_)                                                     \
  I(monitor)                                                   \
  IN(interface_, "interface")                                  \
  I(extends)                                                   \
  I(implements)                                                \
  I(none)                                                      \
  I(any)                                                       \
  IN(empty_string, "")                                         \
  I(assert_)                                                   \
  I(intrinsics)                                                \
  I(array_do)                                                  \
  I(hash_find)                                                 \
  I(hash_do)                                                   \
  I(smi_repeat)                                                \
  I(value_)                                                    \
  IN(index, "[]")                                              \
  IN(index_put, "[]=")                                         \
  IN(index_slice, "[..]")                                      \
  IN(op, "operator")                                           \
  IN(int_, "int")                                              \
  IN(bool_, "bool")                                            \
  IN(float_, "float")                                          \
  I(string)                                                    \
  IN(this_, "this")                                            \
  I(super)                                                     \
  I(constructor)                                               \
  I(unreachable)                                               \
  I(_)                                                         \
  I(debug_string)                                              \
  I(dispatch_debug_string)                                     \
  I(run_global_initializer_)                                   \
  I(from)                                                      \
  I(to)                                                        \


class Token {
 public:
  enum Kind {
#define T(n, s, p) n,
TOKENS(T)
#undef T
    INVALID
  };

  static Precedence precedence(Kind kind) { return precedence_[kind]; }
  static Symbol symbol(Kind kind) { return Symbol::synthetic(syntax_[kind]); }

 private:
  static Precedence precedence_[];
  static const char* syntax_[];
};

class Symbols {
 public:
#define I(n) static const Symbol n;
#define IN(n, s) static const Symbol n;
IDENTIFIERS(I, IN)
#undef IN
#undef I

#define E(n, lib_name, a) static const Symbol n;
ENTRY_POINTS(E)
#undef E

  static const int reserved_symbol_count = 4;
  static bool is_reserved(Symbol name) {
    return name == Symbols::this_ ||
        name == Symbols::super ||
        name == Symbols::constructor ||
        name == Symbols::_;
  }
};


} // namespace toit::compiler
} // namespace toit
