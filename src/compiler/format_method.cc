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

#include "format_method.h"

#include "../top.h"
#include "ast.h"
#include "format_trivia.h"
#include "sources.h"

#include <algorithm>
#include <cstring>

namespace toit {
namespace compiler {

class MethodHeaderLowering {
 public:
  MethodHeaderLowering(Source* source,
                       LayoutBuilder* layouts,
                       LogicalOperatorBindings* bindings,
                       SyntaxProtection* syntax,
                       const FormatStyle& style,
                       TriviaLowering* trivia)
      : source_(source)
      , layouts_(layouts)
      , bindings_(bindings)
      , syntax_(syntax)
      , style_(style)
      , trivia_(trivia) {}

  LoweredMethodHeader lower(ast::Method* method) {
    ASSERT(method != null);

    int header_from = start(method);
    int signature_end = end(method->name_or_dot());
    for (ast::Parameter* parameter : method->parameters()) {
      signature_end = std::max(signature_end, end(parameter));
    }
    if (method->return_type() != null) {
      signature_end = std::max(signature_end, end(method->return_type()));
    }
    int header_limit = end(method);
    if (method->body() != null && !method->body()->expressions().is_empty()) {
      header_limit = start(method->body()->expressions().first());
    }
    int colon_offset = method->body() == null
                           ? -1
                           : find_syntax(signature_end, header_limit, ":");

    if (trivia_ != null) {
      int frozen_limit = colon_offset < 0 ? signature_end : colon_offset + 1;
      int line_comment =
          trivia_->first_line_comment(header_from, frozen_limit, true);
      if (line_comment >= 0) {
        // Token movement across a verbatim line would contradict the rule that
        // only its indentation may change. Preserve this complete header as
        // the current conservative replacement unit and expose no semantic
        // return piece to the exceptional placement pass.
        frozen_limit =
            std::max(frozen_limit, trivia_->comment(line_comment).to);
        Layout* frozen = trivia_->verbatim_region(header_from, frozen_limit);
        return LoweredMethodHeader(layouts_, frozen, frozen, {}, null, null,
                                   LayoutMarker(), LayoutMarker(),
                                   style_.continuation_step);
      }
    }

    std::vector<Layout*> name_parts;
    if (method->is_abstract()) name_parts.push_back(layouts_->text("abstract "));
    if (method->is_static()) name_parts.push_back(layouts_->text("static "));
    name_parts.push_back(layouts_->text(method_name(method->name_or_dot())));
    Layout* name = layouts_->concat(std::move(name_parts));
    if (method->is_setter()) {
      name = layouts_->concat({name, layouts_->text("=")});
    }

    int name_limit =
        next_component_after(end(method->name_or_dot()), method, colon_offset);
    if (trivia_ != null && name_limit >= 0) {
      name = trivia_->take_inline_suffix(name, end(method->name_or_dot()),
                                         name_limit);
    }

    std::vector<Layout*> parameters;
    for (int i = 0; i < method->parameters().length(); i++) {
      ast::Parameter* parameter = method->parameters()[i];
      int limit = next_component_after(end(parameter), method, colon_offset);
      parameters.push_back(lower_parameter(parameter, limit));
    }

    Layout* return_type = method->return_type() == null
        ? null
        : lower_type(method->return_type());
    if (return_type != null && trivia_ != null) {
      int type_start = start(method->return_type());
      // A default value may itself contain the bytes `->` (for example in a
      // string). The grammar's return arrow is the last such spelling before
      // the return type; comments are skipped by find_syntax.
      int arrow = -1;
      int search_from = header_from;
      while (true) {
        int candidate = trivia_->find_syntax(search_from, type_start, "->");
        if (candidate < 0) break;
        arrow = candidate;
        search_from = candidate + 2;
      }
      if (arrow >= 0) {
        return_type =
            trivia_->take_inline_prefix(return_type, arrow + 2, type_start);
      }
      int return_limit = next_component_after(end(method->return_type()),
                                              method, colon_offset);
      if (return_limit >= 0) {
        return_type = trivia_->take_inline_suffix(
            return_type, end(method->return_type()), return_limit);
      }
    }

    Layout* colon = null;
    if (colon_offset >= 0) {
      colon = layouts_->text(":");
      if (trivia_ != null) {
        int line_end = colon_offset + 1;
        while (line_end < source_->size() &&
               source_->text()[line_end] != '\n' &&
               source_->text()[line_end] != '\r') {
          line_end++;
        }
        colon = trivia_->take_inline_suffix(colon, colon_offset + 1, line_end);
      }
    }
    LayoutMarker parameters_start = layouts_->marker();
    LayoutMarker parameters_end = layouts_->marker();
    Layout* regular_parameters =
        regular_parameter_list(parameters, parameters_start, parameters_end);

    std::vector<Layout*> source_order = {name, regular_parameters};
    if (return_type != null) {
      // This is the only ordering generic method lowering constructs. It is
      // correct even when the group breaks; the dedicated pass may later
      // construct a different ordering from the private semantic pieces.
      source_order.push_back(layouts_->text(" -> "));
      source_order.push_back(return_type);
    }
    if (colon != null) source_order.push_back(colon);

    Layout* source_order_layout =
        layouts_->group(layouts_->concat(std::move(source_order)));
    return LoweredMethodHeader(
        layouts_, source_order_layout, name, std::move(parameters), return_type,
        colon, parameters_start, parameters_end, style_.continuation_step);
  }

 private:
  Source* source_;
  LayoutBuilder* layouts_;
  LogicalOperatorBindings* bindings_;
  SyntaxProtection* syntax_;
  const FormatStyle& style_;
  TriviaLowering* trivia_;

  int start(ast::Node* node) const {
    return source_->offset_in_source(node->full_range().from());
  }

  int end(ast::Node* node) const {
    return source_->offset_in_source(node->full_range().to());
  }

  int find_syntax(int from, int to, const char* syntax) const {
    if (trivia_ != null) return trivia_->find_syntax(from, to, syntax);
    int length = std::strlen(syntax);
    const uint8* text = source_->text();
    for (int offset = from; offset + length <= to; offset++) {
      if (std::memcmp(text + offset, syntax, length) == 0) return offset;
    }
    return -1;
  }

  int next_component_after(int offset,
                           ast::Method* method,
                           int colon_offset) const {
    int result = colon_offset > offset ? colon_offset : -1;
    for (ast::Parameter* parameter : method->parameters()) {
      int candidate = start(parameter);
      if (candidate > offset && (result < 0 || candidate < result)) {
        result = candidate;
      }
    }
    if (method->return_type() != null) {
      int candidate = start(method->return_type());
      if (candidate > offset && (result < 0 || candidate < result)) {
        result = candidate;
      }
    }
    return result;
  }

  std::string source_text(ast::Node* node) const {
    Source::Range range = node->full_range();
    ASSERT(range.is_valid());
    int from = source_->offset_in_source(range.from());
    int to = source_->offset_in_source(range.to());
    ASSERT(from >= 0 && to >= from);
    return std::string(reinterpret_cast<const char*>(source_->text()) + from,
                       to - from);
  }

  std::string qualified_name(ast::Expression* name) const {
    if (name->is_Identifier()) return name->as_Identifier()->data().c_str();
    if (name->is_Dot()) {
      ast::Dot* dot = name->as_Dot();
      return qualified_name(dot->receiver()) + "." + dot->name()->data().c_str();
    }
    if (name->is_Error()) UNREACHABLE();
    UNREACHABLE();
  }

  std::string method_name(ast::Expression* name) const {
    if (!name->is_Identifier()) return qualified_name(name);

    ast::Identifier* identifier = name->as_Identifier();
    std::string canonical = identifier->data().c_str();
    // Ordinary identifiers have exactly their canonical bytes as their range.
    // Operator identifier ranges also include the `operator` keyword. This
    // comparison avoids treating a legal method such as `operator-name` as an
    // operator merely because its spelling starts with those characters.
    return source_text(name) == canonical
        ? canonical
        : std::string("operator ") + canonical;
  }

  Layout* lower_type(ast::Expression* type) {
    if (type->is_Identifier()) {
      return layouts_->text(type->as_Identifier()->data().c_str());
    }
    if (type->is_Dot()) {
      ast::Dot* dot = type->as_Dot();
      return layouts_->concat({lower_type(dot->receiver()),
                               layouts_->text("."),
                               layouts_->text(dot->name()->data().c_str())});
    }
    if (type->is_Nullable()) {
      return layouts_->concat({lower_type(type->as_Nullable()->type()),
                               layouts_->text("?")});
    }
    if (type->is_Error()) UNREACHABLE();
    UNREACHABLE();
  }

  std::string field_prefix(ast::Parameter* parameter) const {
    ASSERT(parameter->is_field_storing());
    int name_from = source_->offset_in_source(
        parameter->name()->full_range().from());
    const char* text = reinterpret_cast<const char*>(source_->text());
    // The parser requires both spellings to be attached. Looking immediately
    // before the name is therefore token-precise and cannot be confused by a
    // comment or by another occurrence of the word `this` in the parameter.
    if (name_from >= 5 && std::memcmp(text + name_from - 5, "this.", 5) == 0) {
      return "this.";
    }
    ASSERT(name_from >= 1 && text[name_from - 1] == '.');
    return ".";
  }

  Layout* lower_parameter(ast::Parameter* parameter, int suffix_limit) {
    std::vector<Layout*> parts;
    if (parameter->is_block()) parts.push_back(layouts_->text("["));
    if (parameter->is_named()) parts.push_back(layouts_->text("--"));
    if (parameter->is_field_storing()) {
      parts.push_back(layouts_->text(field_prefix(parameter)));
    }
    parts.push_back(layouts_->text(parameter->name()->data().c_str()));
    if (parameter->type() != null) {
      parts.push_back(layouts_->text("/"));
      parts.push_back(lower_type(parameter->type()));
    }
    if (parameter->default_value() != null) {
      parts.push_back(layouts_->text("="));
      parts.push_back(lower_expression(parameter->default_value(), source_,
                                       layouts_, bindings_, syntax_, style_,
                                       trivia_)
                          .layout);
    }
    if (parameter->is_block()) parts.push_back(layouts_->text("]"));
    Layout* result = layouts_->concat(std::move(parts));
    if (trivia_ != null && suffix_limit >= 0) {
      result = trivia_->take_inline_suffix(
          result, end(parameter), suffix_limit);
    }
    return result;
  }

  Layout* regular_parameter_list(const std::vector<Layout*>& parameters,
                                 LayoutMarker start,
                                 LayoutMarker end) {
    std::vector<Layout*> parts = {layouts_->mark(start)};
    for (Layout* parameter : parameters) {
      parts.push_back(layouts_->line());
      parts.push_back(parameter);
    }
    parts.push_back(layouts_->mark(end));
    return layouts_->indent(style_.continuation_step,
                            layouts_->concat(std::move(parts)));
  }
};

LoweredMethodHeader lower_method_header(ast::Method* method,
                                        Source* source,
                                        LayoutBuilder* layouts,
                                        LogicalOperatorBindings* bindings,
                                        SyntaxProtection* syntax,
                                        const FormatStyle& style,
                                        TriviaLowering* trivia) {
  ASSERT(source != null);
  ASSERT(layouts != null);
  ASSERT(bindings != null);
  ASSERT(syntax != null);
  return MethodHeaderLowering(source, layouts, bindings, syntax, style, trivia)
      .lower(method);
}

} // namespace compiler
} // namespace toit
