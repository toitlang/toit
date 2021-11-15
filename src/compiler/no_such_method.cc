// Copyright (C) 2021 Toitware ApS.
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

#include "no_such_method.h"

#include "resolver_scope.h"
#include "queryable_class.h"
#include "diagnostic.h"

namespace toit {
namespace compiler {

static void report_no_such_method(List<ir::Node*> candidates,
                                  ir::Class* klass,
                                  bool is_static,
                                  const Selector<CallShape>& selector,
                                  const Source::Range& range,
                                  Diagnostics* diagnostics) {
  // Note that the candidates could contain the super-class separator ClassScope::SUPER_CLASS_SEPARATOR.
  // All other nodes must be ir::Method* nodes.
  if (candidates.is_empty() ||
      (candidates.length() == 1 && candidates[0] == ClassScope::SUPER_CLASS_SEPARATOR)) {
    ASSERT(!is_static);
    if (klass->name().is_valid()) {
      diagnostics->report_error(range,
                                "Class '%s' does not have any method '%s'",
                                klass->name().c_str(),
                                selector.name().c_str());
    } else {
      ASSERT(diagnostics->encountered_error());
      diagnostics->report_error(range,
                                "No method '%s' in this class",
                                selector.name().c_str());
    }
    return;
  }
  bool too_few_unnamed_blocks = true;
  bool too_few_unnamed_args = true;
  bool too_many_unnamed_blocks = true;
  bool too_many_unnamed_args = true;
  bool wrong_number_of_unnamed_blocks = true;
  bool wrong_number_of_unnamed_args = true;
  bool all_candidates_are_setters = true;
  bool no_candidates_take_a_named_block = true;
  bool no_candidates_take_a_named_arg = true;
  int selector_blocks = selector.shape().unnamed_block_count();
  int selector_args = selector.shape().unnamed_non_block_count() - (is_static ? 0 : 1);
  Map<Symbol, bool> seen_names;
  Map<Symbol, int> always_required_names;  // Count how many of the candidates require each name.
  for (auto symbol : selector.shape().names()) {
    seen_names.set(symbol, false);
  }
  int total_candidates = 0;
  for (auto node : candidates) {
    if (node == ClassScope::SUPER_CLASS_SEPARATOR || !node->is_Method()) continue;
    auto method = node->as_Method();
    auto shape = method->resolution_shape();
    for (int i = 0; i < shape.names().length(); i++) {
      auto symbol = shape.names()[i];
      if (!shape.optional_names()[i]) {
        if (total_candidates == 0) {
          always_required_names.set(symbol, 1);
        // Not worth introducing a new entry in always_required_names if we are
        // not on the first candidate since it will never be found to be
        // required by all candidates if it isn't in the first.
        } else if (always_required_names.contains_key(symbol)) {
          always_required_names.set(symbol, always_required_names[symbol] + 1);  // Increment.
        }
      }
      if (seen_names.contains_key(symbol)) {
        seen_names.set(symbol, true);
      }
    }

    if (!shape.is_setter()) all_candidates_are_setters = false;
    int candidate_blocks = shape.unnamed_block_count();
    int candidate_min_args = shape.min_unnamed_non_block() - (method->is_static() && !method->is_constructor() ? 0 : 1);
    int candidate_max_args = shape.max_unnamed_non_block() - (method->is_static() && !method->is_constructor() ? 0 : 1);
    if (candidate_blocks <= selector_blocks) {
      too_few_unnamed_blocks = false;
    }
    if (candidate_blocks >= selector_blocks) {
      too_many_unnamed_blocks = false;
    }
    if (candidate_blocks == selector_blocks) {
      wrong_number_of_unnamed_blocks = false;
    }
    if (candidate_min_args <= selector_args) {
      too_few_unnamed_args = false;
    }
    if (candidate_max_args >= selector_args) {
      too_many_unnamed_args = false;
    }
    if (candidate_min_args <= selector_args && selector_args <= candidate_max_args) {
      wrong_number_of_unnamed_args = false;
    }
    if (shape.named_block_count() != 0) {
      no_candidates_take_a_named_block = false;
    }
    if (shape.named_non_block_count() != 0) {
      no_candidates_take_a_named_arg = false;
    }
    total_candidates++;
  }
  bool selector_uses_named_blocks = selector.shape().named_block_count() != 0;
  bool mention_unnamed_blocks = selector_uses_named_blocks || !no_candidates_take_a_named_block;
  std::string helpful_note = "";
  const char* unnamed = mention_unnamed_blocks ? " unnamed" : "";
  if (too_many_unnamed_blocks) {
    if (selector_blocks == 1) {
      // For grepping purposes, written as two strings, auto-concatenated
      // according to the syntax of C/C++.
      helpful_note += "\n" "Method does not take a";
      if (mention_unnamed_blocks) helpful_note += "n";
      helpful_note += unnamed;
      helpful_note += " block argument, but one was provided";
    } else {
      helpful_note = "\n" "Too many";
      helpful_note += unnamed;
      helpful_note += " block arguments provided";
    }
  } else if (too_few_unnamed_blocks) {
    if (selector_blocks == 0) {
      helpful_note = mention_unnamed_blocks ? "\n" "Unnamed block" : "\n" "Block";
      helpful_note += " argument not provided";
    } else {
      helpful_note = "\n" "Too few";
      helpful_note += unnamed;
      helpful_note += " block arguments provided";
    }
  } else if (wrong_number_of_unnamed_blocks) {
    helpful_note = "\n" "Could not find an overload with ";
    helpful_note += std::to_string(selector_blocks);
    helpful_note += unnamed;
    helpful_note += " block arguments";
  }
  bool selector_uses_named_args = selector.shape().named_non_block_count() != 0;
  bool mention_unnamed_args = selector_uses_named_args || !no_candidates_take_a_named_arg;
  unnamed = mention_unnamed_args ? " unnamed" : "";
  if (too_many_unnamed_args) {
    if (selector_args == 1) {
      if (selector.shape().is_setter()) {
        helpful_note = "\n" "No setter available";
      } else {
        helpful_note = "\n" "Method does not take any";
        helpful_note += unnamed;
        helpful_note += " arguments, but one was provided";
      }
    } else {
      helpful_note = "\n" "Too many";
      helpful_note += unnamed;
      helpful_note += " arguments provided";
    }
  } else if (too_few_unnamed_args) {
    if (all_candidates_are_setters) {
      helpful_note = "\n" "No getter available";
    } else {
      helpful_note = "\n" "Too few";
      helpful_note += unnamed;
      helpful_note += " arguments provided";
    }
  } else if (wrong_number_of_unnamed_args) {
    helpful_note = "\n" "Could not find an overload with ";
    helpful_note += std::to_string(selector_args);
    helpful_note += unnamed;
    helpful_note += " arguments";
  }
  for (auto symbol : seen_names.keys()) {
    if (!seen_names[symbol]) {
      helpful_note += "\n" "No argument named '--";
      helpful_note += symbol.c_str();
      helpful_note += "'";
    }
  }
  // Go through the named args that are required by at least one candidate and
  // check if they are required by all candidates but not provided.
  for (auto required : always_required_names.keys()) {
    if (always_required_names[required] == total_candidates) {
      if (!seen_names.contains_key(required)) {
        helpful_note += "\n" "Required named argument '--";
        helpful_note += required.c_str();
        helpful_note += "' not provided";
      }
    }
  }
  // TODO: Named args that have the wrong block-ness.
  // TODO: If we could not give any notes, go through all individual candidates and explain why they don't match.
  if (is_static) {
    diagnostics->report_error(range,
                              "Argument mismatch for '%s'%s",
                              selector.name().c_str(),
                              helpful_note.c_str());
  } else if (klass->name().is_valid()) {
    diagnostics->report_error(range,
                              "Argument mismatch for '%s.%s'%s",
                              klass->name().c_str(),
                              selector.name().c_str(),
                              helpful_note.c_str());
  } else {
    ASSERT(diagnostics->encountered_error());
    diagnostics->report_error(range,
                              "Argument mismatch for method '%s' in this class%s",
                              selector.name().c_str(),
                              helpful_note.c_str());
  }
}

void report_no_such_instance_method(ir::Class* klass,
                           const Selector<CallShape>& selector,
                           const Source::Range& range,
                           Diagnostics* diagnostics) {
  // TODO(florian): filtering the methods every time is linear and
  // could be too slow. Consider adding a caching mechanism.
  ListBuilder<ir::Node*> candidates_builder;
  for (auto method : klass->methods()) {
    if (method->name() == selector.name()) {
      candidates_builder.add(method);
    }
  }
  auto candidates = candidates_builder.build();
  report_no_such_method(candidates,
                        klass,
                        false,
                        selector,
                        range,
                        diagnostics);

}

void report_no_such_static_method(List<ir::Node*> candidates,
                                  const Selector<CallShape>& selector,
                                  const Source::Range& range,
                                  Diagnostics* diagnostics) {
  ASSERT(!candidates.is_empty());
  report_no_such_method(candidates,
                        null,
                        true,
                        selector,
                        range,
                        diagnostics);
}

} // namespace compiler
} // namespace toit
