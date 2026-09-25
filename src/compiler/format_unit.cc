// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.

#include "format_unit.h"

#include <string>
#include <vector>

#include "format_declaration.h"
#include "format_source.h"
#include "format_statement.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

class UnitPrinter {
 public:
  UnitPrinter(Source* source,
              const FormatStyle& style,
              const FormatExpressionOptions& expression_options,
              FormatCommentState* comments)
      : source_(source)
      , style_(style)
      , expression_options_(expression_options)
      , comments_(comments) {}

  bool run(Unit* unit, std::string* result) {
    std::vector<std::string> sections;
    std::vector<std::string> directives;
    int cursor = 0;
    for (auto import : unit->imports()) {
      std::string text;
      if (!leading(import, 0, cursor, &text)) return false;
      std::string directive;
      if (has_comment_on_first_line(import)) {
        directive = verbatim(import, 0);
      } else if (!format_import(import, &directive)) {
        return false;
      }
      if (!text.empty()) text += "\n";
      text += directive;
      directives.push_back(std::move(text));
      cursor = end(import);
    }
    for (auto export_ : unit->exports()) {
      std::string text;
      if (!leading(export_, 0, cursor, &text)) return false;
      std::string directive;
      if (has_comment_on_first_line(export_)) {
        directive = verbatim(export_, 0);
      } else if (!format_export(export_, &directive)) {
        return false;
      }
      if (!text.empty()) text += "\n";
      text += directive;
      directives.push_back(std::move(text));
      cursor = end(export_);
    }
    if (!directives.empty()) sections.push_back(join(directives, "\n"));

    for (auto node : unit->declarations()) {
      std::string text;
      std::string prefix;
      if (!leading(node, 0, cursor, &prefix)) return false;
      if (!declaration(node, 0, &text)) return false;
      if (!prefix.empty()) text = prefix + "\n" + text;
      sections.push_back(std::move(text));
      cursor = end(node);
    }
    std::string trailing;
    if (!comments_->render_own_line(
        cursor,
        source_->size(),
        0,
        &trailing,
        style_.max_blank_lines)) return false;
    if (!trailing.empty()) sections.push_back(std::move(trailing));
    *result = join(sections, "\n\n");
    if (!result->empty()) result->push_back('\n');
    return true;
  }

 private:
  Source* source_;
  const FormatStyle& style_;
  const FormatExpressionOptions& expression_options_;
  FormatCommentState* comments_;

  const FormatSource* facts() const { return comments_->source(); }

  int start(Node* node) const {
    return source_->offset_in_source(node->full_range().from());
  }

  int end(Node* node) const {
    return source_->offset_in_source(node->full_range().to());
  }

  int original_indentation(Node* node) const {
    return facts()->lines()[facts()->line_index_at(start(node))].indentation;
  }

  bool leading(Node* node,
               int indentation,
               int cursor,
               std::string* result) {
    return comments_->render_own_line(
        cursor,
        start(node),
        indentation - original_indentation(node),
        result,
        style_.max_blank_lines);
  }

  bool has_comment_on_first_line(Node* node) const {
    int node_start = start(node);
    int line = facts()->line_index_at(node_start);
    return comments_->has_unconsumed_in(
        node_start, facts()->lines()[line].to);
  }

  bool offset_is_in_comment(int offset) const {
    for (const auto& comment : facts()->comments()) {
      if (comment.from <= offset && offset < comment.to) return true;
    }
    return false;
  }

  int method_header_end(Method* method) const {
    if (method->body() == null) return end(method);
    int body_start = method->body()->expressions().is_empty()
        ? end(method)
        : start(method->body()->expressions().first());
    const uint8* bytes = source_->text();
    for (int offset = body_start - 1; offset >= start(method); offset--) {
      if (bytes[offset] == ':' && !offset_is_in_comment(offset)) {
        int line = facts()->line_index_at(offset);
        return facts()->lines()[line].to;
      }
    }
    return body_start;
  }

  std::string verbatim(Node* node, int indentation) {
    int first = facts()->line_index_at(start(node));
    int last = facts()->line_index_at(std::max(start(node), end(node) - 1));
    return comments_->render_verbatim(first, last, indentation);
  }

  static std::string indent(int indentation) {
    return std::string(indentation, ' ');
  }

  static std::string join(const std::vector<std::string>& parts,
                          const char* separator) {
    std::string result;
    for (const auto& part : parts) {
      if (!result.empty()) result += separator;
      result += part;
    }
    return result;
  }

  bool flat(Expression* expression, std::string* result) {
    return format_expression_flat(
        expression, source_, result, expression_options_);
  }

  bool format_import(Import* import, std::string* result) {
    std::string text = "import ";
    if (import->is_relative()) {
      text.append(import->dot_outs() + 1, '.');
    }
    for (int i = 0; i < import->segments().length(); i++) {
      if (i > 0) text += ".";
      std::string segment;
      if (!flat(import->segments()[i], &segment)) return false;
      text += segment;
    }
    if (import->prefix() != null) {
      std::string prefix;
      if (!flat(import->prefix(), &prefix)) return false;
      text += " as " + prefix;
    }
    if (import->show_all()) {
      text += " show *";
    } else if (!import->show_identifiers().is_empty()) {
      text += " show";
      for (auto identifier : import->show_identifiers()) {
        std::string name;
        if (!flat(identifier, &name)) return false;
        text += " " + name;
      }
    }
    *result = text;
    return true;
  }

  bool format_export(Export* export_, std::string* result) {
    std::string text = "export";
    if (export_->export_all()) {
      text += " *";
    } else {
      for (auto identifier : export_->identifiers()) {
        std::string name;
        if (!flat(identifier, &name)) return false;
        text += " " + name;
      }
    }
    *result = text;
    return true;
  }

  bool field(Field* field, int indentation, std::string* result) {
    if (comments_->has_unconsumed_in(
        start(field),
        facts()->lines()[facts()->line_index_at(end(field))].to)) {
      *result = verbatim(field, indentation);
      return true;
    }
    std::string prefix = indent(indentation);
    if (field->is_abstract()) prefix += "abstract ";
    if (field->is_static()) prefix += "static ";
    std::string name;
    if (!flat(field->name(), &name)) return false;
    prefix += name;
    if (field->type() != null) {
      std::string type;
      if (!flat(field->type(), &type)) return false;
      prefix += "/" + type;
    }
    if (field->initializer() == null) {
      *result = prefix;
      return true;
    }
    FormatOutput initializer;
    if (!format_expression(field->initializer(),
                           source_,
                           indentation,
                           &initializer,
                           style_,
                           expression_options_)) return false;
    prefix += field->is_final() ? " ::= " : " := ";
    ASSERT(!initializer.lines().empty());
    *result = prefix + initializer.lines()[0].text;
    for (int i = 1; i < static_cast<int>(initializer.lines().size()); i++) {
      *result += "\n" +
          indent(indentation + initializer.lines()[i].indentation) +
          initializer.lines()[i].text;
    }
    return true;
  }

  bool method(Method* method, int indentation, std::string* result) {
    int header_to = method_header_end(method);
    if (comments_->has_unconsumed_in(start(method), header_to)) {
      *result = verbatim(method, indentation);
      return true;
    }
    FormatOutput header;
    if (!format_method_header(method,
                              source_,
                              indentation,
                              &header,
                              style_,
                              expression_options_)) return false;
    *result = header.render(indentation);
    if (method->body() != null) {
      std::string body;
      if (!format_sequence(method->body(),
                           source_,
                           indentation + style_.indentation_step,
                           &body,
                           style_,
                           expression_options_,
                           comments_)) return false;
      if (!body.empty()) *result += "\n" + body;
    }
    return true;
  }

  bool class_(Class* klass, int indentation, std::string* result) {
    if (has_comment_on_first_line(klass)) {
      *result = verbatim(klass, indentation);
      return true;
    }
    std::string header = indent(indentation);
    if (klass->has_abstract_modifier()) header += "abstract ";
    switch (klass->kind()) {
      case Class::CLASS: header += "class "; break;
      case Class::INTERFACE: header += "interface "; break;
      case Class::MONITOR: header += "monitor "; break;
      case Class::MIXIN: header += "mixin "; break;
    }
    std::string name;
    if (!flat(klass->name(), &name)) return false;
    header += name;
    if (klass->super() != null) {
      std::string super;
      if (!flat(klass->super(), &super)) return false;
      header += " extends " + super;
    }
    if (!klass->mixins().is_empty()) {
      header += " with";
      for (auto mixin : klass->mixins()) {
        std::string text;
        if (!flat(mixin, &text)) return false;
        header += " " + text;
      }
    }
    if (!klass->interfaces().is_empty()) {
      header += " implements";
      for (auto interface : klass->interfaces()) {
        std::string text;
        if (!flat(interface, &text)) return false;
        header += " " + text;
      }
    }
    header += ":";

    std::vector<std::string> members;
    int cursor = facts()->lines()[facts()->line_index_at(start(klass))].to;
    for (auto member : klass->members()) {
      std::string text;
      std::string prefix;
      if (!leading(member,
                   indentation + style_.indentation_step,
                   cursor,
                   &prefix)) return false;
      if (!declaration(
          member, indentation + style_.indentation_step, &text)) return false;
      if (!prefix.empty()) text = prefix + "\n" + text;
      members.push_back(std::move(text));
      cursor = end(member);
    }
    *result = header;
    if (!members.empty()) *result += "\n" + join(members, "\n\n");
    return true;
  }

  bool declaration(Node* node, int indentation, std::string* result) {
    if (node->is_Field()) return field(node->as_Field(), indentation, result);
    if (node->is_Method()) return method(node->as_Method(), indentation, result);
    if (node->is_Class()) return class_(node->as_Class(), indentation, result);
    return false;
  }
};

} // namespace

bool format_unit(Unit* unit,
                 Source* source,
                 List<Scanner::Comment> comments,
                 std::string* result,
                 const FormatStyle& style,
                 const FormatExpressionOptions& expression_options) {
  ASSERT(unit != null && source != null && result != null);
  FormatSource facts(source, comments);
  FormatCommentState comment_state(&facts);
  UnitPrinter printer(source, style, expression_options, &comment_state);
  if (!printer.run(unit, result)) return false;
  return comment_state.all_consumed();
}

} // namespace compiler
} // namespace toit
