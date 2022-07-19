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

#include "resolver_method.h"

#include <errno.h>
#include <stdarg.h>
#include <functional>
#include <limits.h>
#include <math.h>

#include "lsp/lsp.h"
#include "no_such_method.h"
#include "package.h"
#include "resolver_primitive.h"
#include "set.h"

#include "../interpreter.h"
#include "../flags.h"
#include "../utils.h"
#include "../objects.h"

namespace toit {
namespace compiler {

static int hex(char a) {
  if ('0' <= a && a <= '9') return a - '0';
  if ('A' <= a && a <= 'F') return a - 'A' + 10;
  if ('a' <= a && a <= 'f') return a - 'a' + 10;
  return -1;
}

static void find_min_indentation(const char* content,
                                 bool is_string_start,
                                 int* min_indentation,
                                 bool* contains_newline) {
  int i = 0;
  // The beginning of interpolated parts doesn't count as indentation.
  bool at_newline = is_string_start;
  while (content[i] != '\0') {
    if (at_newline) {
      at_newline = false;
      int line_indentation = 0;
      while (content[i] == ' ') {
        line_indentation++;
        i++;
      }
      // Empty lines are skipped and don't count for indentation purposes.
      // That's not true for `\0` which  serves as indentation hint.
      bool empty_line = content[i] == '\r' || content[i] == '\n';
      if (!empty_line && (*min_indentation == -1 || line_indentation < *min_indentation)) {
        *min_indentation = line_indentation;
      }
      continue;
    }
    if (content[i] == '\n') {
      *contains_newline = true;
      at_newline = true;
    } else if (content[i] == '\r') {
      *contains_newline = true;
      i++;
      if (content[i] == '\n') continue;
      at_newline = true;
    }
    i++;
  }
  if (at_newline) {
    // The string ended at a new line. This doesn't count as "empty_line", and
    // the indentation is thus set to 0.
    // Something like:
    // ```
    //   str := """
    //     foo
    // """
    // ```
    *min_indentation = 0;
  }
}

static const char* convert_string_content(const char* content,
                                          int min_indentation,
                                          bool skip_leading,
                                          bool is_multiline,
                                          int* length) {
  // strpbrk(s, accept): locates the first occurrence in the string s of any
  //   of the bytes in the string accept.
  if (min_indentation == 0 && strpbrk(content, "\\\n\r") == null) {
    *length = strlen(content);
    return content;
  }
  char* result = unvoid_cast<char*>(malloc(strlen(content) + 1));
  bool at_newline = skip_leading;
  int src = 0;
  int dst = 0;
  if (skip_leading) {
    // Skip over leading newline, even if it is preceded by spaces.
    int i = 0;
    while (content[i] == ' ') i++;
    if (content[i] == '\r' || content[i] == '\n') {
      if (content[i] == '\r' && content[i + 1] == '\n') i++;
      src = i + 1;
    }
  }
  char peek = content[src++];
  while (peek != 0) {
    if (at_newline) {
      at_newline = false;
      for (int i = 0; i < min_indentation; i++) {
        if (peek == ' ') {
          peek = content[src++];
        } else {
          break;
        }
      }
      continue;
    }
    if (peek == '\\') {
      peek = content[src++];
      switch (peek) {
        case '0':  result[dst++] = '\0'; break;
        case 'a':  result[dst++] = '\a'; break;  // Alert (Beep, Bell)
        case 'b':  result[dst++] = '\b'; break;  // Backspace
        case 'f':  result[dst++] = '\f'; break;  // Form feed
        case 'n':  result[dst++] = '\n'; break;  // New line
        case 'r':  result[dst++] = '\r'; break;  // Carriage return
        case 't':  result[dst++] = '\t'; break;  // Tab
        case 'v':  result[dst++] = '\v'; break;  // Vertical Tab
        case '$':  result[dst++] = '$';  break;
        case '\\': result[dst++] = '\\'; break;
        case '\"': result[dst++] = '"';  break;
        case '\'': result[dst++] = '\'';  break;
        // Multiline strings can remove _new lines by escaping them.
        case '\r':
          ASSERT(is_multiline);
          if (content[src] == '\n') src++;
          at_newline = true;
          break;
        case '\n':
          ASSERT(is_multiline);
          at_newline = true;
          break;
        case 's':
          // 's' escapes are only allowed in multiline strings.
          if (is_multiline) {
            result[dst++] = ' ';
            break;
          } else {
            return null;
          }
        case 'u' :
        case 'x' : {
          // Hex decoding  "\xXX" "\x{X}" .. "\x{XXXXXX...}".
          // U decoding  "\uXXXX" "\u{X}" .. "\u{XXXXXX...}".
          if (content[src] == 0) return null;
          int code_unit = 0;
          int first = hex(content[src]);
          if (first >= 0) {
            int expected_digits = (peek == 'x') ? 2 : 4;
            code_unit = first;
            src++;
            for (int i = 1; i < expected_digits; i++) {
              int next_hex = hex(content[src++]);
              if (next_hex < 0) return null;
              code_unit = (code_unit << 4) | next_hex;
            }
          } else if (content[src] == '{') {
            src++;
            do {
              if (code_unit > Utils::MAX_UNICODE) return null;
              int next_hex = hex(content[src++]);
              if (next_hex < 0) return null;
              code_unit = (code_unit << 4) | next_hex;
            } while (content[src] != '}');
            src++;
          } else {
            // Not a valid hex syntax.
            return null;
          }
          if (code_unit <= Utils::MAX_ASCII) {
            result[dst++] = code_unit;
          } else if (code_unit > Utils::MAX_UNICODE) {
            return null;
          } else {
            char buffer[4];
            int index = 0;
            // Payload bytes have 6 bits of the code unit.
            while (code_unit > Utils::UTF_8_MASK) {
              buffer[index++] = Utils::UTF_8_PAYLOAD | (code_unit & Utils::UTF_8_MASK);
              code_unit >>= Utils::UTF_8_BITS_PER_BYTE;
            }
            uint8_t UTF_8_PREFIXES[] = {
              0x00,  // Ascii. Won't be used.
              0xC0,  // 2 bytes.
              0xE0,  // 3 bytes.
              0xF0,  // 4 bytes.
            };
            int PREFIX_MASK = (1 << (Utils::UTF_8_BITS_PER_BYTE - index)) - 1;
            if (code_unit > PREFIX_MASK) {
              // Doesn't fit yet.
              buffer[index++] = Utils::UTF_8_PAYLOAD | (code_unit & Utils::UTF_8_MASK);
              code_unit >>= Utils::UTF_8_BITS_PER_BYTE;
            }
            ASSERT(code_unit < (UTF_8_PREFIXES[index] >> 1));
            buffer[index] = UTF_8_PREFIXES[index] | code_unit;
            // Copy the utf-8 character into the result.
            for (int i = index; i >= 0; i--) {
              result[dst++] = buffer[i];
            }
          }
          break;
        }
        default: {
          return null;
        }
      }
    } else if (peek == '\r' && content[src] == '\n') {
      result[dst++] = '\n';
      src++;
    } else {
      result[dst++] = peek;
    }
    // No need to worry about `\r\n`, as the code depending on `at_newline` will
    //   not be able to remove any spaces in between the `\r` and `\n`.
    at_newline = peek == '\r' || peek == '\n';
    peek = content[src++];
  }
  result[dst] = 0;  // Terminate the string.
  *length = dst;
  return result;
}

static ast::Expression* _without_parenthesis(ast::Expression* node) {
  if (node == null) return null;
  while (node->is_Parenthesis()) {
    node = node->as_Parenthesis()->expression();
  }
  return node;
}

// Returns whether `node` is a definition.
//
// Also returns true for bad definition (`Binary` nodes with `:=` or `::=` kind).
static bool is_definition(ast::Node* node) {
  if (node == null) return false;
  if (node->is_DeclarationLocal()) return true;
  return node->is_Binary() &&
         (node->as_Binary()->kind() == Token::DEFINE ||
          node->as_Binary()->kind() == Token::DEFINE_FINAL);
}

static bool is_assignment(ast::Node* node) {
  if (node == null || !node->is_Binary()) return false;
  auto binary = node->as_Binary();
  switch (binary->kind()) {
    case Token::ASSIGN:
    case Token::ASSIGN_ADD:
    case Token::ASSIGN_BIT_AND:
    case Token::ASSIGN_BIT_OR:
    case Token::ASSIGN_BIT_SHL:
    case Token::ASSIGN_BIT_SHR:
    case Token::ASSIGN_BIT_USHR:
    case Token::ASSIGN_BIT_XOR:
    case Token::ASSIGN_DIV:
    case Token::ASSIGN_MOD:
    case Token::ASSIGN_MUL:
    case Token::ASSIGN_SUB:
      return true;

    default:
      return false;
  }
}

void MethodResolver::report_error(ir::Node* position_node, const char* format, ...) {
  auto range = _ir_to_ast_map->at(position_node)->range();
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(range, format, arguments);
  va_end(arguments);
}

void MethodResolver::report_error(const ast::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(position_node->range(), format, arguments);
  va_end(arguments);
}

void MethodResolver::report_error(Source::Range range, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(range, format, arguments);
  va_end(arguments);
}

void MethodResolver::report_error(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_error(format, arguments);
  va_end(arguments);
}

void MethodResolver::report_note(ir::Node* position_node, const char* format, ...) {
  auto range = _ir_to_ast_map->at(position_node)->range();
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_note(range, format, arguments);
  va_end(arguments);
}

void MethodResolver::report_note(const ast::Node* position_node, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_note(position_node->range(), format, arguments);
  va_end(arguments);
}

void MethodResolver::report_note(Source::Range range, const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  diagnostics()->report_note(range, format, arguments);
  va_end(arguments);
}

ir::Type MethodResolver::resolve_type(ast::Expression* type, bool is_return_type) {
  ResolutionEntry type_declaration;

  if (type->is_Nullable()) {
    auto resolved = resolve_type(type->as_Nullable()->type(), is_return_type);
    return resolved.to_nullable();
  }

  {
    // Start by checking that there isn't any `super` or `this` in the type.
    // Linearize the type, so we can check it from left to right.
    ListBuilder<ast::Identifier*> names;
    auto current = type;
    while (current != null) {
      if (current->is_Identifier()) {
        names.add(current->as_Identifier());
        current = null;
      } else if (current->is_Dot()) {
        names.add(current->as_Dot()->name());
        current = current->as_Dot()->receiver();
      } else {
        // Unless we already reported an error, we will do so later in this function.
        current = null;
      }
    }
    for (int i = names.length() - 1; i >= 0; i--) {
      auto name = names[i];
      if (is_literal_this(name) || is_literal_super(name)) {
        report_error(name, "Unexpected '%s' in type", name->data().c_str());
        return ir::Type::any();
      }
    }
  }
  Symbol type_name = Symbol::invalid();
  if (type->is_Identifier()) {
    type_name = type->as_Identifier()->data();
    // TODO(florian): remove this hack.
    if (type_name == Symbols::none) {
      if (is_return_type) return ir::Type::none();
      report_error(type->as_Identifier(), "Type 'none' is only allowed as return type");
      return ir::Type::any();
    }
    if (type_name == Symbols::any) return ir::Type::any();
    type_declaration = lookup(type_name).entry;
    if (type->is_LspSelection()) {
      _lsp->selection_handler()->type(type, scope(), type_declaration, is_return_type);
    }
  } else if (type->is_Dot()) {
    auto dot = type->as_Dot();
    type_name = dot->name()->data();
    type_declaration = scope()->lookup_prefixed(type);
    if (dot->receiver()->is_LspSelection()) {
      auto entry = lookup(dot->receiver()->as_Identifier()->data()).entry;
      _lsp->selection_handler()->type(type, scope(), entry, is_return_type);
    } else if (dot->name()->is_LspSelection()) {
      if (dot->receiver()->is_Identifier()) {
        auto lookup_entry = lookup(dot->receiver()->as_Identifier()->data()).entry;
        if (lookup_entry.is_prefix()) {
          _lsp->selection_handler()->type(type, lookup_entry.prefix(), type_declaration, is_return_type);
        } else {
          // We are not going to visit this node again. Might as well stop now.
          exit(2);
        }
      }
    }
  } else if (type->is_Error()) {
    // We already reported an error. Just assume the type is 'any'.
    return ir::Type::any();
  } else {
    report_error(type, "Invalid type");
    return ir::Type::any();
  }

  if (type_declaration.is_class()) return ir::Type(type_declaration.klass());

  if (type_declaration.is_empty()) {
    if (type_name == Symbols::String) {
      diagnostics()->report_warning(type->range(),
                                    "Use of 'String' as type is deprecated. Use 'string' instead");
      // The `String` resolves to its `string` version unless it has been shadowed.
      auto core_scope = _core_module->scope();
      auto lookup_entry = core_scope->lookup(Symbols::string).entry;
      if (!lookup_entry.is_class()) { FATAL("Couldn't find 'string' type"); }
      return ir::Type(lookup_entry.klass());
    }

    if (!type_name.is_valid()) {
      // No need to report an error, since we already did that.
      ASSERT(diagnostics()->encountered_error());
    } else {
      if (type->is_Dot()) {
        auto dot = type->as_Dot();
        if (dot->receiver()->is_Identifier() &&
            lookup(dot->receiver()->as_Identifier()->data()).entry.is_prefix()) {
          report_error(type, "Unresolved type: '%s'", type_name.c_str());
        } else {
          report_error(type, "Invalid type");
        }
      } else {
        report_error(type, "Unresolved type: '%s'", type_name.c_str());
      }
    }
  } else if (type_declaration.kind() == ResolutionEntry::AMBIGUOUS) {
    diagnostics()->start_group();
    report_error(type, "Ambiguous resolution of type: '%s'", type_name.c_str());
    for (auto node : type_declaration.nodes()) {
      report_note(node, "Resolution candidate for '%s'", type_name.c_str());
    }
    diagnostics()->end_group();
  } else if (type_declaration.is_prefix()) {
    report_error(type, "Prefix can't be used as type: '%s'", type_name.c_str());
  } else if (type_declaration.is_single()) {
    report_error(type,
                 "Type annotation does not resolve to class or interface: '%s'",
                 type_name.c_str());
  } else {
    // Not sure if possible, but doesn't hurt.
    report_error(type, "Invalid type");
  }
  return ir::Type::any();
}

void MethodResolver::resolve_fill_field_stub() {
  ASSERT(_method->is_FieldStub());
  _resolution_mode = INSTANCE;

  // Global initializers don't take arguments.
  if (_method->is_Global()) return;
  auto field_stub = _method->as_FieldStub();
  auto field = field_stub->field();
  auto ast_field = _ir_to_ast_map->at(field)->as_Field();
  auto range = ast_field->range();
  ir::Type ir_type = field->type();

  ListBuilder<ir::Parameter*> ir_parameters;
  ir::Sequence* body;

  int parameter_index = 0;
  auto this_parameter = _new ir::Parameter(MethodResolver::this_identifier(),
                                           ir::Type(_holder),
                                           false,  // Not a block.
                                           parameter_index++,
                                           false,
                                           Source::Range::invalid());
  ir_parameters.add(this_parameter);

  auto this_ref = _new ir::ReferenceLocal(this_parameter, 0, ast_field->range());

  if (field_stub->is_getter()) {
    auto range = ast_field->range();
    body = _new ir::Sequence(list_of(_new ir::Return(_new ir::FieldLoad(this_ref, field, range),
                                                     false,
                                                     range)),
                             range);
  } else {
    auto new_value_parameter = _new ir::Parameter(Symbol::synthetic("<new value>"),
                                                  ir_type,
                                                  false,  // Not a block.
                                                  parameter_index++,
                                                  false,
                                                  Source::Range::invalid());
    ir_parameters.add(new_value_parameter);

    if (field->is_final()) {
      field_stub->mark_throwing();
      // TODO(florian): Do we just want to throw this string? Probably want to
      // print a message as well. Maybe call a helper method (like `lookup_failed`) ?
      const char* message = "FINAL_FIELD_ASSIGNMENT_FAILED";
      auto throw_failure = _create_throw(new ir::LiteralString(message, strlen(message), range), range);
      body = _new ir::Sequence(list_of(throw_failure), range);
    } else {
      auto store = _new ir::FieldStore(this_ref,
                                       field,
                                       _new ir::ReferenceLocal(new_value_parameter, 0, range),
                                       range);
      auto ret = _new ir::Return(store, false, range);
      List<ir::Expression*> expressions;
      if (field->type().is_class()) {
        auto type = field->type();
        field_stub->set_checked_type(type);
        // We could also use `FIELD_AS_CHECK` here, but we expect parameter checks to be
        //   more optimized than field as-checks.
        auto check = _new ir::Typecheck(ir::Typecheck::PARAMETER_AS_CHECK,
                                        _new ir::ReferenceLocal(new_value_parameter, 0, range),
                                        type,
                                        type.klass()->name(),
                                        range);
        expressions = list_of(check, ret);
      } else {
        expressions = list_of(ret);
      }
      body = _new ir::Sequence(expressions, range);
    }
  }
  _method->set_return_type(ir_type);
  ASSERT(_method->return_type().is_valid());
  _method->set_parameters(ir_parameters.build());
  _method->set_body(body);
}

/// Returns the index of the `super` instruction in the body.
///
/// If the body does not contain any explicit super_invocation on the toplevel,
/// then -1 is returned.
int MethodResolver::_find_super_invocation(List<ast::Expression*> expressions) {
  int i = 0;
  for (; i < expressions.length(); i++) {
    auto expr = expressions[i];
    if (is_literal_super(expr)) return i;
    if (expr->is_Dot() && is_literal_super(expr->as_Dot()->receiver())) return i;
    if (expr->is_Call()) {
      auto target = expr->as_Call()->target();
      if (is_literal_super(target)) return i;
      if (target->is_Dot() && is_literal_super(target->as_Dot()->receiver())) return i;
    }
  }
  return -1;
}

class FindFinalFieldStoreVisitor : public ir::TraversingVisitor {
 public:
  FindFinalFieldStoreVisitor() : _field_store(null) { }

  ir::FieldStore* field_store() const { return _field_store; }

  void visit_FieldStore(ir::FieldStore* node) {
    if (_field_store == null && node->field()->is_final()) {
      _field_store = node;
    }
  }

 private:
  ir::FieldStore* _field_store;
};

void MethodResolver::resolve_fill_constructor() {
  ASSERT(_method->is_Constructor());
  auto klass = _method->as_Constructor()->klass();

  _resolution_mode = CONSTRUCTOR_STATIC;

  ResolutionShape synthetic_constructor_shape = ResolutionShape(0).with_implicit_this();
  bool is_synthetic_constructor = _method->resolution_shape() == synthetic_constructor_shape &&
                                  _ir_to_ast_map->find(_method) == _ir_to_ast_map->end();

  Set<ir::Parameter*> field_storing_parameters;
  std::vector<ir::Expression*> parameter_expressions;
  if (is_synthetic_constructor) {
    auto ir_parameter = _new ir::Parameter(MethodResolver::this_identifier(),
                                           ir::Type(_holder),
                                           false,  // Not a block.
                                           0,
                                           false,
                                           Source::Range::invalid());

    _method->set_parameters(ListBuilder<ir::Parameter*>::build(ir_parameter));
    _method->set_return_type(ir::Type(klass));
  } else {
    auto ast_method = _ir_to_ast_map->at(_method)->as_Method();
    if (ast_method->return_type() != null) {
      report_error(ast_method->return_type(), "Constructors may not have return types");
    }
    _resolve_fill_parameters_return_type(&field_storing_parameters, &parameter_expressions);
  }
  ASSERT(_method->return_type().is_valid());

  ListBuilder<ir::Expression*> compiled_expressions;
  for (auto expression : parameter_expressions) {
    compiled_expressions.add(expression);
  }

  // Note that we haven't pushed the scope yet.
  LocalScope parameter_scope(_scope);
  for (auto parameter : _method->parameters()) {
    auto name = parameter->name();
    if (name.is_valid()) {
      parameter_scope.add(parameter->name(), ResolutionEntry(parameter));
    }
  }

  UnorderedSet<ir::Parameter*> missing_field_storing_parameter_assignments;
  missing_field_storing_parameter_assignments.insert(field_storing_parameters.begin(),
                                                     field_storing_parameters.end());

  for (auto ir_field : klass->fields()) {
    auto ast_field = _ir_to_ast_map->at(ir_field)->as_Field();
    Symbol field_name = ast_field->name()->data();

    auto entry = parameter_scope.lookup_shallow(field_name);
    ir::Expression* ir_initial_value = null;
    auto range = Source::Range::invalid();
    if (!entry.is_empty()) {
      ASSERT(entry.is_single() && entry.single()->is_Parameter());
      auto ir_parameter = entry.single()->as_Parameter();
      bool was_present = missing_field_storing_parameter_assignments.erase(ir_parameter);
      if (was_present) {
        // This is a field-storing parameter.
        if (!_parameter_has_explicit_type(ir_parameter)) {
          ASSERT(ir_parameter->type().is_any());
          // Copy the type of the target to the field-storing parameter.
          ir_parameter->set_type(ir_field->type());
        }
        range = _ir_to_ast_map->at(ir_parameter)->range();
        ir_initial_value = _new ir::ReferenceLocal(ir_parameter, 0, range);
        if (ir_parameter->type().is_class()) {
          // We can't rely on the typecheck of the field below, as FIELD_INITIALIZER_AS_CHECKS
          // can be optimized away, and as the type isn't always the same.
          ir_initial_value = _new ir::Typecheck(ir::Typecheck::PARAMETER_AS_CHECK,
                                                ir_initial_value,
                                                ir_parameter->type(),
                                                ir_parameter->type().klass()->name(),
                                                range);
        }
      }
    }
    if (ir_initial_value == null) {
      _resolution_mode = FIELD;
      auto old_diagnostics = _diagnostics;
      NullDiagnostics null_diagnostics(_diagnostics);
      // Don't report errors for fields. That is done outside.
      _diagnostics = &null_diagnostics;
      if (ast_field->initializer() == null) {
        range = ast_field->range();
        ir_initial_value = _new ir::LiteralUndefined(range);
      } else {
        range = ast_field->initializer()->range();
        LocalScope field_initializer_scope(_scope);
        _scope = &field_initializer_scope;
        ir_initial_value = resolve_expression(ast_field->initializer(),
                                              "Can't initialize field with block");
        _scope = field_initializer_scope.outer();
      }
      _diagnostics = old_diagnostics;
    }

    if (!ir_initial_value->is_LiteralNull() ||
        (ir_field->type().is_class() && !ir_field->type().is_nullable())) {
      ASSERT(range.is_valid());
      auto this_ref = _new ir::ReferenceLocal(_method->parameters()[0], 0, range);
      if (ir_field->type().is_class() && !ir_initial_value->is_LiteralUndefined()) {
        ir_initial_value = _new ir::Typecheck(ir::Typecheck::FIELD_INITIALIZER_AS_CHECK,
                                              ir_initial_value,
                                              ir_field->type(),
                                              ir_field->type().klass()->name(),
                                              range);
      }
      compiled_expressions.add(
        _new ir::FieldStore(this_ref, ir_field, ir_initial_value, range));
    }
  }

  if (!missing_field_storing_parameter_assignments.empty()) {
    for (auto ir_parameter : field_storing_parameters) {
      if (missing_field_storing_parameter_assignments.contains(ir_parameter)) {
        report_error(ir_parameter,
                    "Couldn't find field for field-storing parameter '%s'",
                     ir_parameter->name().c_str());
      }
    }
  }

  LocalScope body_scope(_scope);
  for (auto parameter : _method->parameters()) {
    if (field_storing_parameters.contains(parameter)) {
      // Field-storing parameters are not visible for the body. All accesses there go
      // directly to the field.
      continue;
    }
    body_scope.add(parameter->name(), ResolutionEntry(parameter));
  }

  // Now that we have dealt with the fields of constructors "push" the scope
  // that contains the parameters.
  _scope = &body_scope;

  List<ast::Expression*> expressions;
  int super_position = -1;
  if (!is_synthetic_constructor) {
    auto ast_node = _ir_to_ast_map->at(_method)->as_Method();
    auto body = ast_node->body();
    if (body != null) expressions = body->expressions();
    super_position = _find_super_invocation(expressions);
  }

  // We delay the construction of the synthetic super, so we can have better
  // error messages. If there is a `super` in the body, but its not at the
  // top-level, we don't want to tell the user that we can't find the default
  // constructor in the superclass.
  auto build_synthetic_super = [&]() {
    ast::Identifier ast_super(Symbols::super);
    if (is_synthetic_constructor) {
      ast_super.set_range(_ir_to_ast_map->at(klass)->range());
    } else {
      ast_super.set_range(_ir_to_ast_map->at(_method)->range());
    }
    _resolution_mode = CONSTRUCTOR_SUPER;
    visit_Identifier(&ast_super);
    _resolution_mode = CONSTRUCTOR_LIMBO_INSTANCE;
    auto ir_node = pop();
    ASSERT(ir_node->is_Expression());
    return ir_node->as_Expression();
  };

  // Neither the `Object` class, nor direct subclasses need to invoke `super`.
  // We will update this variable as soon as a super has been emitted.
  bool needs_super_invocation = klass->super() != null && klass->super()->super() != null;
  bool has_emitted_super_invocation = false;

  // If there is an explicit `super` call, then the section before the call is
  // `static`. Otherwise, it's in limbo state (depending on the expressions we compile).
  _resolution_mode = super_position == -1 ? CONSTRUCTOR_LIMBO_STATIC : CONSTRUCTOR_STATIC;
  for (int i = 0; i < expressions.length(); i++) {
    auto expr = expressions[i];
    if (i == super_position) {
      ASSERT(_resolution_mode == CONSTRUCTOR_STATIC);
      _resolution_mode = CONSTRUCTOR_SUPER;
      auto super_call = resolve_statement(expr, null);
      bool is_explicit = true;
      bool is_at_end = false;
      compiled_expressions.add(_new ir::Super(super_call, is_explicit, is_at_end, expr->range()));
      has_emitted_super_invocation = true;
      _resolution_mode = CONSTRUCTOR_INSTANCE;
      continue;
    }

    auto old_mode = _resolution_mode;
    auto ir_expression = resolve_statement(expr, null);

    // If necessary, add a synthetic `super` before the expression we just
    // compiled.
    if (old_mode == CONSTRUCTOR_LIMBO_STATIC &&
        _resolution_mode == CONSTRUCTOR_LIMBO_INSTANCE) {

      // For later error reporting.
      _super_forcing_expression = expr;

      // If we can insert a synthetic `super` call, we will do that before this line.
      // We need to make sure that the compiled expression does not contain
      // instructions that would require static access (like setting final fields).
      FindFinalFieldStoreVisitor visitor;
      ir_expression->accept(&visitor);
      if (visitor.field_store() != null) {
        diagnostics()->start_group();
        report_error(expr, "Expression assigns to final field but accesses 'this'");
        report_note(visitor.field_store(),
                     "Assignment to final field '%s'", visitor.field_store()->field()->name().c_str());
        diagnostics()->end_group();
      }
      if (!has_emitted_super_invocation) {
        if (needs_super_invocation) {
          auto super_call = build_synthetic_super();
          bool is_explicit = false;
          bool is_at_end = false;
          compiled_expressions.add(_new ir::Super(super_call, is_explicit, is_at_end, expr->range()));
        } else {
          bool is_at_end = false;
          compiled_expressions.add(_new ir::Super(is_at_end, expr->range()));
        }
        has_emitted_super_invocation = true;
      }
    }
    compiled_expressions.add(ir_expression);
  }

  // Add the trailing `super` invocation if none was added so far.
  if (!has_emitted_super_invocation) {
    if (needs_super_invocation) {
      auto super_call = build_synthetic_super();
      bool is_explicit = false;
      bool is_at_end = true;
      compiled_expressions.add(_new ir::Super(super_call, is_explicit, is_at_end, _method->range()));
    } else {
      bool is_at_end = true;
      compiled_expressions.add(_new ir::Super(is_at_end, _method->range()));
    }
  }

  auto this_ref = _new ir::ReferenceLocal(_method->parameters()[0], 0, _method->range());
  compiled_expressions.add(_new ir::Return(this_ref, false, _method->range()));

  _method->set_body(_new ir::Sequence(compiled_expressions.build(), _method->range()));

  ASSERT(_scope == &body_scope);
  _scope = _scope->outer();
}

void MethodResolver::resolve_fill_global() {
  _resolution_mode = STATIC;

  LocalScope body_scope(_scope);
  _scope = &body_scope;

  auto ast_node = _ir_to_ast_map->at(_method);
  auto range = Source::Range::invalid();
  auto ast_field = ast_node->as_Field();
  if (ast_field->type() != null) {
    _method->set_return_type(resolve_type(ast_field->type(), false));
    ASSERT(_method->return_type().is_valid());
  } else {
    _method->set_return_type(ir::Type::any());
  }
  ir::Expression* initial_value;
  if (ast_field->initializer() == null) {
    report_error(ast_field, "Global variables must have initializers");
    range = ast_field->range();
    initial_value = _new ir::LiteralUndefined(range);
  } else {
    range = ast_field->initializer()->range();
    initial_value = resolve_expression(ast_field->initializer(),
                                       "Can't initialize global with a block");
    if (ast_field->is_final() && initial_value->is_LiteralUndefined()) {
      report_error(ast_field, "Global final variables can't be initialized with '?'");
    }
  }
  ir::Expression* body;
  if (initial_value->is_LiteralUndefined()) {
    // The failure method takes the global id as argument.
    // However, we don't know the id yet, so we use a builtin to extract it at the end.
    CallBuilder builder(range);
    builder.add_argument(_new ir::ReferenceGlobal(_method->as_Global(), false, range), Symbol::invalid());
    auto id_call = builder.call_builtin(_new ir::Builtin(ir::Builtin::GLOBAL_ID));
    body = _call_runtime(Symbols::uninitialized_global_failure_,
                         list_of(id_call),
                         range);
  } else {
    body = _new ir::Return(initial_value, false, range);
  }
  _method->set_body(_new ir::Sequence(list_of(body), range));

  ASSERT(_scope == &body_scope);
  _scope = _scope->outer();
}

void MethodResolver::resolve_fill_method() {
  auto ast_node = _ir_to_ast_map->at(_method)->as_Method();

  _resolution_mode = _method->is_static() ? STATIC : INSTANCE;

  Set<ir::Parameter*> field_storing_parameters;
  std::vector<ir::Expression*> parameter_expressions;
  _resolve_fill_parameters_return_type(&field_storing_parameters, &parameter_expressions);

  if (_method->is_factory() && ast_node->return_type() != null) {
    report_error(ast_node->return_type(), "Factories may not have return types");
  }

  if (_method->is_setter()) {
    if (ast_node->return_type() != null &&
        !_method->return_type().is_none()) {
      report_error(ast_node->return_type(), "Setters can only have 'void' as return type");
    }
    int this_count = _method->is_static() ? 0 : 1;
    if (_method->parameters().length() == this_count) {
      report_error(ast_node, "Setters must take exactly one parameter");
    } else if (_method->parameters().length() > this_count + 1) {
      report_error(ast_node->parameters()[1], "Setters must take exactly one parameter");
    }
  }

  ListBuilder<ir::Expression*> compiled_expressions;
  for (auto expression : parameter_expressions) {
    compiled_expressions.add(expression);
  }

  // Note that the scope isn't pushed yet.
  LocalScope method_scope(_scope);
  for (auto parameter : _method->parameters()) {
    if (field_storing_parameters.contains(parameter)) {
      // Field-storing parameters aren't visible to the body.
      continue;
    }
    method_scope.add(parameter->name(), ResolutionEntry(parameter));
  }

  if (!field_storing_parameters.empty()) {
    if (_method->is_static() ||
        _method->is_abstract() ||
        (_method->is_instance() && _method->holder()->is_interface())) {
      const char* kind;
      if (_method->is_static()) {
        kind = "static functions";
      } else if (_method->is_abstract()) {
        kind = "abstract methods";
      } else {
        kind = "interface methods";
      }
      for (auto ir_parameter : field_storing_parameters) {
        report_error(ir_parameter, "Field-storing parameter not allowed in %s", kind);
      }
    } else {
      auto this_parameter = _method->parameters()[0];
      UnorderedSet<ir::Field*> class_fields;
      class_fields.insert(_holder->fields().begin(), _holder->fields().end());
      for (auto field_storing : field_storing_parameters) {
        auto setter_shape = CallShape::for_instance_setter();
        auto probe = lookup(field_storing->name());
        ir::Method* setter = null;
        for (auto candidate : probe.entry.nodes()) {
          // We only look for setters in the same class.
          if (candidate == ClassScope::SUPER_CLASS_SEPARATOR) break;
          // TODO(florian): can there be something else?
          if (candidate->is_Method()) {
            auto method = candidate->as_Method();
            if (method->is_instance() && method->resolution_shape().accepts(setter_shape)) {
              setter = method;
              break;
            }
          }
        }
        if (setter == null) {
          report_error(field_storing, "Unresolved target for field-storing parameter");
        } else if (!setter->is_FieldStub()) {
          report_error(field_storing, "Field-storing parameters may not call setters.");
        } else if (!class_fields.contains(setter->as_FieldStub()->field())) {
          report_error(field_storing, "Field-storing parameter can only set local fields");
        } else if (setter->as_FieldStub()->field()->is_final()) {
          report_error(field_storing, "Can't set final field");
        } else {
          ASSERT(!field_storing->is_block());
          auto field_type = setter->as_FieldStub()->field()->type();
          if (!_parameter_has_explicit_type(field_storing)) {
            // Copy over the type of the field as type for the parameter.
            field_storing->set_type(field_type);
          }
          auto dot = _new ir::Dot(_new ir::ReferenceLocal(this_parameter, 0, field_storing->range()),
                                  field_storing->name());
          auto ast_node = _ir_to_ast_map->at(field_storing);
          ir::Expression* new_field_value = _new ir::ReferenceLocal(field_storing, 0, field_storing->range());
          if (field_type.is_class()) {
            new_field_value = _new ir::Typecheck(ir::Typecheck::FIELD_AS_CHECK,
                                                 new_field_value,
                                                 field_type,
                                                 field_type.klass()->name(),
                                                 field_storing->range());
          }
          auto setter_arg_list = list_of(new_field_value);
          auto update = _new ir::CallVirtual(dot,
                                             setter_shape,
                                             setter_arg_list,
                                             ast_node->range());
          compiled_expressions.add(update);
        }
      }
    }
  }

  _scope = &method_scope;

  auto ast_body = ast_node->body();
  if (ast_body != null) {
    auto method_range = _method->range();
    visit_Sequence(ast_body);
    auto ir_node = pop();
    ASSERT(ir_node->is_Sequence());
    ir::Sequence* ir_body = ir_node->as_Sequence();
    // Inject the 'return null' expressions into the body sequence to avoid
    // leaving the body sequence (this popping locals) before the return.
    ListBuilder<ir::Expression*> extended;
    extended.add(ir_body->expressions());
    ir::Expression* last_expression = null;
    auto return_type = _method->return_type();
    if (return_type.is_class() && !_method->return_type().is_nullable()) {
      last_expression = _new ir::Typecheck(ir::Typecheck::RETURN_AS_CHECK,
                                          _new ir::LiteralNull(method_range),
                                          _method->return_type(),
                                          _method->return_type().klass()->name(),
                                          method_range);
    } else {
      last_expression = _new ir::Return(_new ir::LiteralNull(method_range), true, method_range);
    }
    extended.add(last_expression);
    compiled_expressions.add(_new ir::Sequence(extended.build(), method_range));
    _method->set_body(_new ir::Sequence(compiled_expressions.build(), method_range));
  } else {
    // Don't set the body.
    // We might miss errors on the default-values, but we would otherwise
    //   have spurious different errors.
  }


  ASSERT(_scope == &method_scope);
  _scope = _scope->outer();
}

/// Whether the given name resembles a constant name.
/// We want to warn users when they forget a 'static' inside a class.
static bool has_constant_name(Symbol name) {
  if (!name.is_valid()) return false;
  const char* str = name.c_str();
  bool seen_capital = false;
  int len = static_cast<int>(strlen(str));
  for (int i = 0; i < len; i++) {
    char c = str[i];
    if ('A' <= c && c <= 'Z') {
      seen_capital = true;
      continue;
    }
    if (c == '_') continue;
    return false;
  }
  return seen_capital;
}

void MethodResolver::resolve_field(ir::Field* ir_field) {
  auto ast_field = _ir_to_ast_map->at(ir_field)->as_Field();
  _resolution_mode = FIELD;

  if (ir_field->is_final() &&
      ast_field->initializer() != null &&
      !ast_field->initializer()->is_LiteralUndefined() &&
      has_constant_name(ir_field->name())) {
    diagnostics()->report_warning(ast_field->name(),
                                  "Final field with constant-like name: '%s'. Missing 'static'?",
                                  ir_field->name().c_str());
  }
  // Resolve the field's types.
  auto ast_type = ast_field->type();
  if (ast_type == null) {
    ir_field->set_type(ir::Type::any());
  } else {
    ir_field->set_type(resolve_type(ast_type, false));
  }

  LocalScope expression_scope(_scope);
  _scope = &expression_scope;

  if (ast_field->initializer() != null) {
    resolve_expression(ast_field->initializer(),
                       "Can't initialize field with a block");
  }

  _scope = _scope->outer();
}

void MethodResolver::resolve_fill() {
  if (_method->is_FieldStub()) {
    resolve_fill_field_stub();
  } else if (_method->is_Global()) {
    resolve_fill_global();
  } else if (_method->is_Constructor()) {
    resolve_fill_constructor();
  } else {
    resolve_fill_method();
  }
  if (_has_primitive_invocation) {
    // Check that no mutated parameter is captured.
    for (auto param : _method->parameters()) {
      if (param->is_captured() && !param->is_effectively_final()) {
        report_error(param->range(),
                     "Mutated parameters can't be captured in methods with primitive invocations");
      }
    }
  }
}

class ReturnCollector : public ast::TraversingVisitor {
 public:
  void visit_Return(ast::Return* node) {
    TraversingVisitor::visit_Return(node);
    _returns.push_back(node);
    if (node->value() == null) {
      _has_return_without_value = true;
    } else {
      _has_return_with_value = true;
    }
  }

  void visit_Call(ast::Call* node) {
    TraversingVisitor::visit_Call(node);
    if (node->is_call_primitive()) {
      _has_return_with_value = true;
      _returns.push_back(node);
    }
  }

  bool has_return_with_value() const { return _has_return_with_value; }
  bool has_return_without_value() const { return _has_return_without_value; }
  // The return list may also contain primitive calls, which implicitly return.
  std::vector<ast::Node*> all_returns() const { return _returns; }

 private:
   std::vector<ast::Node*> _returns;
   bool _has_return_with_value = false;
   bool _has_return_without_value = false;
};

void MethodResolver::_resolve_fill_parameters_return_type(
    Set<ir::Parameter*>* field_storing_parameters,
    std::vector<ir::Expression*>* parameter_expressions) {
  _resolve_fill_return_type();

  auto ast_method = _ir_to_ast_map->at(_method)->as_Method();
  ASSERT(ast_method != null);

  bool has_implicit_this = _method->is_instance() || _method->is_constructor();

  std::vector<ir::Expression*> type_check_expressions;
  List<ir::Parameter*> ir_parameters;
  _resolve_parameters(ast_method->parameters(),
                      has_implicit_this,
                      &ir_parameters,
                      field_storing_parameters,
                      parameter_expressions);
  _method->set_parameters(ir_parameters);
}

void MethodResolver::_resolve_fill_return_type() {
  auto ast_method = _ir_to_ast_map->at(_method)->as_Method();
  ASSERT(ast_method != null);

  if (ast_method->return_type() != null) {
    _method->set_return_type(ir::Type(resolve_type(ast_method->return_type(), true)));
  } else if (_method->is_constructor() || _method->is_factory()) {
    _method->set_return_type(ir::Type(_holder));
  } else if (ast_method->body() == null) {
    // Either abstract, interface method, or bad function. Either way, we can't search
    //   for returns and have to assume that the method returns something.
    _method->set_return_type(ir::Type::any());
  } else {
    ReturnCollector visitor;
    visitor.visit(ast_method);
    if (visitor.has_return_with_value() && visitor.has_return_without_value()) {
      diagnostics()->start_group();
      report_error(ast_method, "Method can't have 'return's with and without value");
      for (auto ret : visitor.all_returns()) {
        if (ret->is_Return() && ret->as_Return()->value() == null) {
          report_note(ret, "Return without value");
        } else {
          report_note(ret, "Return with value");
        }
      }
      diagnostics()->end_group();
      _method->set_return_type(ir::Type::any());
    } else if (visitor.has_return_with_value()) {
      _method->set_return_type(ir::Type::any());
    } else {
      _method->set_return_type(ir::Type::none());
    }
  }
  ASSERT(_method->return_type().is_valid());
}

// Handles the parameters and their default values.
//
// Returns (in an output parameter) the IR parameters.
//
// Returns (in an output parameter) the list of field-storing parameters.
// These parameters will have their corresponding ast-node in the
//   `_ir_to_ast_map` (for error reporting).
// The field_storing_parameters parameter may be null.
//
// Returns (in an output parameter) the necessary expressions to set the default
// values of incoming parameters. Similarly, all type checks are stored in the
// output parameter.
void MethodResolver::_resolve_parameters(
    List<ast::Parameter*> ast_parameters,
    bool has_implicit_this,
    List<ir::Parameter*>* ir_parameters,
    Set<ir::Parameter*>* field_storing_parameters,
    std::vector<ir::Expression*>* parameter_expressions,
    int id_offset) {
  ASSERT(parameter_expressions != null);

  std::vector<ast::Parameter*> sorted_ast_parameters(ast_parameters.begin(),
                                                     ast_parameters.end());
  CallBuilder::sort_parameters(sorted_ast_parameters);

  UnorderedMap<ast::Parameter*, int> final_positions;
  for (int i = 0; i < ast_parameters.length(); i++) {
    int offset = has_implicit_this ? 1 : 0;
    final_positions[sorted_ast_parameters[i]] = i + offset;
  }

  int ir_parameter_length = ast_parameters.length() + (has_implicit_this ? 1 : 0);
  *ir_parameters = ListBuilder<ir::Parameter*>::allocate(ir_parameter_length);


  LocalScope default_value_scope(_scope);
  Scope* old_scope = _scope;
  _scope = &default_value_scope;

  if (has_implicit_this) {
    ASSERT(id_offset == 0);
    auto implicit_this = _new ir::Parameter(MethodResolver::this_identifier(),
                                            ir::Type(_holder),
                                            false,  // Not a block
                                            0,
                                            false,
                                            Source::Range::invalid());
    default_value_scope.add(implicit_this->name(),
                            ResolutionEntry(implicit_this));
    (*ir_parameters)[0] = implicit_this;
  }

  bool seen_default_values_in_unnamed = false;
  bool have_seen_unnamed_block = false;
  Set<Symbol> existing;
  for (int i = 0; i < ast_parameters.length(); i++) {
    auto parameter = ast_parameters[i];
    bool is_block = parameter->is_block();
    bool has_explicit_type = parameter->type() != null;

    // Check for duplicate parameter names.
    Symbol name = parameter->name()->data();
    if (name == Symbols::_) {
      // Anonymous parameter name.
      // Don't check for duplication, but don't allow `_` to be used as named
      //   parameter.
      if (parameter->is_named()) {
        report_error(parameter, "Can't use '_' as name for a named parameter");
      }
    } else if (is_reserved_identifier(name)) {
      report_error(parameter, "Can't use '%s' as name for a parameter", name.c_str());
    } else if (name.is_valid()) {
      if (existing.contains(name)) {
        diagnostics()->start_group();
        report_error(parameter, "Duplicate parameter '%s'", name.c_str());
        for (int j = 0; j < i; j++) {
          if (ast_parameters[j]->name()->data() == name) {
            report_note(ast_parameters[j], "First declaration of '%s'", name.c_str());
          }
        }
        diagnostics()->end_group();
      }
      existing.insert(name);
    } else {
      name = Symbol::synthetic("<invalid_param>");
    }

    // Check that block arguments are always after non-block arguments.
    if (!parameter->is_named()) {
      if (is_block) {
        have_seen_unnamed_block = true;
      } else if (have_seen_unnamed_block) {
        diagnostics()->start_group();
        report_error(parameter, "Unnamed non-blocks must be before blocks");
        for (int j = 0; j < i; j++) {
          auto other_parameter = ast_parameters[j];
          if (!other_parameter->is_named() && other_parameter->is_block()) {
            report_note(other_parameter, "Block parameter");
          }
        }
        diagnostics()->end_group();
      }
    }
    // Get the type.
    ir::Type type = has_explicit_type
        ? resolve_type(parameter->type(), false)
        : ir::Type::any();

    // Create the ir-parameter.
    int index = final_positions.at(parameter);
    auto ir_parameter = _new ir::Parameter(name,
                                           type,
                                           is_block,
                                           index + id_offset,
                                           i,
                                           parameter->default_value() != null,
                                           parameter->range());

    (*ir_parameters)[index] = ir_parameter;

    if (parameter->is_field_storing() && parameter->name()->is_LspSelection()) {
      List<ir::Field*> fields;
      auto holder = _method->holder();
      if (holder != null) {
        fields = holder->fields();
      }
      bool field_storing_is_allowed = _method->is_constructor() || _method->is_instance();
      _lsp->selection_handler()->field_storing_parameter(parameter, fields, field_storing_is_allowed);
    }

    if (field_storing_parameters != null && parameter->is_field_storing()) {
      (*field_storing_parameters).insert(ir_parameter);
      (*_ir_to_ast_map)[ir_parameter] = parameter;
    }

    // Resolve the default values.
    if (seen_default_values_in_unnamed
        && !parameter->is_named()
        && !parameter->is_block()
        && parameter->default_value() == null) {
      diagnostics()->start_group();
      report_error(parameter,
                    "Parameter without default-value, after an earlier parameter had a default-value");
      for (int j = 0; j < i; j++) {
        auto other_parameter = ast_parameters[j];
        if (other_parameter->is_named()) continue;
        if (other_parameter->default_value() == null) continue;
        report_note(other_parameter, "Parameter with default_value");
      }
      diagnostics()->end_group();
    }
    if (parameter->default_value() != null) {
      if (parameter->is_block()) {
        report_error(parameter, "Block parameters may not have a default value.");
      }
      if (!parameter->is_named()) seen_default_values_in_unnamed = true;
      // If the incoming parameter == null, replace it with the default-value (unless the
      // the default value is `null`, which wouldn't do anything).
      if (!parameter->default_value()->is_LiteralNull()) {
        auto ir_default_value = resolve_expression(parameter->default_value(),
                                                  "Default value can't be a block");

        ir::Expression* comparison;
        if (parameter->is_block()) {
          // Can't have default values for block parameters.
          ASSERT(diagnostics()->encountered_error());
          comparison = _new ir::LiteralBoolean(false, parameter->range());
        } else {
          comparison = _call_runtime(Symbols::identical,
                                      list_of(_new ir::ReferenceLocal(ir_parameter, 0, parameter->range()),
                                              _new ir::LiteralNull(parameter->range())),
                                      parameter->range());
        }
        auto assignment = _new ir::AssignmentLocal(ir_parameter, 0, ir_default_value, ir_parameter->range());
        auto ir_if = _new ir::If(comparison,
                                 assignment,
                                 _new ir::LiteralNull(parameter->range()),
                                 parameter->range());
        (*parameter_expressions).push_back(ir_if);
      }
    }

    // No need to typecheck the `any` type, and don't try to typecheck in abstract methods.
    if (!type.is_any()) {
      ASSERT(type.is_class());
      auto check = _new ir::Typecheck(ir::Typecheck::PARAMETER_AS_CHECK,
                                      _new ir::ReferenceLocal(ir_parameter, 0, parameter->range()),
                                      type,
                                      type.klass()->name(),
                                      parameter->range());
      (*parameter_expressions).push_back(check);
    }

    // Once we have resolved everything for this parameter we add it to the scope.
    default_value_scope.add(ir_parameter->name(), ResolutionEntry(ir_parameter));
  }

  _scope = old_scope;
}

ir::Expression* MethodResolver::_instantiate_runtime(Symbol id,
                                                     List<ir::Expression*> arguments,
                                                     Source::Range range) {
  ast::Identifier ast_id(id);
  ast_id.set_range(range);
  auto shape_without_implicit_this = CallShape::for_static_call_no_named(arguments);
  ir::Node* resolved_target = _resolve_call_target(&ast_id,
                                                   shape_without_implicit_this,
                                                   _core_module->scope()); // Search in core-library.
  ASSERT(resolved_target->is_ReferenceMethod());
  ASSERT(resolved_target->as_ReferenceMethod()->target()->is_static());
  auto ref_target = resolved_target->as_ReferenceMethod();
  CallBuilder call_builder(range);
  call_builder.add_arguments(arguments);
  if (ref_target->target()->is_constructor()) {
    return call_builder.call_constructor(ref_target);
  } else {
    return call_builder.call_static(ref_target);
  }
}

ir::ReferenceMethod* MethodResolver::_resolve_runtime_call(Symbol id, CallShape shape) {
  ast::Identifier ast_id(id);
  auto target = _resolve_call_target(&ast_id,
                                     shape,
                                     _core_module->scope());  // Search in the core library.
  ASSERT(target->is_ReferenceMethod());
  ASSERT(!target->as_ReferenceMethod()->target()->is_constructor());
  ASSERT(target->as_ReferenceMethod()->target()->is_static());
  return target->as_ReferenceMethod();
}

ir::Expression* MethodResolver::_call_runtime(Symbol id,
                                              List<ir::Expression*> arguments,
                                              Source::Range range) {
  auto target = _resolve_runtime_call(id, CallShape::for_static_call_no_named(arguments));
  CallBuilder builder(range);
  builder.add_arguments(arguments);
  return builder.call_static(target);
}

ir::Expression* MethodResolver::_create_throw(ir::Expression* exception,
                                              Source::Range range) {
  return _call_runtime(Symbols::throw_, list_of(exception), range);
}

static bool _contains_no_blocks(List<ir::Expression*> expressions) {
  for (auto expression : expressions) {
    if (expression->is_block()) return false;
  }
  return true;
}

ir::Expression* MethodResolver::_create_array(List<ir::Expression*> entries,
                                              Source::Range range) {
  ASSERT(_contains_no_blocks(entries));
  if (0 < entries.length() && entries.length() <= 4) {
    // Use the shortcut functions, reducing the size of the code.
    return _call_runtime(Symbols::create_array_, entries, range);
  }

  ListBuilder<ir::Expression*> expressions;

  // The array-allocation will return the canonicalized empty array if the length is 0.
  // This means we don't need to do anything here.
  auto length_argument = list_of(_new ir::LiteralInteger(entries.length(), range));
  auto array_construction = _instantiate_runtime(Symbols::Array_, length_argument, range);

  auto temporary = _new ir::Local(Symbol::synthetic("<array>"),
                                  true,   // Final.
                                  false,  // Not a block.
                                  range);
  auto define = _new ir::AssignmentDefine(temporary, array_construction, range);

  expressions.add(define);

  for (int i = 0 ; i < entries.length(); i++) {
    auto dot = _new ir::Dot(_new ir::ReferenceLocal(temporary, 0, range), Symbols::index_put);
    auto args = list_of(_new ir::LiteralInteger(i, range), entries[i]);
    auto add_call = _new ir::CallVirtual(dot,
                                         CallShape::for_instance_call_no_named(args),
                                         args,
                                         range);
    expressions.add(add_call);
  }
  // The last expression of the sequence is the return value.
  expressions.add(_new ir::ReferenceLocal(temporary, 0, range));
  return _new ir::Sequence(expressions.build(), range);
}

void MethodResolver::visit_Block(ast::Block* node) {
  // Blocks are only allowed at specific locations. These locations deal with
  // the blocks directly.
  report_error(node, "Unexpected block");
  push(_create_block(node, true, Symbol::invalid()));
}

void MethodResolver::visit_Lambda(ast::Lambda* node) {
  push(_create_lambda(node, Symbol::invalid()));
}

ir::Expression* MethodResolver::_create_lambda(ast::Lambda* node, Symbol label) {
  Scope* old_scope = _scope;
  LambdaScope lambda_scope(_scope);
  _scope = &lambda_scope;

  ListBuilder<Source::Range> ranges;

  if (node->parameters().length() > 4) {
    auto range = node->parameters()[4]->range();
    range = range.extend(node->parameters().last()->range());
    report_error(range, "Lambdas can have at most 4 parameters");
  }
  ast::Node* old_lambda = _current_lambda;
  _current_lambda = node;

  auto code = _create_code(node,
                           node->parameters(),
                           node->body(),
                           false,  // Not a block.
                           true,   // May have an implicit 'it' parameter.
                           label);
  _current_lambda = old_lambda;

  auto captured_depths = lambda_scope.captured_depths();

  ASSERT(_scope == &lambda_scope);
  ASSERT(lambda_scope.outer() == old_scope);
  _scope = old_scope;

  code->set_captured_count(captured_depths.size());

  // The captured variables are now arguments to the lambda construction.
  auto arguments = ListBuilder<ir::Expression*>::allocate(captured_depths.size());
  for (int i = 0; i < arguments.length(); i++) {
    auto captured = captured_depths.keys()[i];
    captured->mark_captured();
    int depth = captured_depths.at(captured);
    ir::Expression* captured_value = _new ir::ReferenceLocal(captured, depth, node->range());
    if (captured->is_block()) {
      report_error(node, "Can't capture block variable %s", captured->name().c_str());
      captured_value = _new ir::Error(captured->range(), list_of(captured_value));
    }
    arguments[i] = captured_value;
  }

  ir::Expression* captured_args;
  if (arguments.length() == 1) {
    captured_args = arguments[0];
  } else {
    // If the arguments-length is 0, the array-constructor will canonicalize to
    //   the empty array, thus not allocating a new object.
    captured_args = _create_array(arguments, node->range());
  }

  // Invoke the top-level `_lambda` function with the code and captured arguments.
  auto lambda_args_list = list_of(code,
                                  captured_args,
                                  _new ir::LiteralInteger(arguments.length(), node->range()));
  auto shape = CallShape::for_static_call_no_named(lambda_args_list);
  auto _lambda = _resolve_runtime_call(Symbols::lambda_, shape);
  return _new ir::Lambda(_lambda,
                         shape,
                         lambda_args_list,
                         captured_depths,
                         node->range());
}

void MethodResolver::visit_Sequence(ast::Sequence* node) {
  LocalScope scope(_scope);
  _scope = &scope;

  List<ast::Expression*> expressions = node->expressions();
  ListBuilder<ir::Expression*> ir_expressions;
  for (auto expression : expressions) {
    ir_expressions.add(resolve_statement(expression, null));
  }
  push(_new ir::Sequence(ir_expressions.build(), node->range()));

  ASSERT(_scope = &scope);
  _scope = scope.outer();
}

void MethodResolver::visit_DeclarationLocal(ast::DeclarationLocal* node) {
  push(_define(node));
}

void MethodResolver::visit_TryFinally(ast::TryFinally* node) {
  ast::Block ast_block(node->body(), List<ast::Parameter*>());
  ast_block.set_range(node->range());
  auto ir_body = _create_block(&ast_block, // Create a block from the sequence.
                               false,      // Does not have an implicit `it` parameter.
                               Symbol::invalid());
  LocalScope handler_scope(_scope);
  _scope = &handler_scope;

  auto handler_parameters = node->handler_parameters();
  int parameter_count = handler_parameters.length();
  if (parameter_count != 0 && parameter_count != 2) {
    report_error(handler_parameters[0], "There must be either 0 or 2 handler parameters");
  }

  // The handler parameters are mapped to locals.
  auto ir_handler_parameters = ListBuilder<ir::Local*>::allocate(parameter_count);
  ListBuilder<ir::Expression*> handler_expressions;
  auto first_name = Symbol::invalid();
  ir::Local* reason_local = null;
  for (int i = 0; i < parameter_count; i++) {
    auto ast_parameter = handler_parameters[i];
    if (ast_parameter->default_value() != null) {
      report_error(ast_parameter, "Handler parameters may not have a default value");
    }
    if (ast_parameter->is_field_storing()) {
      report_error(ast_parameter, "Handler parameters may not be field-storing");
    }
    if (ast_parameter->is_named()) {
      report_error(ast_parameter, "Handler parameters may not be named");
    }
    if (ast_parameter->is_block()) {
      report_error(ast_parameter, "Handler parameters may not be blocks");
    }
    auto name = ast_parameter->name()->data();
    if (name == Symbols::_) {
      // Just ignore it.
    } else if (is_reserved_identifier(name)) {
      report_error(ast_parameter, "Can't use '%s' as name for handler parameter", name.c_str());
    } else if (i == 0) {
      first_name = name;
    } else if (i == 1 && name.is_valid()) {
      // For simplicity we only check whether the first two parameter names are
      //   duplicates.
      if (name == first_name) {
        report_error(ast_parameter, "Duplicate parameter '%s'", name.c_str());
      }
    }

    bool has_explicit_type = ast_parameter->type() != null;
    ir::Type type = ir::Type::invalid();
    if (has_explicit_type) {
      type = resolve_type(ast_parameter->type(), false);
    }

    auto range = ast_parameter->range();
    ir::Local* local = _new ir::Local(name,
                                      false,  // Final
                                      false,  // Not a block
                                      type,
                                      range);
    ir::Local* ir_handler_parameter = local;
    if (i == 0) {
      reason_local = local;
      // The interpreter only tells us the unwind reason.
      // We need to make it a boolean.
      ir_handler_parameter = _new ir::Local(Symbol::synthetic("<unwind-reason>"),
                                            true,  // Final
                                            false, // Not a block
                                            range);
      auto throw_value = _new ir::LiteralInteger(Interpreter::UNWIND_REASON_WHEN_THROWING_EXCEPTION,
                                                 range);
      auto reason_ref = _new ir::ReferenceLocal(ir_handler_parameter, 0, range);
      ast::Binary comparison(Token::EQ, null, null);
      comparison.set_range(range);
      auto ir_comparison = _binary_operator(&comparison, throw_value, reason_ref);
      auto assig = _new ir::AssignmentDefine(local, ir_comparison, range);
      handler_expressions.add(assig);
    } else if (i == 1) {
      // Depending on whether we are in a throw we need to either use the value
      // from the stack, or assign `null`.
      ir_handler_parameter = _new ir::Local(Symbol::synthetic("<exception>"),
                                            true,  // Final
                                            false, // Not a block
                                            range);
      // Blank the exception value if we are not throwing.
      auto null_val = _new ir::LiteralNull(range);
      auto exception_ref = _new ir::ReferenceLocal(ir_handler_parameter, 0, range);
      auto is_throw = _new ir::ReferenceLocal(reason_local, 0, range);
      // Wrap the `is_throw` in an 'as any' to avoid type warnings
      //   ("always evaluates to true") later on.
      auto iff = _new ir::If(_new ir::Typecheck(ir::Typecheck::AS_CHECK,
                                                is_throw,
                                                ir::Type::any(),
                                                Symbols::any,
                                                node->range()),
                             exception_ref,
                             null_val,
                             range);
      auto exception_assig = _new ir::AssignmentDefine(local, iff, range);
      handler_expressions.add(exception_assig);
    }

    if (type.is_class()) {
      handler_expressions.add(_new ir::Typecheck(ir::Typecheck::Kind::PARAMETER_AS_CHECK,
                                                 _new ir::ReferenceLocal(local, 0, range),
                                                 type,
                                                 type.klass()->name(),
                                                 range));
    }
    _scope->add(local->name(), ResolutionEntry(local));
    ir_handler_parameters[i] = ir_handler_parameter;
  }

  visit(node->handler());
  auto ir_handler = pop();
  ASSERT(ir_handler->is_Sequence());
  if (!handler_expressions.is_empty()) {
    handler_expressions.add(ir_handler->as_Sequence());
    ir_handler = _new ir::Sequence(handler_expressions.build(), node->range());
  }

  _scope = handler_scope.outer();

  auto try_ = _new ir::TryFinally(ir_body,
                                  ir_handler_parameters,
                                  ir_handler->as_Sequence(),
                                  node->range());
  push(try_);
}

void MethodResolver::visit_If(ast::If* node) {
  LocalScope if_scope(_scope);
  _scope = &if_scope;

  auto ast_condition = node->expression();
  bool needs_sequence = ast_condition->is_DeclarationLocal();
  ir::Expression* ir_condition = resolve_expression(node->expression(),
                                                    "Condition can't be a block");
  auto ast_yes = node->yes();
  auto ir_yes = resolve_expression(ast_yes, "If branches may not evaluate to blocks");

  ir::Expression* ir_no;
  auto ast_no = node->no();
  if (ast_no == null) {
    ir_no = _new ir::LiteralNull(node->range());
  } else {
    ir_no = resolve_expression(ast_no, "If branches may not evaluate to blocks");
  }
  ir::Expression* result = _new ir::If(ir_condition, ir_yes, ir_no, node->range());
  if (needs_sequence) {
    // To delimit the visibility of the definition.
    result = _new ir::Sequence(list_of(result), node->range());
  }
  _scope = if_scope.outer();
  push(result);
}

void MethodResolver::visit_loop(ast::Node* node,
                                bool is_while,
                                ast::Expression* ast_initializer,
                                ast::Expression* ast_condition,
                                ast::Expression* ast_update,
                                ast::Expression* ast_body) {
  ir::Local* loop_variable = null;
  bool assign_condition_to_loop_variable = false;

  ir::Expression* ir_initializer = null;
  ir::Expression* ir_condition = null;
  ir::Expression* ir_update = null;

  LocalScope loop_scope(_scope);
  _scope = &loop_scope;

  if (ast_condition != null && ast_condition->is_DeclarationLocal()) {
    ASSERT(ast_initializer == null);
    // Something like:
    //    while x := foo:
    //      x.bar
    //
    // We move the declaration to the initializer, as if it was a `for` loop.
    auto loop_variable_declaration = ast_condition->as_DeclarationLocal();
    auto range = loop_variable_declaration->range();
    auto ast_undefined = _new ast::LiteralUndefined();
    ast_undefined->set_range(range);
    ast_initializer = _new ast::DeclarationLocal(loop_variable_declaration->kind(),
                                                 loop_variable_declaration->name(),
                                                 loop_variable_declaration->type(),
                                                 ast_undefined);
    ast_initializer->set_range(range);
    ast_condition = loop_variable_declaration->value();
    assign_condition_to_loop_variable = true;
  }

  if (ast_initializer != null && ast_initializer->is_DeclarationLocal()) {
    // Something like:
    //    for x := 0; x < 10; x++:
    //      x.bar
    auto loop_variable_declaration = ast_initializer->as_DeclarationLocal();

    auto ir_loop_variable_initializer = resolve_expression(loop_variable_declaration->value(),
                                                           "Loop variables may not be blocks");
    // Define the loop variable.
    ir_initializer = _define(loop_variable_declaration, ir_loop_variable_initializer);
    loop_variable = ir_initializer->as_AssignmentDefine()->local();
  } else if (ast_initializer != null) {
    ASSERT(!is_while);
    ir_initializer = resolve_statement(ast_initializer, null);
  }

  // The loop variable can't be mutated in the initializer, since that's where it is
  // declared.
  int old_mutation_count = loop_variable != null ? loop_variable->mutation_count() : 0;

  if (ast_condition != null) {
    if (is_while && is_definition(ast_condition)) {
      ASSERT(ast_condition->is_Binary());
      ir_condition = _bad_define(ast_condition->as_Binary());
    } else {
      ir_condition = resolve_expression(ast_condition, "Condition may not be a block");
    }
  } else {
    ir_condition = _new ir::LiteralBoolean(true, node->range());
  }
  if (assign_condition_to_loop_variable) {
    if (loop_variable == null) {
      // This happens when the left-hand-side wasn't an identifier, and we didn't
      // create a loop variable.
      ASSERT(diagnostics()->encountered_error());
      ASSERT(!ast_initializer->as_Binary()->left()->is_Identifier());
    } else if (ir_condition->is_LiteralUndefined()) {
      report_error(ast_condition,
                   "Can't assign '?' to condition loop variable");
    } else {
      // Assign the condition to the loop-variable.
      // Note that we are ignoring the 'final' bit of the local. This is ok, since
      // from a user's point of view the variable is only assigned once per iteration.
      ir_condition = _typed_assign_local(loop_variable,
                                         0,  // Block depth.
                                         ir_condition,
                                         ast_initializer->range());
    }
  }

  if (ast_update != null) {
    ir_update = resolve_expression(ast_update, null, true);
  } else {
    ir_update = _new ir::Nop(node->range());
  }

  if (loop_variable != null) {
    // If the loop variable hasn't been captured, we are allowed to reset the
    // mutation count. This is, because condition and update always happen before the
    // body. If we don't modify the loop-variable in the body, then we can capture it
    // there by just copying it.
    if (!loop_variable->is_captured()) old_mutation_count = loop_variable->mutation_count();
  }

  auto old_status = _loop_status;
  int old_loop_depth = _loop_block_depth;
  _loop_status = IN_LOOP;
  _loop_block_depth = 0;

  auto ir_body = resolve_expression(ast_body, null);

  _loop_status = old_status;
  _loop_block_depth = old_loop_depth;

  if (loop_variable != null && loop_variable->mutation_count() == old_mutation_count) {
    loop_variable->mark_effectively_final_loop_variable();
  }

  auto ir_while = _new ir::While(ir_condition, ir_body, ir_update, loop_variable, node->range());


  ListBuilder<ir::Expression*> expressions;
  if (ir_initializer != null) expressions.add(ir_initializer);
  expressions.add(ir_while);
  expressions.add(_new ir::LiteralNull(node->range()));
  push(_new ir::Sequence(expressions.build(), node->range()));

  ASSERT(_scope = &loop_scope);
  _scope = loop_scope.outer();
}

void MethodResolver::visit_While(ast::While* node) {
  visit_loop(node,
             true,
             null,
             node->condition(),
             null,
             node->body());
}

void MethodResolver::visit_For(ast::For* node) {
  visit_loop(node,
             false,
             node->initializer(),
             node->condition(),
             node->update(),
             node->body());
}

void MethodResolver::visit_BreakContinue(ast::BreakContinue* node) {
  if (node->label() != null) {
    visit_labeled_break_continue(node);
    return;
  }

  ASSERT(node->value() == null);

  const char* kind = node->is_break() ? "break" : "continue";
  switch (_loop_status) {
    case NO_LOOP:
      report_error(node, "'%s' must be inside loop", kind);
      push(_new ir::Error(node->range()));
      break;

    case IN_LAMBDA_LOOP:
      diagnostics()->start_group();
      report_error(node, "'%s' can't break out of lambda", kind);
      report_note(_current_lambda, "Location of the lambda that '%s' would break out of", kind);
      diagnostics()->end_group();
      push(_new ir::Error(node->range()));
      break;

    case IN_LOOP:
    case IN_BLOCKED_LOOP:
      push(_new ir::LoopBranch(node->is_break(), _loop_block_depth, node->range()));
  }
}

ir::Code* MethodResolver::_create_code(
    ast::Node* node,
    List<ast::Parameter*> parameters,
    ast::Sequence* body,
    bool is_block,
    bool has_implicit_it_parameter,
    Symbol label) {

  auto old_status = _loop_status;
  switch (old_status) {
    case NO_LOOP:
      break;
    case IN_LOOP:
      ASSERT(_loop_block_depth == 0);
      [[fallthrough]];
    case IN_BLOCKED_LOOP:
      _loop_status = is_block ? IN_BLOCKED_LOOP : IN_LAMBDA_LOOP;
      break;
    case IN_LAMBDA_LOOP:
      break;
  }
  if (_loop_status == IN_BLOCKED_LOOP) _loop_block_depth++;

  _break_continue_label_stack.push_back(std::make_pair(label, node));

  Scope* old_scope = _scope;
  ItScope it_scope(scope());

  int id_offset = is_block ? 1 : 0;
  List<ir::Parameter*> ir_parameters;
  std::vector<ir::Expression*> parameter_expressions;

  if (parameters.is_empty() && has_implicit_it_parameter) {
    auto ir_parameter = _new ir::Parameter(Symbols::it,
                                           ir::Type::any(), // No type.
                                           false,  // Not a block.
                                           id_offset,
                                           false,
                                           node->range());
    it_scope.set_it(ir_parameter);
    _scope = &it_scope;
  } else {
    Set<ir::Parameter*> field_storing_parameters;

    _resolve_parameters(parameters,
                        false,  // No implicit 'this'.
                        &ir_parameters,
                        &field_storing_parameters,
                        &parameter_expressions,
                        id_offset);

    for (auto field_storing : field_storing_parameters) {
      report_error(field_storing,
                   "%s can't have field-storing parameters", is_block ? "Block" : "Lambda");
    }
  }

  for (auto ast_parameter : parameters) {
    auto kind = is_block ? "Block" : "Lambda";
    if (ast_parameter->is_block()) {
      report_error(ast_parameter,
                   "%s parameters can't be blocks", kind);
    }
    if (ast_parameter->default_value() != null) {
      report_error(ast_parameter->range(),
                   "%s parameters can't have default values", kind);
    }
    if (ast_parameter->is_named()) {
      report_error(ast_parameter->range(),
                   "%s parameters can't be named", kind);
    }
  }

  for (auto ir_parameter : ir_parameters) {
    _scope->add(ir_parameter->name(), ResolutionEntry(ir_parameter));
  }

  auto error_message = is_block
      ? "Can't return a block from a block"
      : "Can't return a block from a lambda";
  auto ir_body = resolve_expression(body, error_message);

  _scope = old_scope;

  if (it_scope.it_was_used()) {
    ASSERT(ir_parameters.is_empty());
    ir_parameters = ListBuilder<ir::Parameter*>::build(it_scope.it());
  }

  if (_loop_status == IN_BLOCKED_LOOP) _loop_block_depth--;
  _loop_status = old_status;

  _break_continue_label_stack.pop_back();

  if (!parameter_expressions.empty()) {
    // Prefix the body with the parameter expressions.
    parameter_expressions.push_back(ir_body);
    ir_body = _new ir::Sequence(ListBuilder<ir::Expression*>::build_from_vector(parameter_expressions),
                                node->range());
  }

  return _new ir::Code(ir_parameters,
                       ir_body,
                       is_block,
                       node->range());
}

ir::Code* MethodResolver::_create_block(ast::Block* node,
                                        bool has_implicit_it_parameter,
                                        Symbol label) {
  BlockScope block_scope(_scope);
  _scope = &block_scope;

  auto result = _create_code(node,
                             node->parameters(),
                             node->body(),
                             true,  // Has an implicit block parameter.
                             has_implicit_it_parameter,
                             label);
  ASSERT(_scope == &block_scope);
  _scope = _scope->outer();

  return result;
}

List<ir::Node*> MethodResolver::_compute_constructor_super_candidates(ast::Node* target_node) {
  auto constructor = _method->as_Constructor();
  auto super = constructor->klass()->super();
  if (is_literal_super(target_node)) {
    ListBuilder<ir::Node*> candidates;
    for (auto super_constructor : super->constructors()) {
      candidates.add(super_constructor);
    }
    return candidates.build();
  } else {
    ASSERT(target_node->is_Dot());
    auto ast_dot = target_node->as_Dot();
    auto name = ast_dot->name()->data();
    auto entry = super->statics()->lookup(name);
    return entry.nodes();
  }
}

ir::Expression* MethodResolver::_resolve_constructor_super_target(ast::Node* target_node, CallShape shape) {
  auto candidates = _compute_constructor_super_candidates(target_node);
  for (auto candidate : candidates) {
    if (!candidate->is_Method()) continue;
    auto method = candidate->as_Method();
    if (!method->is_constructor()) continue;
    if (method->resolution_shape().accepts(shape)) {
      return _new ir::ReferenceMethod(method, target_node->range());
    }
  }
  auto constructor = _method->as_Constructor();
  auto super = constructor->klass()->super();
  // TODO(florian): List all possible options and explain why they didn't match.
  // Bonus points for continuing the resolution in the super scopes and detect
  // matches there.
  report_error(target_node,
                "Couldn't find matching constructor in superclass '%s'",
                super->name().c_str());
  return _new ir::Error(target_node->range());
}

MethodResolver::Candidates MethodResolver::_compute_target_candidates(ast::Node* target_node, Scope* scope) {
  int block_depth;
  int starting_index = -1;
  bool allow_abstracts = true;
  Symbol name = Symbol::invalid();
  ResolutionEntry candidate_entry;
  ast::Node* error_position_node = null;
  if (target_node->is_Identifier() && !is_literal_super(target_node)) {
    error_position_node = target_node;
    name = target_node->as_Identifier()->data();
    auto lookup_result = scope->lookup(name);
    candidate_entry = lookup_result.entry;
    block_depth = lookup_result.block_depth;
    starting_index = 0;
  } else if (target_node->is_Dot()) {
    ASSERT(_scope->is_prefixed_identifier(target_node) ||
           _scope->is_static_identifier(target_node));
    error_position_node = target_node->as_Dot()->name();
    name = target_node->as_Dot()->name()->data();
    candidate_entry = scope->lookup_static_or_prefixed(target_node);
    block_depth = 0;
    starting_index = 0;
  } else {
    ASSERT(is_literal_super(target_node));
    error_position_node = target_node;
    allow_abstracts = false;
    name = _method->name();
    // Resolve the current method and get the ResolutionEntry.
    // We need to do this on the class-scope to avoid finding a local that has
    // the same name as this method.
    auto entry = scope->enclosing_class_scope()->lookup_shallow(name);
    // At the very least we need to find the method we are currently compiling.
    if (entry.is_empty()) {
      ASSERT(!name.is_valid());
      ASSERT(diagnostics()->encountered_error());
      starting_index = 0;
    }
    auto nodes = entry.nodes();
    // Run through the nodes to find the class-separation token.
    for (int i = 1; i < nodes.length(); i++) {
      if (nodes[i] == ClassScope::SUPER_CLASS_SEPARATOR) {
        starting_index = i + 1;
        break;
      }
    }
    ASSERT(starting_index != -1);
    candidate_entry = entry;
    block_depth = 0;
  }
  ASSERT(error_position_node != null);

  List<ir::Node*> candidates;
  switch (candidate_entry.kind()) {
    case ResolutionEntry::PREFIX:
      report_error(error_position_node, "Can't use prefix '%s' as an expression", name.c_str());
      return {
        .name = name,
        .block_depth = block_depth,
        .nodes = List<ir::Node*>(),
        .klass = null,
        .encountered_error = true,
      };
    case ResolutionEntry::NODES:
      candidates = candidate_entry.nodes();
      break;
    case ResolutionEntry::AMBIGUOUS:
      diagnostics()->start_group();
      report_error(error_position_node, "Ambiguous resolution of '%s'", name.c_str());
      for (auto node : candidate_entry.nodes()) {
        report_note(node, "Resolution candidate for '%s'", name.c_str());
      }
      diagnostics()->end_group();
      return {
        .name = name,
        .block_depth = block_depth,
        .nodes = List<ir::Node*>(),
        .klass = null,
        .encountered_error = true,
      };
  }

  bool candidates_include_class = false;
  // Normally a class is the single entry in the candidate-list. However,
  // when the program is erroneous we might have multiple entries.
  for (int i = starting_index; i < candidates.length(); i++) {
    if (candidates[i] != ClassScope::SUPER_CLASS_SEPARATOR && candidates[i]->is_Class()) {
      candidates_include_class = true;
      break;
    }
  }

  ir::Class* klass = null;
  if (candidates_include_class) {
    bool is_single_class = candidates.length() == 1;

    // Replace the class with its unnamed constructors/factories.
    // TODO(florian): is this too expensive? Do we need to cache the candidates for classes?
    ListBuilder<ir::Node*> candidates_builder;
    for (int i = starting_index; i < candidates.length(); i++) {
      auto candidate = candidates[i];
      if (candidate == ClassScope::SUPER_CLASS_SEPARATOR ||
          !candidate->is_Class()) {
        candidates_builder.add(candidate);
        continue;
      }
      klass = candidate->as_Class();
      for (auto constructor : klass->constructors()) candidates_builder.add(constructor);
      for (auto factory : klass->factories()) candidates_builder.add(factory);
    }
    starting_index = 0;
    candidates = candidates_builder.build();

    if (!is_single_class) {
      klass = null;
    }
  }
  if (starting_index != 0 || allow_abstracts) {
    ListBuilder<ir::Node*> candidates_builder;
    for (int i = starting_index; i < candidates.length(); i++) {
      auto candidate = candidates[i];
      if (candidate == ClassScope::SUPER_CLASS_SEPARATOR) continue;
      if (!allow_abstracts &&
          candidate->is_Method() &&
          candidate->as_Method()->is_abstract()) {
        continue;
      }
      candidates_builder.add(candidate);
    }
    candidates = candidates_builder.build();
  }

  return {
    .name = name,
    .block_depth = block_depth,
    .nodes = candidates,
    .klass = klass,
    .encountered_error = false,
  };
}

bool MethodResolver::is_sdk_protected_identifier(Symbol name) {
  const char* prefix = "__";
  return strncmp(name.c_str(), prefix, strlen(prefix)) == 0;
}

// Checks that a `__identifier` of the SDK isn't accessed from outside the
// SDK libraries.
void MethodResolver::check_sdk_protection(Symbol name,
                                          const Source::Range& caller_range,
                                          const Source::Range& target_range) {
  if (is_sdk_protected_identifier(name)) {
    Source* caller_source = source_manager()->source_for_position(caller_range.from());
    if (caller_source->package_id() != Package::SDK_PACKAGE_ID) {
      Source* target_source = source_manager()->source_for_position(target_range.from());
      if (target_source->package_id() == Package::SDK_PACKAGE_ID) {
        report_error(caller_range,
                     "Can't access protected member '%s' of the SDK libraries",
                     name.c_str());
      }
    }
  }
}

/// Returns the target of a call.
///
/// Returns an `Error` node if the target is invalid.
/// For instance methods returns a `ReferenceMethod` node. The caller must change
/// this to an instance call (if necessary).
ir::Node* MethodResolver::_resolve_call_target(ast::Node* target_node,
                                               CallShape shape_without_implicit_this,
                                               Scope* lookup_scope) {
  auto range = target_node->range();

  if (lookup_scope == null) lookup_scope = scope();

  auto candidates = _compute_target_candidates(target_node, lookup_scope);
  if (candidates.encountered_error) return _new ir::Error(range);

  if (candidates.klass != null && candidates.nodes.is_empty()) {
    auto klass = candidates.klass;
    if (klass->is_interface()) {
      report_error(target_node, "Can't instantiate interface '%s'",
                   candidates.name.c_str());
    } else {
      report_error(target_node, "Class '%s' only has named constructors",
                   candidates.name.c_str());
    }
    return _new ir::Error(range);
  }

  Symbol name = candidates.name;

  if (!name.is_valid()) {
    // In this case the parser already reported an error.
    ASSERT(diagnostics()->encountered_error());
    return _new ir::Error(range);
  }

  auto candidate_nodes = candidates.nodes;
  int block_depth = candidates.block_depth;

  for (auto candidate : candidate_nodes) {
    if (candidate == ClassScope::SUPER_CLASS_SEPARATOR) {
      continue;
    } else if (ir::Block* block_node = candidate->as_Block()) {
      return _new ir::ReferenceBlock(block_node, block_depth, range);
    } else if (ir::Local* local_node = candidate->as_Local()) {
      return _new ir::ReferenceLocal(local_node, block_depth, range);
    } else if (ir::Global* global_node = candidate->as_Global()) {
      check_sdk_protection(name, target_node->range(), global_node->range());
      // By default the global reference needs to check for lazy initializers.
      // The bytegen skips cases where the global can be initialized immediately.
      // Other optimizations can also change this flag. For example, two
      // successive access to the same local don't need to check for the
      // initializer.
      bool is_lazy = true;  // Could be changed in optimizations further down the pipeline.
      return _new ir::ReferenceGlobal(global_node, is_lazy, range);
    } else if (candidate->is_Method()) {
      ASSERT(!(candidate->is_Method() && candidate->as_Method()->is_initializer()));
      auto method_node = candidate->as_Method();
      if (method_node->is_instance() || method_node->is_constructor()) {
        // If the method is an instance or constructor method, then the
        // arguments include an implicit `this` argument.
        if (!method_node->resolution_shape().accepts(shape_without_implicit_this.with_implicit_this())) {
          continue;  // Does not match.
        }
      } else {
        if (!method_node->resolution_shape().accepts(shape_without_implicit_this)) {
          continue;  // Does not match.
        }
      }
      if (method_node->is_static()) {
        check_sdk_protection(name, target_node->range(), method_node->range());
        return _new ir::ReferenceMethod(method_node, range);
      }
      // Instance method or field.
      switch (_resolution_mode) {
        case CONSTRUCTOR_LIMBO_STATIC:
          // As soon as we access super-members or invoke non-field members,
          // we have to switch to instance-mode.
          _resolution_mode = CONSTRUCTOR_LIMBO_INSTANCE;
          break;

        case CONSTRUCTOR_STATIC:
          report_error(target_node, "Can't access instance members before `super` call.");
          return _new ir::Error(range);

        case FIELD:
          report_error(target_node, "Can't access instance members in field initializers.");
          return _new ir::Error(range);

        case INSTANCE:
        case CONSTRUCTOR_INSTANCE:
        case CONSTRUCTOR_LIMBO_INSTANCE:
          // All good.
          break;

        case STATIC: {
          const char* kind = _method->is_factory() ? "factories" : "static contexts";
          report_error(target_node, "Can't access instance members in %s", kind);
          return _new ir::Error(range);
        }

        case CONSTRUCTOR_SUPER:
          UNREACHABLE();
          break;
      }

      // If the method is an instance method, then the caller must change the call to an
      // instance call.
      return _new ir::ReferenceMethod(method_node, range);
    } else {
      UNREACHABLE();
    }
  }
  // Check, whether it's ASSERT.
  if (target_node->is_Identifier() &&
      target_node->as_Identifier()->data() == Token::symbol(Token::AZZERT)) {
    if (shape_without_implicit_this == CallShape(1, 1)) {
      // A call to assert.
      return _resolve_runtime_call(Symbols::assert_, shape_without_implicit_this);
    }
    report_error(target_node, "'assert' takes exactly one block");
    return _new ir::Error(range);
  }

  // If there is no match at all, try to see, whether it's a builtin.
  if (target_node->is_Identifier()) {
    auto builtin = ir::Builtin::resolve(target_node->as_Identifier()->data());
    if (builtin != null) {
      ResolutionShape builtin_shape(builtin->arity());
      if (builtin_shape.accepts(shape_without_implicit_this)) {
        return builtin;
      }
      report_error(target_node, "Builtin call argument mismatch");
      return _new ir::Error(range);
    }
  }

  ast::Node* error_node = target_node;
  if (error_node->is_Dot()) error_node = error_node->as_Dot()->name();
  if (candidate_nodes.is_empty()) {
    report_error(error_node, "Unresolved identifier: '%s'", name.c_str());
  } else {
    Selector<CallShape> selector(name, shape_without_implicit_this);
    report_no_such_static_method(candidate_nodes, selector, error_node->range(), diagnostics());
  }
  return _new ir::Error(range);
}

ir::Expression* MethodResolver::_this_ref(Source::Range range, bool ignore_resolution_mode) {
  if (!ignore_resolution_mode) {
    ast::Identifier ast_this(Symbols::this_);
    ast_this.set_range(range);
    return resolve_expression(&ast_this, null);
  }
  auto this_lookup = lookup(this_identifier());
  ASSERT(this_lookup.entry.is_single());
  return _new ir::ReferenceLocal(this_lookup.entry.single()->as_Local(),
                                 this_lookup.block_depth,
                                 range);
}

ir::Expression* MethodResolver::resolve_expression(ast::Node* node,
                                                   const char* error_when_block,
                                                   bool allow_assignment) {
  ir::Node* ir_node;
  if (allow_assignment && is_assignment(node)) {
    ir_node = _assign(node->as_Binary());
  } else {
    visit(node);
    ir_node = pop();
  }
  ASSERT(ir_node->is_Expression());
  auto result = ir_node->as_Expression();
  if (error_when_block != null && result->is_block()) {
    auto position_node = node;
    while (position_node->is_Sequence()) {
      position_node = position_node->as_Sequence()->expressions().last();
    }
    report_error(position_node, error_when_block);
    result = _new ir::Error(node->range(), list_of(result));
  }
  return result;
}

ir::Expression* MethodResolver::resolve_statement(ast::Node* node,
                                                  const char* error_when_block) {
  ir::Node* ir_node;
  if (is_assignment(node)) {
    ir_node = _assign(node->as_Binary());
  } else if (is_definition(node)) {
    ir_node = _define(node->as_Expression());
  } else {
    visit(node);
    ir_node = pop();
  }
  ASSERT(ir_node->is_Expression());
  auto result = ir_node->as_Expression();
  if (error_when_block != null && result->is_block()) {
    auto position_node = node;
    while (position_node->is_Sequence()) {
      position_node = position_node->as_Sequence()->expressions().last();
    }
    report_error(position_node, error_when_block);
    result = _new ir::Error(node->range(), list_of(result));
  }
  return result;
}

ir::Expression* MethodResolver::resolve_error(ast::Node* node) {
  // Delimit the node as if it was enclosed in a sequence.
  LocalScope scope(_scope);
  _scope = &scope;
  auto expression = resolve_statement(node, null);
  _scope = scope.outer();
  return _new ir::Sequence(list_of(expression), node->range());
}

void MethodResolver::_handle_lsp_call_dot(ast::Dot* ast_dot, ir::Expression* ir_receiver) {
  ASSERT(ast_dot->name()->is_LspSelection());
  ASSERT(!_scope->is_prefixed_identifier(ast_dot));
  ASSERT(!_scope->is_static_identifier(ast_dot));
  // We are not handling virtual call completions here.
  // We are only handling the xxx.<lsp_selection> where `xxx` resolves to something that could be
  //   a prefix or class-name.
  // Note that xxx.<lsp_selection> itself doesn't resolve to a prefixed or static identifier (which
  //   is handled in another function).
  // Most commonly we handle cases for completions of prefixes or when trying to access static
  //   identifiers.

  if (ir_receiver->is_block()) {
    // Most likely, the selector is `call`. At least that's what the
    //   completion will suggest.
    _lsp->selection_handler()->call_block(ast_dot, ir_receiver);
  } else if (ir_receiver->is_CallConstructor() &&
             !ast_dot->receiver()->is_Parenthesis()) {
    // We have to deal with the special case `Class.x` where `x` could either
    //   be a static or an instance.
    // However, we don't want this to trigger for `(Class).x` where it is clear that
    //   the completion must be for an instance member.
    auto call_constructor = ir_receiver->as_CallConstructor();
    // The selector doesn't resolve to a static target (otherwise we wouldn't be here), so
    // no need to try to find candidates.
    List<ir::Node*> candidates;
    _lsp->selection_handler()->call_class(ast_dot,
                                          call_constructor->klass(),
                                          null,
                                          null,
                                          candidates,
                                          _scope);
  } else if (ir_receiver->is_Error() ||
              (ir_receiver->is_CallStatic() &&
              ir_receiver->as_CallStatic()->target()->target()->is_factory())) {
    // Test whether the receiver is a class.
    // Maybe it just doesn't have an unnamed constructor (in which case we would get
    // an ir-error here), or it has an unnamed factory.
    ResolutionEntry class_entry;
    if (ast_dot->receiver()->is_Identifier()) {
      class_entry = _scope->lookup(ast_dot->receiver()->as_Identifier()->data()).entry;
    } else if (_scope->is_prefixed_identifier(ast_dot->receiver())) {
      class_entry = _scope->lookup_prefixed(ast_dot->receiver());
    }
    if (class_entry.is_class()) {
      // The selector doesn't resolve to a static target (otherwise we wouldn't be here), so
      // no need to try to find candidates.
      List<ir::Node*> candidates;
      _lsp->selection_handler()->call_class(ast_dot,
                                            class_entry.klass(),
                                            null,
                                            null,
                                            candidates,
                                            _scope);
    }
  }
}

// This function is also used for assignments, where the left-hand side is
//   an identifier (or prefixed/static identifier).
// In that case, the getter and setter might be different, which is why
//   there are two IR targets.
void MethodResolver::_handle_lsp_call_identifier(ast::Node* ast_target,
                                                 ir::Node* ir_target1,
                                                 ir::Node* ir_target2) {
  ASSERT(ast_target->is_LspSelection() ||
         (ast_target->is_Dot() && ast_target->as_Dot()->name()->is_LspSelection()));
  // When it's a Dot, then we were able to identify the target.
  // Either because it was just prefixed, or as a static in a class.
  ASSERT(!ast_target->is_Dot() ||
         (_scope->is_prefixed_identifier(ast_target) ||
          _scope->is_static_identifier(ast_target)))

  auto candidates = _compute_target_candidates(ast_target, scope());
  if (ast_target->is_Identifier()) {
    _lsp->selection_handler()->call_static(ast_target,
                                           ir_target1,
                                           ir_target2,
                                           candidates.nodes,
                                           scope(),
                                           _method);
  } else if (_scope->is_prefixed_identifier(ast_target)) {
    auto ast_dot = ast_target->as_Dot();
    auto prefix_name = ast_dot->receiver()->as_Identifier()->data();
    auto entry = _scope->lookup(prefix_name).entry;
    ASSERT(entry.kind() == ResolutionEntry::PREFIX);
    _lsp->selection_handler()->call_prefixed(ast_target->as_Dot(),
                                             ir_target1,
                                             ir_target2,
                                             candidates.nodes,
                                             entry.prefix());
  } else {
    ASSERT(_scope->is_static_identifier(ast_target));
    auto ast_dot = ast_target->as_Dot();
    ResolutionEntry class_entry;
    auto receiver = ast_dot->receiver();
    if (receiver->is_Identifier()) {
      auto class_name = receiver->as_Identifier()->data();
      class_entry = _scope->lookup(class_name).entry;
    } else {
      class_entry = _scope->lookup_prefixed(receiver);
    }
    ir::Class* ir_class = class_entry.klass();
    _lsp->selection_handler()->call_class(ast_dot,
                                          ir_class,
                                          ir_target1,
                                          ir_target2,
                                          candidates.nodes,
                                          _scope);
  }
}

void MethodResolver::_visit_potential_call_identifier(ast::Node* ast_target,
                                                      CallBuilder& call_builder,
                                                      ast::LspSelection* named_lsp_selection,
                                                      ast::Node* target_name_node,
                                                      Symbol target_name) {
  // This doesn't include a potential `this` argument, if the resolved target
  // is a member method of this instance.
  auto shape_without_implicit_this = call_builder.shape();

  auto ir_target = _resolve_call_target(ast_target, shape_without_implicit_this);
  if (named_lsp_selection != null) {
    auto candidates = _compute_target_candidates(ast_target, scope());
    _lsp->selection_handler()->call_static_named(named_lsp_selection,
                                                 ir_target,
                                                 candidates.nodes);
  }
  if (ast_target->is_LspSelection() ||
      (ast_target->is_Dot() && ast_target->as_Dot()->name()->is_LspSelection())) {
    _handle_lsp_call_identifier(ast_target, ir_target, null);
  }
  if (!ir_target->is_Error() && target_name == Symbols::_) {
    ASSERT(target_name_node != null);
    report_error(target_name_node, "Can't reference '_'");
  }
  if (ir_target->is_Error()) {
    ir_target->as_Error()->set_nested(call_builder.arguments());
    push(ir_target);
  } else if (ir_target->is_ReferenceLocal() || ir_target->is_ReferenceGlobal()) {
    if (shape_without_implicit_this == CallShape(0)) {
      push(ir_target);  // Not a call.
    } else {
      const char* kind = null;
      const char* name = null;
      if (ir_target->is_ReferenceLocal()) {
        kind = "local";
        name = ir_target->as_ReferenceLocal()->target()->name().c_str();
      } else {
        kind = "global";
        name = ir_target->as_ReferenceGlobal()->target()->name().c_str();
      }
      report_error(ast_target, "Can't invoke %s variable '%s'", kind, name);
      push(_new ir::Error(ast_target->range(), call_builder.arguments()));
    }
  } else if (ir_target->is_ReferenceMethod()) {
    auto ref = ir_target->as_ReferenceMethod();
    if (ref->target()->is_constructor()) {
      auto ir_class = ref->target()->as_Constructor()->klass();
      if (ir_class->is_abstract()) {
        if (ir_class->is_interface()) {
          report_error(ast_target, "Can't instantiate interface class without factory");
        } else {
          report_error(ast_target, "Can't instantiate abstract class");
        }
      }
      push(call_builder.call_constructor(ref));
    } else if (ref->target()->is_instance()) {
      auto ir_dot = _new ir::Dot(_this_ref(ast_target->range()), ref->target()->name());
      push(call_builder.call_instance(ir_dot));
    } else if (ast_target->is_Identifier() &&
                ast_target->as_Identifier()->data() == Token::symbol(Token::AZZERT) &&
                !Flags::enable_asserts) {
      // We let resolver find the call-target (`_assert`) first to get errors if
      // assert is used with wrong arguments.
      // We do allow direct calls to `_assert` which is why we check for the token `assert`.
      ASSERT(ref->target()->name() == Symbols::assert_);
      push(_new ir::LiteralNull(ast_target->range()));
    } else {
      push(call_builder.call_static(ref));
    }
  } else if (ir_target->is_Builtin()) {
    push(call_builder.call_builtin(ir_target->as_Builtin()));
  } else {
    UNREACHABLE();
  }
}

void MethodResolver::_visit_potential_call_dot(ast::Dot* ast_dot,
                                               CallBuilder& call_builder,
                                               ast::LspSelection* named_lsp_selection) {

  // Look for `A.foo` first. If the class 'A' only has named constructors, a lookup with
  // `resolve_expression` would report an error (complaining that you need to use the
  // named constructor).
  // We know that this isn't a constructor call, as the `visit_potential_call` would have
  // caught that one.
  auto ast_receiver = ast_dot->receiver();
  // If this is for the LSP just follow the normal path.
  // We are only interested in `A.foo`/`prefix.A.foo` not `(A).foo`.
  if (!ast_dot->name()->is_LspSelection() &&
      (ast_receiver->is_Identifier() || scope()->is_prefixed_identifier(ast_receiver))) {
    auto candidates = _compute_target_candidates(ast_receiver, scope());
    if (!candidates.encountered_error &&
        (candidates.klass != null && candidates.nodes.is_empty())) {
      if (!ast_dot->name()->data().is_valid()) {
        ASSERT(diagnostics()->encountered_error());
      } else {
        auto klass = candidates.klass;
        auto class_interface = klass->is_interface() ? "Interface" : "Class";
        report_error(ast_dot, "%s '%s' does not have any static member or constructor with name '%s'",
                    class_interface,
                    candidates.name.c_str(),
                    ast_dot->name()->data().c_str());
      }
      push(_new ir::Error(ast_dot->range(), call_builder.arguments()));
      return;
    }
  }

  auto receiver = resolve_expression(ast_dot->receiver(), null);
  auto selector = ast_dot->name()->data();

  if (ast_dot->name()->is_LspSelection()) {
    _handle_lsp_call_dot(ast_dot, receiver);
  }

  if (receiver->is_block() && selector == Symbols::call) {
    if (call_builder.has_block_arguments()) {
      report_error(ast_dot, "Can't invoke a block with a block argument.");
      push(_new ir::Error(ast_dot->range(), call_builder.arguments()));
    } else if (call_builder.has_named_arguments()) {
      report_error(ast_dot, "Can't invoke a block with a named argument.");
      push(_new ir::Error(ast_dot->range(), call_builder.arguments()));
    } else {
      push(call_builder.call_block(receiver));
    }
  } else if (!selector.is_valid()) {
    ASSERT(diagnostics()->encountered_error());
    ListBuilder<ir::Expression*> nested;
    nested.add(receiver);
    nested.add(call_builder.arguments());
    push(_new ir::Error(ast_dot->name()->range(), nested.build()));
  } else if (receiver->is_block()) {
    report_error(ast_dot, "Can't invoke %s on a block", selector.c_str());
    push(_new ir::Error(ast_dot->range(), call_builder.arguments()));
  } else if (is_reserved_identifier(selector)) {
    report_error(ast_dot->name(), "Invalid member name '%s'", selector.c_str());
    push(_new ir::Error(ast_dot->range(), call_builder.arguments()));
  } else {
    bool is_construction = receiver->is_CallConstructor() ||
        (receiver->is_CallStatic() && receiver->as_CallStatic()->target()->target()->is_factory());
    if (is_construction) {
      // We don't want to allow `<X>.foo` where `foo` could be either a static or member function.
      // If `<X>` is already a named constructor, then `foo` is guaranteed to be a member. So we only
      // need to catch cases where `<X>` is of the form `ClassName` or `prefix.ClassName`.
      auto ast_receiver = ast_dot->receiver();
      bool is_prefixed = _scope->is_prefixed_identifier(ast_receiver);
      if (ast_receiver->is_Identifier()  || // Of the form `ClassName`.
          (is_prefixed && ast_receiver->is_Dot() && ast_receiver->as_Dot()->receiver()->is_Identifier())) { // Of the form `prefix.ClassName`.
        // TODO(florian): Once this isn't a warning anymore, we should change the error
        // message for LHS identifiers, complaining that no static 'xyz' was found.
        // At that point we also need to handle LSP completion here.
        diagnostics()->report_warning(ast_dot->range(),
                                      "Deprecated use of static method syntax to call an unnamed constructor. Use (<Class>).<member> instead.");
      }
    }

    ir::Dot* ir_dot;
    if (ast_dot->name()->is_LspSelection() || named_lsp_selection != null) {
      Symbol lsp_name = named_lsp_selection == null ? Symbol::invalid() : named_lsp_selection->data();
      ir_dot = _new ir::LspSelectionDot(receiver, selector, lsp_name);
    } else {
      ir_dot = _new ir::Dot(receiver, selector);
    }
    push(call_builder.call_instance(ir_dot, ast_dot->name()->range()));
  }
}

void MethodResolver::_visit_potential_call_index(ast::Node* ast_target,
                                                 CallBuilder& call_builder) {
  auto receiver = resolve_expression(ast_target,
                                     "Can't use the index operator on a block");
  push(call_builder.call_instance(_new ir::Dot(receiver, Symbols::index)));
}

void MethodResolver::_visit_potential_call_index_slice(ast::Node* ast_target,
                                                       CallBuilder& call_builder) {
  auto receiver = resolve_expression(ast_target,
                                     "Can't use the slice operator on a block");
  push(call_builder.call_instance(_new ir::Dot(receiver, Symbols::index_slice)));
}

void MethodResolver::_visit_potential_call_super(ast::Node* ast_target,
                                                 CallBuilder& call_builder,
                                                 bool is_constructor_super_call) {
  // This doesn't include a potential `this` argument, if the resolved target
  // is a member method of this instance.
  auto shape_without_implicit_this = call_builder.shape();

  switch (_resolution_mode) {
    case INSTANCE: {
      ASSERT(is_literal_super(ast_target));
      // We are getting the static resolution of the call target.
      auto ir_target = _resolve_call_target(ast_target, shape_without_implicit_this);
      if (ast_target->is_LspSelection()) {
        auto candidates = _compute_target_candidates(ast_target, scope());
        _lsp->selection_handler()->call_static(ast_target,
                                               ir_target,
                                               null,
                                               candidates.nodes,
                                               scope(),
                                               _method);
      }
      if (ir_target->is_Error()) {
        ir_target->as_Error()->set_nested(call_builder.arguments());
        push(ir_target);
        break;
      } else {
        ASSERT(ir_target->is_ReferenceMethod());
        ASSERT(ir_target->as_ReferenceMethod()->target()->is_instance());
        // We need to fix up the arguments.
        // 1. we need to add `this` in front.
        // 2. add optional arguments (if necessary).
        // Then we can do a direct static call.
        call_builder.prefix_argument(_this_ref(ast_target->range()));
        push(call_builder.call_static(ir_target->as_ReferenceMethod()));
        break;
      }
    }
    case CONSTRUCTOR_SUPER:
      // When we enter with CONSTRUCTOR_SUPER we switch to CONSTRUCTOR_STATIC
      // in the beginning of the function.
      UNREACHABLE();
    case CONSTRUCTOR_STATIC: {
      if (is_constructor_super_call) {
        auto shape = shape_without_implicit_this.with_implicit_this();
        auto ir_target = _resolve_constructor_super_target(ast_target, shape);
        if (ast_target->is_LspSelection()) {
          auto candidates = _compute_constructor_super_candidates(ast_target);
          _lsp->selection_handler()->call_static(ast_target,
                                                 ir_target,
                                                 null,
                                                 candidates,
                                                 scope(),
                                                 _method);
        } else if (ast_target->is_Dot() && ast_target->as_Dot()->name()->is_LspSelection()) {
          // The candidates include statics and factories with the same name. This might make it
          //   easier to figure out what's wrong.
          auto candidates = _compute_constructor_super_candidates(ast_target);
          auto super = _holder->super();
          auto super_statics_scope = super != null ? super->statics() : null;
          // For completion we only want constructors, but not statics or factories.
          FilteredIterableScope filtered(super_statics_scope, [&] (Symbol, const ResolutionEntry& entry) {
            for (auto node : entry.nodes()) {
              if (node->is_Method() && node->as_Method()->is_constructor()) return true;
            }
            return false;
          });
          _lsp->selection_handler()->call_prefixed(ast_target->as_Dot(),
                                                   ir_target,
                                                   null,
                                                   candidates,
                                                   &filtered);
        } else if (ast_target->is_Dot() && ast_target->as_Dot()->receiver()->is_LspSelection()) {
          // We don't provide any target for goto-definition. (The only good option would be the actual target,
          //   but that's already handled by goto-definition of the actual 'name'.
          // For completion we just provide all current static targets.
          _lsp->selection_handler()->call_static(ast_target->as_Dot()->receiver(),
                                                 null,
                                                 null,
                                                 List<ir::Node*>(),
                                                 scope(),
                                                 _method);
        }
        if (ir_target->is_ReferenceMethod()) {
          // 1. we need to add `this` in front.
          // 2. add optional arguments (if necessary).
          // Then we can do a direct static call (and not a constructor call).
          call_builder.prefix_argument(_this_ref(ast_target->range(), true));
          push(call_builder.call_static(ir_target->as_ReferenceMethod()));
        } else {
          ASSERT(ir_target->is_Error());
          auto ir_error = ir_target->as_Error();
          ir_error->set_nested(call_builder.arguments());
          push(ir_error);
        }
        break;
      } // Else fall through.
    }
    case CONSTRUCTOR_INSTANCE:
    case CONSTRUCTOR_LIMBO_INSTANCE:
      report_error(ast_target,
                  "Only one super call at the top-level of a constructor is allowed");
      push(_new ir::Error(ast_target->range(), call_builder.arguments()));
      break;
    case CONSTRUCTOR_LIMBO_STATIC:
      report_error(ast_target,
                  "Super constructor calls must be at the top-level");
      push(_new ir::Error(ast_target->range(), call_builder.arguments()));
      break;
    case FIELD:
      report_error(ast_target, "Can't access 'super' in field initializers");
      push(_new ir::Error(ast_target->range(), call_builder.arguments()));
      break;
    case STATIC:
      auto kind = _method->is_factory() ? "factory" : "static";
      report_error(ast_target, "Can't access 'super' in %s method", kind);
      push(_new ir::Error(ast_target->range(), call_builder.arguments()));
      break;
  }
}

void MethodResolver::_visit_potential_call(ast::Expression* potential_call,
                                           ast::Node* ast_target,
                                           List<ast::Expression*> ast_arguments) {
  auto range = potential_call->range();

  bool is_constructor_super_call = false;

  switch (_resolution_mode) {
    case CONSTRUCTOR_SUPER: {
      ASSERT(is_literal_super(ast_target) || ast_target->is_Dot());
      is_constructor_super_call = true;
      // Make sure the arguments are compiled in a static context.
      _resolution_mode = CONSTRUCTOR_STATIC;
      break;
    }

    case CONSTRUCTOR_STATIC:
    case CONSTRUCTOR_INSTANCE:
    case CONSTRUCTOR_LIMBO_INSTANCE:
    case CONSTRUCTOR_LIMBO_STATIC: {
      // In constructors, accesses to fields are direct.
      Symbol name = Symbol::invalid();
      bool lookup_class_scope = false;
      if (ast_target->is_Dot() && is_literal_this(ast_target->as_Dot()->receiver())) {
        name = ast_target->as_Dot()->name()->data();
        lookup_class_scope = true;
      } else if (ast_target->is_Identifier()) {
        name = ast_target->as_Identifier()->data();
        lookup_class_scope = false;
      }
      bool is_lsp_selection =
          ast_target->is_LspSelection() ||
          (ast_target->is_Dot() &&
            (ast_target->as_Dot()->receiver()->is_LspSelection() ||
             ast_target->as_Dot()->name()->is_LspSelection()));

      // We don't want to skip the "normal" handling when we do completion or
      //   goto-definition.
      if (ast_arguments.is_empty() && !is_lsp_selection) {
        auto load = _potentially_load_field(name, lookup_class_scope, ast_target->range());
        if (load != null) {
          push(load);
          return;
        }
      }
    }

    case FIELD:
    case INSTANCE:
    case STATIC:
      // Nothing to do here.
      break;
  }

  ast::Node* target_name_node = null;
  auto target_name = Symbol::invalid();
  if (ast_target->is_Identifier()) {
    target_name_node = ast_target;
    target_name = ast_target->as_Identifier()->data();
  } else if (ast_target->is_Dot()) {
    target_name_node = ast_target->as_Dot()->name();
    target_name = ast_target->as_Dot()->name()->data();
  }
  int block_count = 0;
  bool has_positional_blocks = false;
  ast::LspSelection* named_lsp_selection = null;
  CallBuilder call_builder(range);
  for (auto argument : ast_arguments) {
    Symbol name = Symbol::invalid();
    ir::Expression* ir_argument = null;
    if (argument->is_NamedArgument()) {
      auto named = argument->as_NamedArgument();
      if (named->name()->is_LspSelection()) {
        named_lsp_selection = named->name()->as_LspSelection();
      }
      name = named->name()->data();
      argument = named->expression();
      if (argument == null) {
        ir_argument = _new ir::LiteralBoolean(!named->inverted(), named->range());
      } else {
        ASSERT(!named->inverted() || diagnostics()->encountered_error());
      }
    }
    if (argument == null) {
      // Boolean flag.
      ASSERT(ir_argument != null);
    } else {
      ASSERT(ir_argument == null);
      argument = _without_parenthesis(argument);
      if (argument->is_Block()) {
        // Code-blocks are not allowed directly as arguments. It's the job of the
        // call_builder to move the code-blocks out of the call and declare them
        // first.

        // `assert` does not have an implicit `it` parameter.
        bool is_assert = ast_target->is_Identifier() &&
            ast_target->as_Identifier()->data() == Token::symbol(Token::AZZERT);
        bool has_implicit_it_parameter = !is_assert;
        ir_argument = _create_block(argument->as_Block(),
                                    has_implicit_it_parameter,
                                    target_name);
      } else if (argument->is_Lambda()) {
        ir_argument = _create_lambda(argument->as_Lambda(), target_name);
      } else {
        ir_argument = resolve_expression(argument, null);
      }
    }
    call_builder.add_argument(ir_argument, name);
    if (ir_argument->is_block()) {
      block_count++;
      if (!name.is_valid()) has_positional_blocks = true;
    } else if (has_positional_blocks && !name.is_valid()) {
      // We don't enter here for named arguments, and therefore boolean named
      //   flags (which have `argument` set to `null` won't be a problem here.
      report_error(argument, "Blocks must be after non-block arguments");
    }
  }

  if (potential_call->is_Index()) {
    // The target is the receiver, and the arguments are the parameters that were
    // inside the brackets.
    _visit_potential_call_index(ast_target, call_builder);
  } else if (potential_call->is_IndexSlice()) {
    // The target is the receiver, and the arguments are the parameters that were
    // inside the brackets.
    _visit_potential_call_index_slice(ast_target, call_builder);
  } else {
    ASSERT(potential_call->is_Call() || potential_call->is_Dot() || potential_call->is_Identifier());

    if ((ast_target->is_Identifier() && !is_literal_super(ast_target)) ||
        _scope->is_prefixed_identifier(ast_target) ||
        _scope->is_static_identifier(ast_target)) {
      _visit_potential_call_identifier(ast_target,
                                      call_builder,
                                      named_lsp_selection,
                                      target_name_node,
                                      target_name);
    } else if (ast_target->is_Dot() && !is_constructor_super_call) {
      _visit_potential_call_dot(ast_target->as_Dot(),
                                call_builder,
                                named_lsp_selection);
    } else if (is_literal_super(ast_target) ||
              (ast_target->is_Dot() && is_constructor_super_call)) {
      _visit_potential_call_super(ast_target, call_builder, is_constructor_super_call);
    } else {
      report_error(ast_target, "Can't call result of evaluating expression");
      ListBuilder<ir::Expression*> all_ir_nodes;
      all_ir_nodes.add(resolve_error(ast_target));
      all_ir_nodes.add(call_builder.arguments());
      push(_new ir::Error(ast_target->range(), all_ir_nodes.build()));
    }
  }
}

void MethodResolver::visit_Error(ast::Error* node) {
  push(_new ir::Error(node->range()));
}

void MethodResolver::visit_Call(ast::Call* node) {
  if (node->is_call_primitive()) {
    visit_call_primitive(node);
  } else {
    _visit_potential_call(node, node->target(), node->arguments());
  }
}

void MethodResolver::visit_Dot(ast::Dot* node) {
  _visit_potential_call(node, node);
}

void MethodResolver::visit_Index(ast::Index* node) {
  _visit_potential_call(node, node->receiver(), node->arguments());
}

void MethodResolver::visit_IndexSlice(ast::IndexSlice* node) {
  // Takes an ast-expression and wraps it into a named argument node.
  auto create_named_argument = [](Symbol name, ast::Expression* expr) {
    // Change it to a named argument.
    auto identifier = _new ast::Identifier(name);
    identifier->set_range(expr->range());
    auto named = _new ast::NamedArgument(identifier, false, expr);
    named->set_range(expr->range());
    return named;
  };

  ListBuilder<ast::Expression*> arguments;
  if (node->from() != null) {
    // Change it to a named argument.
    arguments.add(create_named_argument(Symbols::from, node->from()));
  }
  if (node->to() != null) {
    // Change it to a named argument.
    arguments.add(create_named_argument(Symbols::to, node->to()));
  }
  _visit_potential_call(node, node->receiver(), arguments.build());
}

void MethodResolver::visit_labeled_break_continue(ast::BreakContinue* node) {
  ASSERT(node->label() != null);
  if (node->is_break()) {
    report_error(node, "Non local breaks not yet implemented");
  }
  Symbol label = node->label()->data();
  // This is linear, but we shouldn't have too many nested blocks, and
  // we hope to hit an outer one first.
  int label_index = -1;
  bool crosses_lambda_boundary = false;
  for (int i = _break_continue_label_stack.size() - 1; i >= 0; i--) {
    if (_break_continue_label_stack[i].first == label) {
      label_index = i;
      break;
    }
    if (_break_continue_label_stack[i].second->is_Lambda()) {
      crosses_lambda_boundary = true;
    }
  }
  if (node->label()->is_LspSelection()) {
    _lsp->selection_handler()->return_label(node, label_index, _break_continue_label_stack);
  }

  if (label_index == -1) {
    report_error(node->label(), "Unresolved label '%s'", label.c_str());
  } else if (crosses_lambda_boundary) {
    report_error(node->label(), "Can't return out of lambda");
  }
  ir::Expression* return_value = null;
  if (node->value()) {
    return_value = resolve_expression(node->value(), "Can't return a block");
  } else {
    return_value = _new ir::LiteralNull(node->range());
  }
  if (label_index == -1) {
    push(_new ir::Error(node->range(), list_of(return_value)));
  } else {
    int return_depth = _break_continue_label_stack.size() - 1 - label_index;
    push(_new ir::Return(return_value, return_depth, node->range()));
  }
}

void MethodResolver::visit_Return(ast::Return* node) {
  if (_method->is_field_initializer() ||
      _resolution_mode == FIELD ||
      _method->is_Global()) {
    const char* kind = _method->is_Global() ? "global" : "field";
    diagnostics()->report_error(node->range(),
                                "Can't return from within a %s initializer",
                                kind);
    if (node->value() == null) {
      push(_new ir::Error(node->range()));
    } else {
      auto value = resolve_expression(node->value(), null, true);
      push(_new ir::Error(node->range(), list_of(value)));
    }
    return;
  }

  ir::Expression* return_value = null;
  if (node->value() != null) {
    if (_method->return_type().is_none()) {
      diagnostics()->report_warning(node->range(),
                                    "Return type of function is 'none'. Can't return a value");
    }
    return_value = resolve_expression(node->value(), "Can't return a block", true);
  } else {
    if (!_method->return_type().is_none() &&
        _ir_to_ast_map->at(_method)->as_Method()->return_type() != null) {
      diagnostics()->report_warning(node->range(), "Missing return value");
      return_value = _new ir::LiteralUndefined(node->range());
    } else {
      return_value = _new ir::LiteralNull(node->range());
    }
  }
  if (_current_lambda != null) {
    report_error(node, "Can't explicitly return from within a lambda");
    push(_new ir::Error(node->range(), list_of(return_value)));
  } else {
    auto return_type = _method->return_type();
    if (return_type.is_class()) {
      return_value = _new ir::Typecheck(ir::Typecheck::RETURN_AS_CHECK,
                                        return_value,
                                        return_type,
                                        return_type.klass()->name(),
                                        node->range());
    }
    push(_new ir::Return(return_value, false, node->range()));
  }
}

void MethodResolver::visit_Identifier(ast::Identifier* node) {
  if (is_literal_this(node)) {
    visit_literal_this(node);
  } else {
    _visit_potential_call(node, node);
  }
}

void MethodResolver::visit_LspSelection(ast::LspSelection* node) {
  visit_Identifier(node);
}

void MethodResolver::visit_literal_this(ast::Identifier* node) {
  ASSERT(is_literal_this(node));

  if (node->is_LspSelection()) {
    _lsp->selection_handler()->this_(node, _holder, scope(), _method);
  }

  switch (_resolution_mode) {
    case CONSTRUCTOR_STATIC:
      report_error(node, "Can't access 'this' before a super call in the constructor");
      push(_new ir::Error(node->range()));
      return;

    case CONSTRUCTOR_LIMBO_STATIC:
      // Access to 'this' requires to switch to instance-mode.
      _resolution_mode = CONSTRUCTOR_LIMBO_INSTANCE;
      break;

    case FIELD:
      report_error(node, "Can't access 'this' in a field initializer");
      push(_new ir::Error(node->range()));
      return;

    case INSTANCE:
    case CONSTRUCTOR_INSTANCE:
    case CONSTRUCTOR_LIMBO_INSTANCE:
      // All good.
      break;

    case STATIC:
      report_error(node, "Can't access 'this' in static method");
      push(_new ir::Error(node->range()));
      return;

    case CONSTRUCTOR_SUPER:
      UNREACHABLE();
  }

  auto this_lookup = lookup(this_identifier());
  ASSERT(this_lookup.entry.is_single());
  push (_new ir::ReferenceLocal(this_lookup.entry.single()->as_Local(),
                                this_lookup.block_depth,
                                node->range()));
}

ir::AssignmentLocal* MethodResolver::_typed_assign_local(ir::Local* local,
                                                         int block_depth,
                                                         ir::Expression* value,
                                                         Source::Range range) {
  if (local->has_explicit_type() && local->type().is_class()) {
    auto type = local->type();
    value = _new ir::Typecheck(ir::Typecheck::LOCAL_AS_CHECK,
                               value,
                               type,
                               type.klass()->name(),
                               range);
  }
  return _new ir::AssignmentLocal(local, block_depth, value, range);
}

ir::Expression* MethodResolver::_as_or_is(ast::Binary* node) {
  bool is_as = node->kind() == Token::AS;
  const char* error_message = is_as
      ? "Can't cast a block"
      : "Can't use a block in an is-test";
  auto ir_left = resolve_expression(node->left(), error_message);

  auto ast_right = node->right();
  ir::Type type = resolve_type(ast_right, false);
  auto type_name = Symbol::invalid();
  if (type.is_none()) {
    auto kind_str = is_as ? "as" : "is";
    report_error(ast_right, "'none' is not a valid type for '%s' checks.", kind_str);
    type = ir::Type::any();
    type_name = Symbols::none;
  } else if (type.is_any()) {
    type_name = Symbols::any;
  } else {
    ASSERT(type.is_class());
    type_name = type.klass()->name();
  }

  auto kind = is_as ? ir::Typecheck::AS_CHECK : ir::Typecheck::IS_CHECK;
  auto ir_check = _new ir::Typecheck(kind,
                                     ir_left,
                                     type,
                                     type_name,
                                     node->range());
  ir::Expression* result = ir_check;
  if (node->kind() == Token::IS_NOT) result = _new ir::Not(result, node->range());
  return result;
}

ir::Expression* MethodResolver::_definition_rhs(ast::Expression* node, Symbol name) {
  auto right = _without_parenthesis(node);
  if (right->is_Block()) {
    return _create_block(right->as_Block(), true, name);
  } else if (right->is_Lambda()) {
    return _create_lambda(right->as_Lambda(), name);
  }
  return resolve_expression(right, null);
}

// A definition at a bad place, or with a bad identifier.
// The node will never be added to the scope.
// Does not always report an error, but always returns an `Error` node.
ir::Expression* MethodResolver::_bad_define(ast::Binary* node) {
  if (node->left()->is_Identifier()) {
    auto name = node->left()->as_Identifier()->data();
    auto ir_right = _definition_rhs(node->right(), name);
    return _new ir::Error(node->range(), list_of(ir_right));
  } else {
    report_error(node->left(), "Left-hand side of definition must be an identifier");
    auto ir_left = resolve_expression(node->left(), null);
    auto ir_right = _definition_rhs(node->right(), Symbol::invalid());
    return _new ir::Error(node->range(), list_of(ir_left, ir_right));
  }
}

// If `ir_right` is not null, then it should be used as the right-hand side
// without evaluating the [node]'s right node.
ir::Expression* MethodResolver::_define(ast::Expression* node,
                                        ir::Expression* ir_right) {
  ASSERT(is_definition(node));
  if (node->is_Binary()) {
    // We come here, either because the lhs of the definition isn't an identifier,
    //   or because we don't want to report follow-up errors, when calling
    //   `resolve_statement`.
    return _bad_define(node->as_Binary());
  }
  auto ast_declaration = node->as_DeclarationLocal();
  ASSERT(ast_declaration->kind() == Token::DEFINE || ast_declaration->kind() == Token::DEFINE_FINAL);
  auto name = Symbol::invalid();
  ast::Identifier* ast_name = ast_declaration->name();
  name = ast_name->data();
  ASSERT(ast_name != null);
  if (is_reserved_identifier(ast_name)) {
    report_error(ast_name, "Can't use '%s' as name for a local variable", name.c_str());
  } else {
    auto lookup_result = lookup(ast_name);
    auto entry = lookup_result.entry;
    switch (entry.kind()) {
      case ResolutionEntry::PREFIX:
        // We are allowed to shadow prefixes.
        break;
      case ResolutionEntry::AMBIGUOUS:
        // Ambiguous nodes can only be imports, so don't matter for shadowing.
        break;

      case ResolutionEntry::NODES:
        if (entry.is_single() && entry.single()->is_Local()) {
          diagnostics()->start_group();
          report_error(ast_name,
                      "Definition of '%s' shadows earlier definition",
                      name.c_str());
          report_note(entry.single()->as_Local()->range(),
                      "Earlier definition of '%s'",
                      name.c_str());
          diagnostics()->end_group();
        }
        if (entry.is_single() && entry.single()->is_Global()) {
          diagnostics()->start_group();
          report_error(ast_name,
                      "Definition of '%s' shadows global variable",
                      name.c_str());
          report_note(entry.single()->as_Global()->range(),
                      "Global definition of '%s'",
                      name.c_str());
          diagnostics()->end_group();
        }
        if (!entry.is_empty() && entry.nodes()[0]->is_FieldStub() &&
            (!_method->is_static() || _method->is_constructor())) {  // Statics can't access the instance fields anyway.
          diagnostics()->start_group();
          report_error(ast_name,
                      "Definition of '%s' shadows outer field definition",
                      name.c_str());
          report_note(entry.nodes()[0]->as_FieldStub()->field(),
                      "Shadowed field '%s'",
                      name.c_str());
          diagnostics()->end_group();
        }
    }
  }

  bool has_explicit_type = ast_declaration->type() != null;

  auto type = has_explicit_type
      ? resolve_type(ast_declaration->type(), false)
      : ir::Type::invalid();

  if (ir_right == null) {
    ir_right = _definition_rhs(ast_declaration->value(), name);
  }

  ir::Local* local;
  if (ir_right->is_block()) {
    local = _new ir::Block(name, ast_declaration->name()->range());
    if (type.is_valid()) {
      report_error(ast_declaration->type(),
                   "Can't assign block to a typed local");
    }
  } else {
    local = _new ir::Local(name,
                           ast_declaration->kind() == Token::DEFINE_FINAL,
                           ir_right->is_block(),
                           type,
                           ast_declaration->name()->range());
    if (type.is_valid() && !type.is_any() && !ir_right->is_LiteralUndefined()) {
      ASSERT(type.is_class());
      ir_right = _new ir::Typecheck(ir::Typecheck::LOCAL_AS_CHECK,
                                    ir_right,
                                    type,
                                    type.klass()->name(),
                                    ast_declaration->range());
    }
  }
  scope()->add(name, ResolutionEntry(local));
  return _new ir::AssignmentDefine(local, ir_right, ast_declaration->range());
}

ir::Expression* MethodResolver::_assign(ast::Binary* node, bool is_postfix) {
  ListBuilder<ir::Expression*> expressions;

  CreateTemp create_temp = [&expressions, node](ir::Expression* value) mutable {
    auto temporary = _new ir::Local(Symbol::synthetic("<tmp>"),
                                    true,  // Final.
                                    false, // Not a block.
                                    Source::Range::invalid());
    auto define = _new ir::AssignmentDefine(temporary, value, node->range());
    expressions.add(define);
    return temporary;
  };

  ir::Local* old_value_tmp = null;
  StoreOldValue store_old = [&](ir::Expression* value) mutable {
    if (!is_postfix) return value;
    old_value_tmp = create_temp(value);
    ir::Expression* result = _new ir::ReferenceLocal(old_value_tmp, 0, node->range());
    return result;
  };

  ir::Expression* ir_assignment = null;
  if (node->left()->is_Identifier() ||
      scope()->is_prefixed_identifier(node->left()) ||
      scope()->is_static_identifier(node->left())) {
    ir_assignment = _assign_identifier(node, store_old);
  } else if (node->left()->is_Dot()) {
    ir_assignment = _assign_dot(node, create_temp, store_old);
  } else if (node->left()->is_Index()) {
    ir_assignment = _assign_index(node, create_temp, store_old);
  } else {
    ir::Expression* ir_left = null;
    if (node->left()->is_LiteralArray() ||
        node->left()->is_LiteralBoolean() ||
        node->left()->is_LiteralCharacter() ||
        node->left()->is_LiteralFloat() ||
        node->left()->is_LiteralInteger() ||
        node->left()->is_LiteralList() ||
        node->left()->is_LiteralMap() ||
        node->left()->is_LiteralNull() ||
        node->left()->is_LiteralSet() ||
        node->left()->is_LiteralString() ||
        node->left()->is_LiteralStringInterpolation()) {
      report_error(node->left(), "Can't assign to literal");
    } else if (is_literal_this(node->left())) {
      report_error(node->left(), "Can't assign to 'this'");
    } else if (node->left()->is_Expression()) {
      // Should cover Binary, Unary and Parenthesis expressions.
      report_error(node->left(), "Can't assign to expression");
      ir_left = resolve_expression(node->left(), null);
    } else {
      UNREACHABLE();
    }
    auto ir_right = resolve_expression(node->right(), null, true);
    if (ir_left == null) {
      return _new ir::Error(node->range(), list_of(ir_right));
    } else {
      return _new ir::Error(node->range(), list_of(ir_left, ir_right));
    }
  }

  if (expressions.length() == 0 && !is_postfix) {
    return ir_assignment;
  } else {
    expressions.add(ir_assignment);
    if (is_postfix) {
      if (old_value_tmp == null) {
        ASSERT(diagnostics()->encountered_error());
        expressions.add(_new ir::Error(node->range()));
      } else {
        expressions.add(_new ir::ReferenceLocal(old_value_tmp, 0, node->left()->range()));
      }
    }
    return _new ir::Sequence(expressions.build(), node->range());
  }
}

ir::Expression* MethodResolver::_potentially_store_field(ast::Node* node,
                                                         Symbol name,
                                                         bool lookup_class_scope,
                                                         ast::Expression* value,
                                                         StoreOldValue& store_old) {
  bool is_compound = node->is_Binary() && node->as_Binary()->kind() != Token::ASSIGN;

  ASSERT(_resolution_mode == CONSTRUCTOR_STATIC ||
         _resolution_mode == CONSTRUCTOR_INSTANCE ||
         _resolution_mode == CONSTRUCTOR_LIMBO_STATIC ||
         _resolution_mode == CONSTRUCTOR_LIMBO_INSTANCE);
  Scope* scope = lookup_class_scope ? _scope->enclosing_class_scope() : _scope;
  auto lookup_result = scope->lookup(name);
  if (lookup_result.entry.is_prefix()) return null;
  auto candidates = lookup_result.entry.nodes();
  for (int i = 0; i < candidates.length(); i++) {
    auto candidate = candidates[i];
    if (candidate == ClassScope::SUPER_CLASS_SEPARATOR) break;
    if (!candidate->is_FieldStub() || candidate->as_FieldStub()->is_getter()) continue;

    // We found a local field of the correct name.

    // Check that it is not in a super-class.
    bool found_super_class_separator = false;
    for (int j = i + 1; j < candidates.length(); j++) {
      if (candidates[j] == ClassScope::SUPER_CLASS_SEPARATOR) {
        found_super_class_separator = true;
        break;
      }
    }
    if (!found_super_class_separator) {
      // The found field is from a super-class. We have to use a virtual call to
      // access it.
      break;
    }

    auto field = candidate->as_FieldStub()->field();

    if (_resolution_mode == CONSTRUCTOR_INSTANCE && field->is_final()) {
      report_error(node, "Can't assign final field in dynamic part of constructor");
    }
    if (_resolution_mode == CONSTRUCTOR_LIMBO_INSTANCE && field->is_final()) {
      if (_super_forcing_expression == null) {
        // Do nothing.
        // We will run through the expression again and then report an error.
        // It might be this assignment, or an earlier one. Either way we don't need
        // to do anything.
      } else {
        diagnostics()->start_group();
        report_error(node, "Can't assign final field in dynamic part of constructor");
        report_note(_super_forcing_expression,
                    "Expression that switched to dynamic part");
        diagnostics()->end_group();
      }
    }

    ir::Expression* ir_value;
    if (is_compound) {
      auto ir_this = _this_ref(node->range(), true);  // Don't care for the resolution-mode.
      auto old_value = store_old(_new ir::FieldLoad(ir_this, field, node->range()));
      ir_value = _binary_operator(node->as_Binary(), old_value);
    } else {
      ir_value = resolve_expression(value, "Can't store a block in a field", true);
    }

    auto ir_this = _this_ref(node->range(), true);  // Don't care for the resolution-mode.
    if (field->type().is_class() &&
        (_resolution_mode == CONSTRUCTOR_INSTANCE ||
         _resolution_mode == CONSTRUCTOR_LIMBO_INSTANCE)) {
      ir_value = _new ir::Typecheck(ir::Typecheck::FIELD_AS_CHECK,
                                    ir_value,
                                    field->type(),
                                    field->type().klass()->name(),
                                    node->range());
    }
    auto field_store = _new ir::FieldStore(ir_this, field, ir_value, node->range());
    if (field->is_final() &&
       (_resolution_mode == CONSTRUCTOR_LIMBO_STATIC ||
        _resolution_mode == CONSTRUCTOR_LIMBO_INSTANCE)) {
      // Store the ast-node, since we might need it for error-reporting.
      (*_ir_to_ast_map)[field_store] = node;
    }
    return field_store;
  }
  return null;
}

ir::Expression* MethodResolver::_potentially_load_field(Symbol name,
                                                        bool lookup_class_scope,
                                                        Source::Range range) {
  ASSERT(_resolution_mode == CONSTRUCTOR_STATIC ||
         _resolution_mode == CONSTRUCTOR_INSTANCE ||
         _resolution_mode == CONSTRUCTOR_LIMBO_STATIC ||
         _resolution_mode == CONSTRUCTOR_LIMBO_INSTANCE);
  Scope* scope = lookup_class_scope ? _scope->enclosing_class_scope() : _scope;
  auto lookup_result = scope->lookup(name);
  if (lookup_result.entry.is_prefix()) return null;
  auto candidates = lookup_result.entry.nodes();
  for (int i = 0; i < candidates.length(); i++) {
    auto candidate = candidates[i];
    if (candidate == ClassScope::SUPER_CLASS_SEPARATOR) break;
    if (!candidate->is_FieldStub() || !candidate->as_FieldStub()->is_getter()) continue;

    // We found a local field of the correct name.

    // Check that it is not in a super-class.
    bool found_super_class_separator = false;
    for (int j = i + 1; j < candidates.length(); j++) {
      if (candidates[j] == ClassScope::SUPER_CLASS_SEPARATOR) {
        found_super_class_separator = true;
        break;
      }
    }
    if (!found_super_class_separator) {
      // The found field is from a super-class. We have to use a virtual call to
      // access it.
      break;
    }

    auto field = candidate->as_FieldStub()->field();
    auto ir_this = _this_ref(range, true);  // Don't care for the resolution-mode.
    return _new ir::FieldLoad(ir_this, field, range);
  }
  return null;
}

ir::Expression* MethodResolver::_assign_dot(ast::Binary* node,
                                            CreateTemp& create_temp,
                                            StoreOldValue& store_old) {
  bool is_compound = node->kind() != Token::ASSIGN;
  auto dot = node->left()->as_Dot();

  // `this.x` in a constructor is treated specially.
  if (is_literal_this(dot->receiver()) &&
      // We prefer treating the `this.x` "normally" when handling
      // lsp selections.
      !dot->receiver()->is_LspSelection() &&
      !dot->name()->is_LspSelection() &&
      (_resolution_mode == CONSTRUCTOR_STATIC ||
       _resolution_mode == CONSTRUCTOR_INSTANCE ||
       _resolution_mode == CONSTRUCTOR_LIMBO_STATIC ||
       _resolution_mode == CONSTRUCTOR_LIMBO_INSTANCE)) {
    Symbol name = dot->name()->data();
    auto field_initialization =
        _potentially_store_field(node, name, true, node->right(), store_old);
    if (field_initialization != null) return field_initialization;
  }

  auto create_dot = [&](ir::Expression* receiver, Symbol selector) {
    if (dot->name()->is_LspSelection()) {
      ir::Dot* result = _new ir::LspSelectionDot(receiver, selector, Symbol::invalid());
      return result;
    } else {
      return _new ir::Dot(receiver, selector);
    }
  };

  auto ir_receiver = resolve_expression(dot->receiver(), "Can't set field of a block");
  if (dot->name()->is_LspSelection()) {
    _handle_lsp_call_dot(dot, ir_receiver);
  }

  if (!is_compound) {
    auto lhs = create_dot(ir_receiver, dot->name()->data());
    auto ir_rhs = resolve_expression(node->right(), "Can't assign block to instance member", true);
    auto args_list = list_of(ir_rhs);
    return _new ir::CallVirtual(lhs, CallShape::for_instance_setter(), args_list, node->range());
  }

  Symbol selector = dot->name()->data();

  auto tmp = create_temp(ir_receiver);
  auto no_args = List<ir::Expression*>();
  auto old_value = store_old(
      _new ir::CallVirtual(create_dot(_new ir::ReferenceLocal(tmp, 0, dot->receiver()->range()),
                                      selector),
                           CallShape::for_instance_call_no_named(no_args),
                           no_args,
                           dot->range()));
  auto new_value = _binary_operator(node, old_value);
  ASSERT(!new_value->is_block());
  auto new_value_args = list_of(new_value);
  // Note that we allow to assign blocks to fields, since getters may invoke them.
  return _new ir::CallVirtual(create_dot(_new ir::ReferenceLocal(tmp, 0, dot->receiver()->range()),
                                         selector),
                              CallShape::for_instance_setter(),
                              new_value_args,
                              dot->range());
}

ir::Expression* MethodResolver::_assign_index(ast::Binary* node,
                                              CreateTemp& create_temp,
                                              StoreOldValue& store_old) {
  bool is_compound = node->kind() != Token::ASSIGN;
  auto index = node->left()->as_Index();
  auto receiver_range = index->receiver()->range();

  ir::Expression* ir_receiver;
  ListBuilder<ir::Expression*> ir_arguments_builder;

  ir_receiver = resolve_expression(index->receiver(), "Can't use []= operator on a block");
  for (auto argument : index->arguments()) {
    auto ir_argument = resolve_expression(argument, null);
    ir_arguments_builder.add(ir_argument);
  }

  List<ir::Expression*> ir_arguments;
  if (!is_compound) {
    auto new_value = resolve_expression(node->right(), "Can't use []= with a block value", true);
    ir_arguments_builder.add(new_value);
    ir_arguments = ir_arguments_builder.build();
  } else {
    // The ir_receiver is updated below.
    ir::Local* receiver_local = create_temp(ir_receiver);

    ListBuilder<ir::Expression*> arguments_builder_read;
    ListBuilder<ir::Expression*> arguments_builder_store;
    for (auto argument : ir_arguments_builder.build()) {
      if (argument->is_Literal()) {
        arguments_builder_read.add(argument);
        // NOTE: this changes the tree into a DAG for Literal nodes.
        arguments_builder_store.add(argument);
      } else {
        auto tmp = create_temp(argument);
        arguments_builder_read.add(_new ir::ReferenceLocal(tmp, 0, argument->range()));
        arguments_builder_store.add(_new ir::ReferenceLocal(tmp, 0, argument->range()));
      }
    }

    auto ir_receiver_read = _new ir::ReferenceLocal(receiver_local, 0, receiver_range);
    auto args_read = arguments_builder_read.build();
    auto old_value = store_old(
        _new ir::CallVirtual(_new ir::Dot(ir_receiver_read, Symbols::index),
                             CallShape::for_instance_call_no_named(args_read),
                             args_read,
                             node->range()));

    auto new_value = _binary_operator(node, old_value);
    arguments_builder_store.add(new_value);

    ir_receiver = _new ir::ReferenceLocal(receiver_local, 0, receiver_range);
    ir_arguments = arguments_builder_store.build();
  }

  return _new ir::CallVirtual(_new ir::Dot(ir_receiver, Symbols::index_put),
                              CallShape::for_instance_call_no_named(ir_arguments),
                              ir_arguments,
                              node->range());
}

ir::Expression* MethodResolver::_assign_instance_member(ast::Binary* node,
                                                        Symbol selector,
                                                        StoreOldValue& store_old) {
  bool is_compound = node->kind() != Token::ASSIGN;

  auto create_receiver = [&]() {
    return _new ir::Dot(_this_ref(node->left()->range()), selector);
  };

  ir::Expression* ir_value;
  if (is_compound) {
    auto no_args = List<ir::Expression*>();
    auto old_value = store_old(
        _new ir::CallVirtual(create_receiver(),
                             CallShape::for_instance_call_no_named(no_args),
                             no_args,
                             node->range()));
    ir_value = _binary_operator(node, old_value);
    if (ir_value->is_block()) {
      report_error(node->right(), "Can't assign block to instance member");
    }
  } else {
    ir_value = resolve_expression(node->right(), "Can't assign block to instance member", true);
  }
  auto new_value_args = list_of(ir_value);
  return _new ir::CallVirtual(create_receiver(),
                              CallShape::for_instance_setter(),
                              new_value_args,
                              node->range());
}

bool MethodResolver::_assign_identifier_resolve_left(ast::Binary* node,
                                                     ir::Node** setter_node,
                                                     ir::Node** getter_node,
                                                     int* block_depth) {
  auto ast_left = node->left();

  bool is_dotted = ast_left->is_Dot();
  bool is_super = is_literal_super(ast_left);

  ast::Node* error_position_node;

  if (is_dotted) {
    auto dot = ast_left->as_Dot();
    if (!dot->name()->data().is_valid()) {
      // Something like `Klass. =`.
      // Don't even try to resolve.
      return false;
    }
    error_position_node = dot->name();
  } else {
    error_position_node = ast_left;
  }

  if (is_super) {
    if (!_method->name().is_valid()) {
      // No need to search for a super node, if we don't even know our own name.
      ASSERT(diagnostics()->encountered_error());
      return false;
    }
    switch (_resolution_mode) {
      case STATIC:
        report_error(error_position_node, "Can't assign to 'super' in static contexts");
        return false;

      case CONSTRUCTOR_STATIC:
      case CONSTRUCTOR_INSTANCE:
      case CONSTRUCTOR_LIMBO_STATIC:
      case CONSTRUCTOR_LIMBO_INSTANCE:
      case CONSTRUCTOR_SUPER:
        report_error(error_position_node, "Can't assign to 'super' in constructor");
        return false;

      case FIELD:
        report_error(error_position_node, "Can't assign to 'super' in field initializer");
        return false;

      case INSTANCE:
        // Do nothing.
        break;
    }
  }
  if (is_literal_this(ast_left)) {
    report_error(error_position_node, "Can't assign to 'this'");
    return false;
  }

  auto candidates = _compute_target_candidates(ast_left, scope());
  Symbol name = candidates.name;

  if (candidates.encountered_error) return false;

  if (candidates.klass != null) {
    report_error(error_position_node,
                 "Can't assign to %s '%s'",
                 candidates.klass->is_interface() ? "interface" : "class",
                 name.c_str());
    return false;
  }
  bool is_compound = node->kind() != Token::ASSIGN;

  if (candidates.nodes.is_empty()) {
    report_error(error_position_node, "Can't assign to unknown '%s'", name.c_str());
    return false;
  }

  // Start by looking at the first node only.
  ir::Node* ir_first_node = candidates.nodes[0];
  if (ir_first_node->is_Local() && ir_first_node->as_Local()->is_block()) {
    report_error(error_position_node, "Can't assign to block variable '%s'", name.c_str());
    return false;
  }

  if ((ir_first_node->is_Method() && !ir_first_node->is_Global()) ||
      ir_first_node->is_Field()) {
    bool is_instance = ir_first_node->as_Method()->is_instance();
    // Check that the available members support setting (and reading if compound).
    bool looking_for_getter = is_compound;
    bool looking_for_setter = true;
    CallShape setter_shape = is_instance
        ? CallShape::for_instance_setter()
        : CallShape::for_static_setter();
    CallShape getter_shape = is_instance
        ? CallShape::for_instance_getter()
        : CallShape::for_static_getter();
    for (auto member : candidates.nodes) {
      if (member == ClassScope::SUPER_CLASS_SEPARATOR) continue;
      if (member->is_Method()) {
        auto method = member->as_Method();
        if (looking_for_getter && method->resolution_shape().accepts(getter_shape)) {
          looking_for_getter = false;
          *getter_node = method;
        } else if (looking_for_setter &&
                   method->resolution_shape().is_setter() &&
                   method->resolution_shape().accepts(setter_shape)) {
          looking_for_setter = false;
          *setter_node = method;
          check_sdk_protection(method->name(), error_position_node->range(), method->range());
          if (member->is_FieldStub() && member->as_FieldStub()->field()->is_final()) {
            report_error(error_position_node, "Final field '%s' cannot be assigned", name.c_str());
            return false;
          }
        }
      }
      if (!looking_for_getter && !looking_for_setter) return true;
    }

    ASSERT(looking_for_getter || looking_for_setter);
    if (looking_for_getter) {
      report_error(error_position_node,
                   "No getter method '%s' (0 arguments) found.",
                   name.c_str());
    }
    if (looking_for_setter) {
      report_error(error_position_node,
                  "No setter method '%s=' found.",
                  name.c_str());
    }
    return false;
  }

  // If we have more than one candidate, we probably have duplicated globals.
  ASSERT(candidates.nodes.length() == 1 || diagnostics()->encountered_error());
  ASSERT(ir_first_node->is_Local() || ir_first_node->is_Global());

  auto ir_node = ir_first_node;

  if (ir_node->is_Local()) {
    // Invalid assignments to final locals are checked in the definitive-assignment analysis.
    ir_node->as_Local()->register_mutation();
  }

  if (ir_node->is_Global()) {
    auto global = ir_node->as_Global();
    check_sdk_protection(global->name(), error_position_node->range(), global->range());
    if (global->is_final()) {
      report_error(error_position_node, "Can't assign to final global");
      return false;
    } else {
      global->register_mutation();
    }
  }

  *setter_node = ir_node;
  *getter_node = ir_node;
  *block_depth = candidates.block_depth;
  return true;
}

ir::Expression* MethodResolver::_assign_identifier(ast::Binary* node,
                                                   StoreOldValue& store_old) {
  ASSERT(node->left()->is_Identifier() ||
         scope()->is_prefixed_identifier(node->left()) ||
         scope()->is_static_identifier(node->left()));

  auto ast_left = node->left();
  auto ast_right = node->right();
  auto range = node->range();
  // When doing completion or goto-definition we prefer to go through the
  //   "normal" paths.
  if (ast_left->is_Identifier() && !ast_left->is_LspSelection()) {
    // Not prefixed.
    auto name = ast_left->as_Identifier()->data();
    switch (_resolution_mode) {
      case CONSTRUCTOR_STATIC:
      case CONSTRUCTOR_INSTANCE:
      case CONSTRUCTOR_LIMBO_STATIC:
      case CONSTRUCTOR_LIMBO_INSTANCE: {
        // In constructors, accesses to fields are always direct and not virtual.

        auto field_initialization =
            _potentially_store_field(node, name, false, ast_right, store_old);
        if (field_initialization != null) return field_initialization;
        break;
      }

      case FIELD:
      case CONSTRUCTOR_SUPER:
      case INSTANCE:
      case STATIC:
        break;
    }
  }

  ir::Node* ir_setter_node = null;
  ir::Node* ir_getter_node = null;
  int block_depth;
  bool succeeded = _assign_identifier_resolve_left(node, &ir_setter_node, &ir_getter_node, &block_depth);

  if (ast_left->is_LspSelection() ||
      (ast_left->is_Dot() && ast_left->as_Dot()->name()->is_LspSelection())) {
    _handle_lsp_call_identifier(ast_left, ir_getter_node, ir_setter_node);
  }

  if (!succeeded) {
    return _new ir::Error(range, list_of(resolve_expression(ast_right, null, true)));
  }

  bool is_compound = node->kind() != Token::ASSIGN;
  bool is_super = is_literal_super(ast_left);

  if (!is_super &&
      (ir_setter_node->is_Method() && ir_setter_node->as_Method()->is_instance())) {
    // The identifier referred to an instance setter/field.
    switch (_resolution_mode) {
      case CONSTRUCTOR_LIMBO_STATIC:
        // The reference to `this` below will automatically switch state.
        break;

      case CONSTRUCTOR_STATIC:
        report_error(ast_left, "Can't access instance members before `super` call.");
        return _new ir::Error(range, list_of(resolve_expression(ast_right, null, true)));

      case FIELD:
        report_error(ast_left, "Can't access instance members in field initializers.");
        return _new ir::Error(range, list_of(resolve_expression(ast_right, null, true)));

      case INSTANCE:
      case CONSTRUCTOR_INSTANCE:
      case CONSTRUCTOR_LIMBO_INSTANCE:
        // All good.
        break;

      case STATIC: {
        const char* kind = _method->is_factory() ? "factories" : "static contexts";
        report_error(ast_left, "Can't access instance members in %s", kind);
        return _new ir::Error(range, list_of(resolve_expression(ast_right, null, true)));
      }

      case CONSTRUCTOR_SUPER:
        UNREACHABLE();
        break;
    }

    ASSERT(!is_compound || ir_getter_node != null);
    auto selector = ir_setter_node->as_Method()->name();
    return _assign_instance_member(node, selector, store_old);
  }

  std::function<ir::Expression* ()> create_get;
  std::function<ir::Expression* (ir::Expression* value)> create_set;

  if (ir_setter_node->is_Global()) {
    // Don't use locals here, as the closures in this block capture by reference.
    create_get = [&]() {
      return _new ir::ReferenceGlobal(ir_getter_node->as_Global(), true, ast_left->range());
    };
    create_set = [&](ir::Expression* value) {
      return _new ir::AssignmentGlobal(ir_getter_node->as_Global(), value, range);
    };
  } else if (ir_setter_node->is_Local()) {
    // Don't use locals here, as the closures in this block capture by reference.
    create_get = [&]() {
      return _new ir::ReferenceLocal(ir_getter_node->as_Local(), block_depth, ast_left->range());
    };
    create_set = [&](ir::Expression* value) {
      return _typed_assign_local(ir_getter_node->as_Local(),
                                 block_depth,
                                 value,
                                 range);
    };
  } else {
    ASSERT(ir_setter_node->is_Method());
    ASSERT(!ir_setter_node->as_Method()->is_instance() || is_super);
    ASSERT(!ir_setter_node->is_Global());  // Has been handled earlier.
    // Don't use locals here, as the closures in this block capture by reference.
    create_get = [&]() {
      ASSERT(ir_getter_node != null);
      auto getter_method = ir_getter_node->as_Method();
      CallBuilder builder(range);
      if (is_super) builder.add_argument(_this_ref(range), Symbol::invalid());
      return builder.call_static(_new ir::ReferenceMethod(getter_method, range));
    };
    create_set = [&](ir::Expression* value) {
      auto setter_method = ir_setter_node->as_Method();
      CallBuilder builder(range);
      if (is_super) builder.add_argument(_this_ref(range), Symbol::invalid());
      builder.add_argument(value, Symbol::invalid());
      return builder.call_static(_new ir::ReferenceMethod(setter_method, range));
    };
  }

  ir::Expression* ir_value;
  if (is_compound) {
    ir::Expression* old_value = store_old(create_get());
    ir_value = _binary_operator(node, old_value);
    if (ir_value->is_block()) {
      report_error(ast_right, "Can't use block value in assignment");
      ir_value = _new ir::Error(ast_right->range(), list_of(ir_value));
    }
  } else {
    ir_value = resolve_expression(ast_right, "Can't use block value in assignment", true);
  }
  auto result = create_set(ir_value);
  if (result->is_AssignmentLocal()) {
    bool reported_warning = false;
    auto assig = result->as_AssignmentLocal();
    auto local = assig->local();
    auto right = assig->right();
    if (right->is_ReferenceLocal() && right->as_ReferenceLocal()->target() == local) {
      if (_method->is_constructor() || _method->is_instance()) {
        auto fields = _method->holder()->fields();
        for (int i = 0; i < fields.length(); i++) {
          auto field_name = fields[i]->name();
          if (field_name.is_valid() && field_name == local->name()) {
            diagnostics()->report_warning(node, "Assigning local to itself has no effect. Did you forget 'this.'?");
            reported_warning = true;
            break;
          }
        }
      }
      if (!reported_warning) {
        diagnostics()->report_warning(node, "Assigning local to itself");
      }
    }
  }
  return result;
}


static Token::Kind compute_effective_operation(Token::Kind kind) {
  switch (kind) {
    case Token::ASSIGN_BIT_OR:   return Token::BIT_OR;
    case Token::ASSIGN_BIT_XOR:  return Token::BIT_XOR;
    case Token::ASSIGN_BIT_AND:  return Token::BIT_AND;
    case Token::ASSIGN_BIT_SHL:  return Token::BIT_SHL;
    case Token::ASSIGN_BIT_SHR:  return Token::BIT_SHR;
    case Token::ASSIGN_BIT_USHR: return Token::BIT_USHR;
    case Token::ASSIGN_ADD:      return Token::ADD;
    case Token::ASSIGN_SUB:      return Token::SUB;
    case Token::ASSIGN_MUL:      return Token::MUL;
    case Token::ASSIGN_DIV:      return Token::DIV;
    case Token::ASSIGN_MOD:      return Token::MOD;
    default:                     return kind;
  }
}

static bool is_binary_comparison(ast::Node* node) {
  if (!node->is_Binary()) return false;
  switch (node->as_Binary()->kind()) {
    case Token::LT:
    case Token::LTE:
    case Token::GT:
    case Token::GTE:
      return true;

    default:
      return false;
  }
}

ir::Expression* MethodResolver::_binary_operator(ast::Binary* node,
                                                 ir::Expression* ir_left,
                                                 ir::Expression* ir_right) {
  if (ir_left == null) {
    ir_left = resolve_expression(node->left(), "Can't use blocks in binary expression");
  }
  if (ir_right == null) {
    ir_right = resolve_expression(node->right(), "Can't use blocks in binary expression");
  }
  auto kind = node->kind();
  bool inverted = false;
  if (kind == Token::NE) {
    kind = Token::EQ;
    inverted = true;
  }
  auto op = Token::symbol(compute_effective_operation(kind));
  auto right_args = list_of(ir_right);
  auto result = _new ir::CallVirtual(_new ir::Dot(ir_left, op),
                                     CallShape::for_instance_call_no_named(right_args),
                                     right_args,
                                     node->range());
  if (inverted) return _new ir::Not(result, node->range());
  return result;
}

ir::Expression* MethodResolver::_binary_comparison_operator(ast::Binary* node,
                                                            ir::Local* temporary) {
  ASSERT(is_binary_comparison(node));
  if (!is_binary_comparison(node->left())) {
    auto ir_left = resolve_expression(node->left(), "Can't use blocks in comparison");
    auto ir_right = resolve_expression(node->right(), "Can't use blocks in comparison");
    if (temporary != null) {
      ir_right = _new ir::AssignmentLocal(temporary, 0, ir_right, node->range());
    }
    return _binary_operator(node, ir_left, ir_right);
  }

  bool outer_most = false;
  if (temporary == null) {
    outer_most = true;
    temporary = _new ir::Local(Symbol::synthetic("<tmp_comp>"),
                               false,  // Not final.
                               false,  // Not a block.
                               node->range());
  }
  auto left_comparison = _binary_comparison_operator(node->left()->as_Binary(), temporary);

  // Now do the right comparison using the temporary from the left comparison.
  auto ir_left = _new ir::ReferenceLocal(temporary, 0, node->left()->range());
  auto ir_right = resolve_expression(node->right(), "Can't use blocks in comparison");
  if (!outer_most) {
    ir_right = _new ir::AssignmentLocal(temporary, 0, ir_right, node->range());
  }
  auto right_comparison = _binary_operator(node, ir_left, ir_right);

  auto binary_and = _new ir::LogicalBinary(left_comparison,
                                           right_comparison,
                                           ir::LogicalBinary::AND,
                                           node->range());
  if (!outer_most) return binary_and;

  // We need to have the definition of the local outside the left-comparison, as
  // we would otherwise pop the value too early.
  auto define = _new ir::AssignmentDefine(temporary, _new ir::LiteralUndefined(node->range()), node->range());
  return _new ir::Sequence(list_of(define, binary_and), node->range());
}

ir::Expression* MethodResolver::_logical_operator(ast::Binary* node) {
  auto ir_left = resolve_expression(node->left(), "Can't use blocks in logical expression");
  auto ir_right = resolve_expression(node->right(), "Can't use blocks in logical expression");
  auto op = node->kind() == Token::LOGICAL_AND
      ? ir::LogicalBinary::AND
      : ir::LogicalBinary::OR;
  return _new ir::LogicalBinary(ir_left, ir_right, op, node->range());
}

void MethodResolver::visit_Binary(ast::Binary* node) {
  switch (node->kind()) {
    case Token::DEFINE:
    case Token::DEFINE_FINAL:
      report_error(node, "Definition of variable not allowed at this location");
      push(_bad_define(node));  // Don't add to scope.
      break;

    case Token::ASSIGN:
      report_error(node, "Assignment to variable not allowed at this location");
      [[fallthrough]];

    case Token::ASSIGN_ADD:
    case Token::ASSIGN_BIT_AND:
    case Token::ASSIGN_BIT_OR:
    case Token::ASSIGN_BIT_SHL:
    case Token::ASSIGN_BIT_SHR:
    case Token::ASSIGN_BIT_USHR:
    case Token::ASSIGN_BIT_XOR:
    case Token::ASSIGN_DIV:
    case Token::ASSIGN_MOD:
    case Token::ASSIGN_MUL:
    case Token::ASSIGN_SUB:
      push(_assign(node));
      break;

    case Token::AS:
    case Token::IS:
    case Token::IS_NOT:
      push(_as_or_is(node));
      break;

    case Token::LT:
    case Token::GT:
    case Token::LTE:
    case Token::GTE:
      push(_binary_comparison_operator(node));
      break;

    case Token::EQ:
    case Token::NE:
    case Token::ADD:
    case Token::BIT_AND:
    case Token::BIT_OR:
    case Token::BIT_SHL:
    case Token::BIT_SHR:
    case Token::BIT_USHR:
    case Token::BIT_XOR:
    case Token::DIV:
    case Token::MOD:
    case Token::MUL:
    case Token::SUB:
      push(_binary_operator(node));
      break;

    case Token::LOGICAL_AND:
    case Token::LOGICAL_OR:
      push(_logical_operator(node));
      break;

    default:
      UNREACHABLE();
  }
}

void MethodResolver::visit_Unary(ast::Unary* node) {
  switch(node->kind()) {
    case Token::INCREMENT:
    case Token::DECREMENT: {
      bool is_postfix = !node->prefix();
      Token::Kind operation = (node->kind() == Token::INCREMENT)
          ? Token::ASSIGN_ADD
          : Token::ASSIGN_SUB;
      // We can't allocate the following nodes on the stack, as
      // a field-store might retain them to give a better error message.
      auto one = _new ast::LiteralInteger(Symbols::one);
      one->set_range(node->range());
      auto assign = _new ast::Binary(operation, node->expression(), one);
      assign->set_range(node->range());
      push(_assign(assign, is_postfix));
      break;
    }

    case Token::NOT: {
      push(_new ir::Not(resolve_expression(node->expression(), "Can't negate blocks"), node->range()));
      break;
    }

    case Token::SUB:
    case Token::BIT_NOT: {
      auto error_message = node->kind() == Token::SUB
          ? "Can't minus blocks"
          : "Can't bit-not blocks";
      auto receiver = resolve_expression(node->expression(), error_message);
      auto no_args = List<ir::Expression*>();
      push(_new ir::CallVirtual(_new ir::Dot(receiver, Token::symbol(node->kind())),
                                CallShape::for_instance_call_no_named(no_args),
                                no_args,
                                node->range()));
      break;
    }

    default:
      UNREACHABLE();
  }
}

void MethodResolver::visit_LiteralNull(ast::LiteralNull* node) {
  push(_new ir::LiteralNull(node->range()));
}

void MethodResolver::visit_LiteralUndefined(ast::LiteralUndefined* node) {
  push(_new ir::LiteralUndefined(node->range()));
}

const char* strip_underscores(const char* str) {
  if (strchr(str, '_') == null) return str;
  char* stripped = unvoid_cast<char*>(malloc(strlen(str)));
  int len = strlen(str);
  int pos = 0;
  for (int i = 0; i < len; i++) {
    if (str[i] != '_') stripped[pos++] = str[i];
  }
  stripped[pos] = '\0';
  return stripped;
}

void MethodResolver::visit_LiteralInteger(ast::LiteralInteger* node) {
  const char* str = strip_underscores(node->data().c_str());

  int base = 10;
  if (str[0] == '0' && (str[1] == 'b' || str[1] == 'B')) {
    base = 2;
  } else if (str[0] == '0' && (str[1] == 'x' || str[1] == 'X')) {
    base = 16;
  }

  int64 value;
  if (base != 10) {
    // Binary and hex are not allowed to be negated.
    if (node->is_negated()) {
      report_error(node, "%s literals may not be negated", base == 2 ? "Binary" : "Hex");
    }
    errno = 0;
    uint64 unsigned_value = strtoull(str + 2, null, base);
    if (unsigned_value == UINT64_MAX && errno == ERANGE) {
      report_error(node, "Literal doesn't fit 64 bits");
    }
    value = static_cast<int64>(unsigned_value);
    if (node->is_negated()) value = -value;  // Only happens in error case.
  } else {
    // We force the base to be 10, to avoid reading octal values.
    errno = 0;
    uint64 unsigned_value = strtoull(str, null, 10);
    if ((node->is_negated() && unsigned_value > (static_cast<uint64>(INT64_MAX) + 1)) ||
        (!node->is_negated() && unsigned_value > (static_cast<uint64>(INT64_MAX)))) {
      report_error(node, "Literal doesn't fit 64 bits");
    }
    if (node->is_negated() && unsigned_value == static_cast<uint64>(INT64_MAX) + 1) {
      value = -INT64_MAX - 1;
    } else {
      value = static_cast<int64>(unsigned_value);
      if (node->is_negated()) value = -value;
    }
  }
  push(_new ir::LiteralInteger(value, node->range()));
}

void MethodResolver::visit_LiteralString(ast::LiteralString* node,
                                         int min_indentation,
                                         bool should_skip_leading) {
  bool is_multiline = node->is_multiline();
  const char* content = node->data().c_str();
  int length;
  if (min_indentation == -1) {
    if (is_multiline) {
      bool contains_newline = false;
      find_min_indentation(content, true, &min_indentation, &contains_newline);
      // If there is no newline, don't remove any indentation.
      if (!contains_newline) min_indentation = 0;
    } else {
      min_indentation = 0;
    }
  }
  const char* result = convert_string_content(content,
                                              min_indentation,
                                              should_skip_leading,
                                              is_multiline,
                                              &length);
  if (result == null) {
    report_error(node, "Invalid string: '%s'\n", content);
    result = "";
  }
  push(_new ir::LiteralString(result, length, node->range()));
}

ir::Expression* MethodResolver::_accumulate_concatenation(ir::Expression* lhs, ir::Expression* rhs, Source::Range range) {
  if (lhs == null) return rhs;
  if (rhs == null) return lhs;
  auto op = Token::symbol(compute_effective_operation(Token::ADD));
  auto dot = _new ir::Dot(lhs, op);
  auto args = list_of(rhs);
  auto plus = _new ir::CallVirtual(dot,
                                   CallShape::for_instance_call_no_named(args),
                                   args,
                                   range);
  return plus;
}

void MethodResolver::visit_LiteralStringInterpolation(ast::LiteralStringInterpolation* node) {
  ASSERT(node->parts().length() > 0);
  ASSERT(node->expressions().length() == node->parts().length() - 1);
  ASSERT(node->formats().length() == node->expressions().length());

  auto parts = node->parts();
  bool is_multiline = parts[0]->is_multiline();
  int min_indentation = 0;
  bool contains_newline = false;
  if (is_multiline) {
    min_indentation = -1;
    find_min_indentation(parts[0]->data().c_str(),
                         true,
                         &min_indentation,
                         &contains_newline);
    for (int i = 1; i < parts.length(); i++) {
      find_min_indentation(parts[i]->data().c_str(),
                           false,  // Not string start.
                           &min_indentation,
                           &contains_newline);
    }
    // Don't remove leading whitespace if the multiline string doesn't have any
    //   newline.
    if (!contains_newline) min_indentation = 0;
  }

  if (parts.length() == 2 && node->formats()[0] == null) {
    // Super-simple case has no format string and only one interpolated value.
    auto left_expression = node->parts()[0];
    auto right_expression = node->parts()[1];

    ir::Expression* left = null;
    if (left_expression->data().c_str()[0] != '\0') {
      visit_LiteralString(left_expression, min_indentation, true);
      auto ir_node = pop();
      ASSERT(ir_node->is_Expression());
      left = ir_node->as_Expression();
    }
    ir::Expression* right = null;
    if (right_expression->data().c_str()[0] != '\0') {
      visit_LiteralString(right_expression, min_indentation, false);
      auto ir_node = pop();
      ASSERT(ir_node->is_Expression());
      right = ir_node->as_Expression();
    }

    auto expression = node->expressions()[0];
    auto center = resolve_expression(expression,
                                   "Can't have a block as interpolated entry in a string");
    // Just call stringify.
    auto dot = _new ir::Dot(center, Symbols::stringify);
    List<ir::Expression*> no_args;
    auto stringify = _new ir::CallVirtual(dot,
                                          CallShape::for_instance_call_no_named(no_args),
                                          no_args,
                                          node->range());
    ir::Expression* accumulator = null;
    accumulator = _accumulate_concatenation(accumulator, left, node->range());
    accumulator = _accumulate_concatenation(accumulator, stringify, node->range());
    accumulator = _accumulate_concatenation(accumulator, right, node->range());
    push(accumulator);
    return;
  }

  ListBuilder<ir::Expression*> array_entries;
  visit_LiteralString(parts[0], min_indentation, true);
  auto ir_node = pop();
  ASSERT(ir_node->is_Expression());
  array_entries.add(ir_node->as_Expression());

  bool has_formats = false;
  for (int i = 1; i < parts.length(); i++) {
    auto format = node->formats()[i - 1];
    if (format != null) {
      has_formats = true;
      break;
    }
  }

  for (int i = 1; i < parts.length(); i++) {
    auto format = node->formats()[i - 1];
    auto expression = node->expressions()[i - 1];
    auto string_part = parts[i];

    if (has_formats) {
      if (format == null) {
        array_entries.add(_new ir::LiteralNull(node->range()));
      } else {
        visit_LiteralString(format);
        auto ir_entry_node = pop();
        ASSERT(ir_entry_node->is_Expression());
        array_entries.add(ir_entry_node->as_Expression());
      }
    }

    auto ir_expression = resolve_expression(expression,
                                          "Can't have a block as interpolated entry in a string");
    array_entries.add(ir_expression);

    visit_LiteralString(string_part, min_indentation, false);
    auto ir_entry_node = pop();
    ASSERT(ir_entry_node->is_Expression());
    array_entries.add(ir_entry_node->as_Expression());
  }

  auto array = _create_array(array_entries.build(), node->range());
  if (has_formats) {
    push(_call_runtime(Symbols::interpolate_strings_, list_of(array), node->range()));
  } else {
    push(_call_runtime(Symbols::simple_interpolate_strings_, list_of(array), node->range()));
  }
}

void MethodResolver::visit_LiteralBoolean(ast::LiteralBoolean* node) {
  push(_new ir::LiteralBoolean(node->value(), node->range()));
}

void MethodResolver::visit_LiteralFloat(ast::LiteralFloat* node) {
  errno = 0;
  double value = strtod(strip_underscores(node->data().c_str()), null);
  // Normally, HUGE_VAL is equal no infinity, but this way the code is cleaner
  // and (in theory) more platform independent.
  if (isinf(value) || (value == HUGE_VAL && errno == ERANGE)) {
    report_error(node, "Floating-point value out of range");
  }
  if (node->is_negated()) value = -value;
  push(_new ir::LiteralFloat(value, node->range()));
}

void MethodResolver::visit_LiteralCharacter(ast::LiteralCharacter* node) {
  const char* content = node->data().c_str();
  int length;
  const char* result = convert_string_content(content, 0, false, false, &length);
  // We got a short UTF-8 string, but now we want a single Unicode code point,
  // so we have to reverse the UTF-8 encoding.
  int characters = 0;
  if (result != null) {
    for (int i = 0; i < length; i++) {
      int byte = result[i] & 0xff;
      if (byte <= Utils::MAX_ASCII || Utils::is_utf_8_prefix(byte)) characters++;
    }
  }
  int value;
  if (characters != 1) {
    report_error(node, "Invalid character '%s'", content);
    value = 0;
  } else {
    if (length == 1) {
      value = result[0];
    } else {
      int c = result[0] & 0xff;
      c = Utils::payload_from_prefix(c);
      for (int i = 1; i < length; i++) {
        c <<= Utils::UTF_8_BITS_PER_BYTE;
        c |= result[i] & Utils::UTF_8_MASK;
      }
      value = c;
    }
  }
  push(_new ir::LiteralInteger(value, node->range()));
}

void MethodResolver::visit_LiteralList(ast::LiteralList* node) {
  auto ir_elements = ListBuilder<ir::Expression*>::allocate(node->elements().length());
  int length = node->elements().length();
  for (int i = 0; i < length; i++) {
    auto element = node->elements()[i];
    auto ir_expression = resolve_expression(element, "List elements may not be blocks");
    ir_elements[i] = ir_expression;
  }

  auto ir_array = _create_array(ir_elements, node->range());
  push(_call_runtime(Symbols::create_list_literal_from_array_, list_of(ir_array), node->range()));
}

void MethodResolver::visit_LiteralByteArray(ast::LiteralByteArray* node) {
  auto range = node->range();
  auto ir_elements = ListBuilder<ir::Expression*>::allocate(node->elements().length());
  bool is_filled_with_literal_ints = true;
  int length = node->elements().length();
  auto data = ListBuilder<uint8>::allocate(length);
  for (int i = 0; i < length; i++) {
    auto element = node->elements()[i];
    auto ir_expression = resolve_expression(element, "ByteArray elements may not be blocks");
    ir_elements[i] = ir_expression;
    if (!ir_expression->is_LiteralInteger()) {
      is_filled_with_literal_ints = false;
    } else {
      auto integer = ir_expression->as_LiteralInteger();
      int64 value = integer->value();
      if (value < 0 || value >= 0x100) {
        diagnostics()->report_warning(element->range(), "Byte-array element not in range 0-255");
      }
      data[i] = value & 0xFF;
    }
  }


  auto length_literal = _new ir::LiteralInteger(ir_elements.length(), range);
  ir::Expression* ir_byte_array;
  if (length == 0) {
    ir_byte_array = _instantiate_runtime(Symbols::ByteArray_, list_of(length_literal), range);
  } else if (ir_elements.length() < 4) {
    ir_byte_array = _call_runtime(Symbols::create_byte_array_, ir_elements, range);
  } else if (is_filled_with_literal_ints) {
    // If we can see that all values are literal integers we can create a
    // Copy-on-Write byte-array which is backed by read-only data.
    ir_byte_array = _call_runtime(Symbols::create_cow_byte_array_,
                        list_of(_new ir::LiteralByteArray(data, range)),
                        range);
  } else {
    // We don't know whether all elements are integer literals.
    // As such we just build up the Byte-array and fill in the values.
    // If the static types are wrong (like storing a string in it), then the
    // type-checker will complain in a later phase.
    ListBuilder<ir::Expression*> expressions;

    auto array_construction = _instantiate_runtime(Symbols::ByteArray_, list_of(length_literal), range);

    auto temporary = _new ir::Local(Symbol::synthetic("<bytes>"),
                                    true,   // Final.
                                    false,  // Not a block.
                                    range);
    auto define = _new ir::AssignmentDefine(temporary, array_construction, range);

    expressions.add(define);

    for (int i = 0 ; i < ir_elements.length(); i++) {
      auto dot = _new ir::Dot(_new ir::ReferenceLocal(temporary, 0, range), Symbols::index_put);
      auto args = list_of(_new ir::LiteralInteger(i, range), ir_elements[i]);
      auto put_call = _new ir::CallVirtual(dot,
                                           CallShape::for_instance_call_no_named(args),
                                           args,
                                           range);
      expressions.add(put_call);
    }
    // The last expression of the sequence is the return value.
    expressions.add(_new ir::ReferenceLocal(temporary, 0, range));
    ir_byte_array = _new ir::Sequence(expressions.build(), range);
  }
  // We want all these expressions to have the inferred type `ByteArray`.
  auto byte_array_entry = _core_module->scope()->lookup_shallow(Symbols::ByteArray);
  ASSERT(byte_array_entry.is_class());
  auto byte_array_class = byte_array_entry.klass();
  ASSERT(byte_array_class->is_interface());
  ir::Type byte_array_type(byte_array_class);
  // The following type-check will be removed by later optimizations (since we
  // statically know that the 'ir_byte_array' expression implements the right
  // type. However, it makes the type-inference assign the correct type to
  // the expression.
  push(_new ir::Typecheck(ir::Typecheck::AS_CHECK,
                          ir_byte_array,
                          byte_array_type,
                          byte_array_type.klass()->name(),
                          range));
}

void MethodResolver::visit_LiteralSet(ast::LiteralSet* node) {
  ListBuilder<ir::Expression*> expressions;

  auto allocated_set = _instantiate_runtime(Symbols::Set, List<ir::Expression*>(), node->range());
  auto temporary = _new ir::Local(Symbol::synthetic("<tmp>"),
                                  true,   // Final.
                                  false,  // Not a block.
                                  node->range());
  auto define = _new ir::AssignmentDefine(temporary, allocated_set, node->range());
  expressions.add(define);

  for (auto element : node->elements()) {
    auto ir_expression = resolve_expression(element, "Set elements may not be blocks");
    auto dot = _new ir::Dot(_new ir::ReferenceLocal(temporary, 0, node->range()),
                            Symbols::add);
    auto args = list_of(ir_expression);
    auto push = _new ir::CallVirtual(dot,
                                     CallShape::for_instance_call_no_named(args),
                                     args,
                                     element->range());
    expressions.add(push);
  }
  expressions.add(_new ir::ReferenceLocal(temporary, 0, node->range()));

  push(_new ir::Sequence(expressions.build(), node->range()));
}

void MethodResolver::visit_LiteralMap(ast::LiteralMap* node) {
  ListBuilder<ir::Expression*> expressions;

  auto allocated_set = _instantiate_runtime(Symbols::Map, List<ir::Expression*>(), node->range());
  auto temporary = _new ir::Local(Symbol::synthetic("<tmp>"),
                                  true,   // Final.
                                  false,  // Not a block.
                                  node->range());
  auto define = _new ir::AssignmentDefine(temporary, allocated_set, node->range());
  expressions.add(define);

  auto ast_keys = node->keys();
  auto ast_values = node->values();
  for (int i = 0; i < ast_keys.length(); i++) {
    auto ir_key = resolve_expression(ast_keys[i], "Map keys may not be blocks");
    auto ir_value = resolve_expression(ast_values[i], "Map values may not be blocks");
    auto dot = _new ir::Dot(_new ir::ReferenceLocal(temporary, 0, node->range()),
                            Symbols::index_put);
    auto args = list_of(ir_key, ir_value);
    auto push = _new ir::CallVirtual(dot,
                                     CallShape::for_instance_call_no_named(args),
                                     args,
                                     ast_values[i]->range());
    expressions.add(push);
  }
  expressions.add(_new ir::ReferenceLocal(temporary, 0, node->range()));

  push(_new ir::Sequence(expressions.build(), node->range()));
}

void MethodResolver::visit_call_main(ast::Call* node) {
  if (node->arguments().length() != 1) {
    report_error("Main primitive call must have one arguments");
    push(_new ir::Error(node->range()));
    return;
  }
  ir::Method* main_method = null;
  bool takes_args = false;
  for (int main_arity = 1; main_arity >= 0; main_arity--) {
    auto main_shape = ResolutionShape(main_arity);
    auto main_entry = _entry_module->scope()->lookup_module(Symbols::main);
    switch (main_entry.kind()) {
      case ResolutionEntry::PREFIX:
      case ResolutionEntry::AMBIGUOUS:
        // Module lookups should never yield prefix or ambiguous entries.
        UNREACHABLE();
        break;
      case ResolutionEntry::NODES:
        for (auto candidate : main_entry.nodes()) {
          if (!candidate->is_Method()) continue;
          auto method = candidate->as_Method();
          if (method->resolution_shape() == main_shape) {
            takes_args = (main_arity == 1);
            main_method = method;
            break;
          }
        }
    }
  }
  if (main_method == null) {
    if (diagnostics()->should_report_missing_main()) {
      auto error_path = _entry_module->unit()->error_path();
      report_error("Couldn't find 'main' (with 0 or 1 argument) in entry file '%s'",
                   error_path.c_str());
      push(_new ir::Error(node->range()));
    } else {
      push(_new ir::Nop(node->range()));
    }
  } else {
    auto ref = _new ir::ReferenceMethod(main_method, node->range());
    CallBuilder builder(node->range());
    ir::Expression* arg = resolve_expression(node->arguments()[0],
                                             "Argument to main intrinsic must not be a block");
    // The `arg` expression is dropped if `main` doesn't take an argument.
    // This is different from normal calls, since the evaluation at runtime is thus not
    // guaranteed.
    // However, here this is exactly what we want, as we don't want to waste time
    // building the args-array, if the user doesn't need it anyway.
    if (takes_args) {
      builder.add_argument(arg, Symbol::invalid());
    }
    push(builder.call_static(ref));
  }
}

void MethodResolver::visit_call_primitive(ast::Call* node) {
  auto target = node->target();
  auto arguments = node->arguments();
  ast::Identifier* module_node = null;
  ast::Identifier* primitive_node = null;
  Symbol module_name = Symbol::invalid();
  Symbol primitive_name = Symbol::invalid();

  bool encountered_error = false;
  int module = 0;
  int index = 0;

  if (!target->is_Dot()) {
    report_error(node, "Missing library name");
    encountered_error = true;
  } else {
    auto outer_dot = target->as_Dot();
    if (outer_dot->receiver()->is_Identifier()) {
      ASSERT(outer_dot->receiver()->as_Identifier()->data() == Token::symbol(Token::PRIMITIVE));
      // Only one dot, which we will use as module name.
      report_error(target, "Missing primitive name");
      encountered_error = true;
      module_node = outer_dot->name();
      module_name = outer_dot->name()->data();
    } else if (!outer_dot->receiver()->is_Dot()) {
      report_error(target, "Invalid primitive call");
      encountered_error = true;
    } else {
      auto inner_dot = outer_dot->receiver()->as_Dot();
      if (!inner_dot->receiver()->is_Identifier()) {
        report_error(inner_dot, "Invalid primitive call");
        encountered_error = true;
      } else {
        ASSERT(inner_dot->receiver()->as_Identifier()->data() == Token::symbol(Token::PRIMITIVE));
        module_node = inner_dot->name();
        module_name = inner_dot->name()->data();
        primitive_node = outer_dot->name();
        primitive_name = outer_dot->name()->data();
      }
    }
  }

  if (module_name == Symbols::intrinsics) {
    if (primitive_name.is_valid() &&
        primitive_name != Symbols::array_do &&
        primitive_name != Symbols::hash_find &&
        primitive_name != Symbols::hash_do &&
        primitive_name != Symbols::smi_repeat &&
        primitive_name != Symbols::main) {
      report_error(primitive_node, "Unknown intrinsic '%s'\n", primitive_name.c_str());
      encountered_error = true;
    }
    if (primitive_name == Symbols::main) {
      visit_call_main(node);
      return;
    }
  } else {
    if (module_name.is_valid()) {
      module = PrimitiveResolver::find_module(module_name);
      if (module < 0) {
        report_error(module_node, "Unknown primitive library '%s'\n", module_name.c_str());
        encountered_error = true;
      }
    } else {
      ASSERT(diagnostics()->encountered_error());
      encountered_error = true;
    }

    index = -1;
    if (!encountered_error) {
      if (primitive_name.is_valid()) {
        index = PrimitiveResolver::find_primitive(primitive_name, module);
        if (index < 0) {
          report_error(primitive_node,
                       "Unknown primitive '%s' in library '%s'\n",
                       primitive_name.c_str(),
                       module_name.c_str());
          encountered_error = true;
        }
      } else {
        ASSERT(diagnostics()->encountered_error());
        encountered_error = true;
      }
    }

    if (!encountered_error) {
      int primitive_arity = PrimitiveResolver::arity(index, module);
      if (primitive_arity != _method->parameters().length()) {
        report_error(_method,
                    "Primitive '%s:%s' takes %d parameters\n",
                    module_name.c_str(),
                    primitive_name.c_str(),
                    primitive_arity);
        encountered_error = true;
      }
    }
  }

  if ((module_node != null && module_node->is_LspSelection()) ||
      (primitive_node != null && primitive_node->is_LspSelection())) {
    ASSERT(module_node != null);
    ast::Node* selected_node = module_node->is_LspSelection() ? module_node : primitive_node;
    _lsp->selection_handler()->call_primitive(selected_node, module_name, primitive_name, module, index,
                                              selected_node == module_node);
  }
  ir::Expression* invocation;
  if (encountered_error) {
    invocation = _new ir::Error(node->range());
  } else {
    invocation = _new ir::PrimitiveInvocation(module_name, primitive_name, module, index, node->range());
    _has_primitive_invocation = true;
  }

  ast::Block* ast_failure = null;
  if (arguments.length() == 1) {
    if (arguments[0]->is_Block()) {
      ast_failure = arguments[0]->as_Block();
    } else {
      report_error(arguments[0], "Third argument to primitive call must be a failure block");
      // No need to set the `encountered_error`.
    }
  } else if (arguments.length() > 1) {
    report_error(arguments[1]->range().extend(arguments.last()->range()),
                 "Spurious arguments to primitive call");
    // No need to set the `encountered_error`.
  }

  if (ast_failure == null) {
    if (encountered_error) {
      push(invocation);
    } else {
      // The invocation has a "non-local return" if it succeeds.
      push(_create_throw(invocation, node->range()));
    }
  } else {
    if (ast_failure->parameters().length() > 1) {
      report_error(ast_failure, "Failure blocks can take at most one argument");
    }

    LocalScope scope(_scope);
    _scope = &scope;
    ir::Local* parameter_local;
    if (ast_failure->parameters().length() == 1) {
      auto ast_parameter = ast_failure->parameters()[0];
      if (ast_parameter->is_field_storing()) {
        report_error(ast_parameter, "Failure blocks can't have field-storing parameters");
      }
      if (ast_parameter->type() != null) {
        report_error(ast_parameter, "Failure parameter can't have a type");
      }
      if (ast_parameter->default_value() != null) {
        report_error(ast_parameter, "Failure parameter can't have a default value");
      }
      Symbol name = ast_parameter->name()->data();
      parameter_local = _new ir::Local(name,
                                       false,  // Not final.
                                       false,  // Not a block.
                                       ast_parameter->range());
    } else {
      parameter_local = _new ir::Local(Symbols::it,
                                       false,  // Not final.
                                       false,  // Not a block.
                                       ast_failure->range());
    }
    auto define = _new ir::AssignmentDefine(parameter_local, invocation, node->range());
    scope.add(parameter_local->name(), ResolutionEntry(parameter_local));
    push(_new ir::Sequence(list_of(define, resolve_expression(ast_failure->body(), null)),
                           node->range()));
    ASSERT(_scope == &scope);
    _scope = scope.outer();
  }
}

void MethodResolver::visit_Parenthesis(ast::Parenthesis* node) {
  visit(node->expression());
}

} // namespace toit::compiler
} // namespace toit
