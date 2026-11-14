// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.

#include "format_declaration.h"

#include <string>
#include <vector>

namespace toit {
namespace compiler {

using namespace ast;

namespace {

class MethodHeaderPrinter {
 public:
  MethodHeaderPrinter(Method* method,
                      Source* source,
                      int base_indentation,
                      const FormatStyle& style,
                      const FormatExpressionOptions& expression_options)
      : method_(method)
      , source_(source)
      , base_indentation_(base_indentation)
      , style_(style)
      , expression_options_(expression_options) {}

  bool run(FormatOutput* result) {
    if (!prepare()) return false;
    if (parameters_.empty()) {
      *result = flat_output();
      return true;
    }

    int flat_width = utf8_code_point_width(prefix_) +
        utf8_code_point_width(return_suffix()) +
        utf8_code_point_width(colon_suffix());
    for (const auto& parameter : parameters_) {
      flat_width += 1 + utf8_code_point_width(parameter);
    }
    int split_at = first_named_ < 0 ? 0 : first_named_;
    int broken_lines = parameters_.size() - split_at;
    if (is_flat_acceptable(flat_width,
                           base_indentation_,
                           broken_lines,
                           broken_lines,
                           0,
                           style_)) {
      *result = flat_output();
      return true;
    }

    if (first_named_ >= 0) {
      int prefix_width = utf8_code_point_width(prefix_) +
          utf8_code_point_width(return_suffix());
      for (int i = 0; i < first_named_; i++) {
        prefix_width += 1 + utf8_code_point_width(parameters_[i]);
      }
      if (is_flat_acceptable(prefix_width,
                             base_indentation_,
                             1,
                             1,
                             0,
                             style_)) {
        *result = named_suffix_output();
        return true;
      }
    }
    *result = fully_broken_output();
    return true;
  }

 private:
  Method* method_;
  Source* source_;
  int base_indentation_;
  const FormatStyle& style_;
  const FormatExpressionOptions& expression_options_;
  std::string prefix_;
  std::string return_type_;
  std::vector<std::string> parameters_;
  int first_named_ = -1;

  bool expression(Expression* node, std::string* result) {
    return format_expression_flat(
        node, source_, result, expression_options_);
  }

  bool prepare_parameter(Parameter* parameter, std::string* result) {
    std::string text;
    if (parameter->is_block()) text += "[";
    if (parameter->is_named()) text += "--";
    if (parameter->is_field_storing()) text += ".";

    std::string name;
    if (!expression(parameter->name(), &name)) return false;
    text += name;
    if (parameter->type() != null) {
      std::string type;
      if (!expression(parameter->type(), &type)) return false;
      text += "/" + type;
    }
    if (parameter->default_value() != null) {
      std::string value;
      if (!expression(parameter->default_value(), &value)) return false;
      text += "=" + (parameter->default_value()->is_Parenthesis()
          ? "(" + value + ")"
          : value);
    }
    if (parameter->is_block()) text += "]";
    *result = text;
    return true;
  }

  bool prepare() {
    if (method_->is_abstract()) prefix_ += "abstract ";
    if (method_->is_static()) prefix_ += "static ";

    std::string name;
    if (!expression(method_->name_or_dot(), &name)) return false;
    prefix_ += name;
    if (method_->is_setter()) prefix_ += "=";

    if (method_->return_type() != null) {
      if (!expression(method_->return_type(), &return_type_)) return false;
    }
    auto ast_parameters = method_->parameters();
    for (int i = 0; i < ast_parameters.length(); i++) {
      Parameter* parameter = ast_parameters[i];
      std::string text;
      if (!prepare_parameter(parameter, &text)) return false;
      if (first_named_ < 0 && parameter->is_named()) first_named_ = i;
      parameters_.push_back(text);
    }
    return true;
  }

  std::string return_suffix() const {
    return return_type_.empty() ? std::string() : " -> " + return_type_;
  }

  std::string colon_suffix() const {
    return method_->body() == null ? std::string() : ":";
  }

  FormatOutput flat_output() const {
    std::string text = prefix_;
    for (const auto& parameter : parameters_) text += " " + parameter;
    text += return_suffix();
    text += colon_suffix();
    return FormatOutput::single_line(text);
  }

  FormatOutput named_suffix_output() const {
    int split_at = first_named_ < 0
        ? static_cast<int>(parameters_.size())
        : first_named_;
    std::string first = prefix_;
    for (int i = 0; i < split_at; i++) first += " " + parameters_[i];
    first += return_suffix();

    FormatOutput result = FormatOutput::single_line(first);
    for (int i = split_at; i < static_cast<int>(parameters_.size()); i++) {
      result.add_line(style_.continuation_step, parameters_[i]);
    }
    if (method_->body() != null) {
      if (split_at == static_cast<int>(parameters_.size())) {
        result.append(":");
      } else {
        result.add_line(0, ":");
      }
    }
    return result;
  }

  FormatOutput fully_broken_output() const {
    FormatOutput result = FormatOutput::single_line(prefix_ + return_suffix());
    for (const auto& parameter : parameters_) {
      result.add_line(style_.continuation_step, parameter);
    }
    if (method_->body() != null) result.add_line(0, ":");
    return result;
  }
};

} // namespace

bool format_method_header(Method* method,
                          Source* source,
                          int base_indentation,
                          FormatOutput* result,
                          const FormatStyle& style,
                          const FormatExpressionOptions& expression_options) {
  ASSERT(method != null && source != null && result != null);
  ASSERT(base_indentation >= 0);
  MethodHeaderPrinter printer(
      method, source, base_indentation, style, expression_options);
  return printer.run(result);
}

} // namespace compiler
} // namespace toit
