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

#include <limits.h>

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
  bool all_separators = true;
  for (auto& candidate : candidates) {
    if (candidate != ClassScope::SUPER_CLASS_SEPARATOR) {
      all_separators = false;
      break;
    }
  }
  if (all_separators) {
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
  bool wrong_number_of_unnamed_blocks = true;
  bool wrong_number_of_unnamed_args = true;
  bool all_candidates_are_setters = true;
  bool no_candidates_take_a_named_block = true;
  bool no_candidates_take_a_named_arg = true;
  int selector_blocks = selector.shape().unnamed_block_count();
  int selector_args = selector.shape().unnamed_non_block_count() - (is_static ? 0 : 1);
  int min_blocks = INT_MAX;
  int max_blocks = -1;
  int min_args = INT_MAX;
  int max_args = -1;

  static const int ANY_NAME                    = 1;     // Name that at least one candidate allows.
  static const int ANY_BLOCK_NAME              = 2;
  static const int EVERY_NAME                  = 4;     // Name that every candidate allows.
  static const int EVERY_BLOCK_NAME            = 8;
  static const int REQUIRED_NAME               = 0x10;  // Name that every candidate requires.
  static const int REQUIRED_BLOCK_NAME         = 0x20;  // Unused in the source.
  static const int CURRENT_NAME                = 0x40;
  static const int CURRENT_BLOCK_NAME          = 0x80;
  static const int CURRENT_REQUIRED_NAME       = 0x100;
  static const int CURRENT_REQUIRED_BLOCK_NAME = 0x200;
  static const int CURRENT_FLAGS               = 0x3c0;
  Map<Symbol, int> candidate_names;  // The names that are in the candidates.

  static const int NAME = 1;
  static const int BLOCK_NAME = 2;
  Map<Symbol, int> call_site_names;  // The names that are in call site.

  int index = 0;
  for (auto symbol : selector.shape().names()) {
    call_site_names.set(symbol, selector.shape().is_block_name(index) ? BLOCK_NAME : NAME);
    index++;
  }
  int total_candidates = 0;
  for (auto node : candidates) {
    if (node == ClassScope::SUPER_CLASS_SEPARATOR || !node->is_Method()) continue;
    // Zero the flags for the current candidate.
    for (auto symbol : candidate_names.keys()) candidate_names[symbol] &= ~CURRENT_FLAGS;
    auto method = node->as_Method();
    auto shape = method->resolution_shape();
    for (int i = 0; i < shape.names().length(); i++) {
      auto symbol = shape.names()[i];
      if (!candidate_names.contains_key(symbol)) {
        candidate_names.set(symbol, 0);
      }
      bool is_required = !shape.optional_names()[i];
      if (shape.is_block_name(i)) {
        candidate_names[symbol] |= CURRENT_BLOCK_NAME;
        if (is_required) candidate_names[symbol] |= CURRENT_REQUIRED_BLOCK_NAME;
      } else {
        candidate_names[symbol] |= CURRENT_NAME;
        if (is_required) candidate_names[symbol] |= CURRENT_REQUIRED_NAME;
      }
    }
    // Now that we did all names of the candidate, update the flags.
    for (int shift = 0; shift < 2; shift++) {
      for (auto symbol : candidate_names.keys()) {
        if ((candidate_names[symbol] & (CURRENT_NAME << shift)) != 0) {
          candidate_names[symbol] |= (ANY_NAME << shift);
          if (total_candidates == 0) {
            candidate_names[symbol] |= (EVERY_NAME << shift);
          }
        } else {
          candidate_names[symbol] &= ~(EVERY_NAME << shift);
        }
        if (total_candidates == 0) {
          if ((candidate_names[symbol] & (CURRENT_REQUIRED_NAME << shift)) != 0) {
            candidate_names[symbol] |= (REQUIRED_NAME << shift);
          }
        } else {
          if ((candidate_names[symbol] & (CURRENT_REQUIRED_NAME << shift)) == 0) {
            candidate_names[symbol] &= ~(REQUIRED_NAME << shift);
          }
        }
      }
    }

    if (!shape.is_setter()) all_candidates_are_setters = false;
    int candidate_blocks = shape.unnamed_block_count();
    int candidate_min_args = shape.min_unnamed_non_block() - (method->is_static() && !method->is_constructor() ? 0 : 1);
    int candidate_max_args = shape.max_unnamed_non_block() - (method->is_static() && !method->is_constructor() ? 0 : 1);
    min_blocks = Utils::min(min_blocks, candidate_blocks);
    max_blocks = Utils::max(max_blocks, candidate_blocks);
    min_args = Utils::min(min_args, candidate_min_args);
    max_args = Utils::max(max_args, candidate_max_args);
    if (candidate_blocks == selector_blocks) {
      wrong_number_of_unnamed_blocks = false;
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
  bool too_few_unnamed_args = selector_args < min_args;
  bool too_many_unnamed_args = selector_args > max_args;
  bool too_few_unnamed_blocks = selector_blocks < min_blocks;
  bool too_many_unnamed_blocks = selector_blocks > max_blocks;
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
    helpful_note = "\n" "Could not find an overload with exactly ";
    helpful_note += std::to_string(selector_blocks);
    helpful_note += unnamed;
    helpful_note += " block arguments";
  }
  bool selector_uses_named_args = selector.shape().named_non_block_count() != 0;
  bool mention_unnamed_args = selector_uses_named_args || !no_candidates_take_a_named_arg;
  unnamed = mention_unnamed_args ? " unnamed" : "";
  if (too_many_unnamed_args) {
    auto non_block = too_few_unnamed_blocks ? " non-block" : "";
    if (selector_args == 1) {
      if (selector.shape().is_setter()) {
        helpful_note = "\n" "No setter available";
      } else {
        helpful_note = "\n" "Method does not take any";
        helpful_note += unnamed;
        helpful_note += non_block;
        helpful_note += " arguments, but one was provided";
      }
    } else {
      helpful_note = "\n" "Too many";
      helpful_note += unnamed;
      helpful_note += non_block;
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
    helpful_note = "\n" "Could not find an overload with exactly ";
    helpful_note += std::to_string(selector_args);
    helpful_note += unnamed;
    helpful_note += " arguments";
  }
  bool added_not_provided_note = false;
  for (auto symbol : call_site_names.keys()) {
    if (!candidate_names.contains_key(symbol)) {
      helpful_note += "\n" "No argument named '--";
      helpful_note += symbol.c_str();
      helpful_note += "'";
    } else {
      if ((call_site_names[symbol] & BLOCK_NAME) != 0) {
        if ((candidate_names[symbol] & ANY_BLOCK_NAME) == 0) {
          helpful_note += "\n" "The argument '--";
          helpful_note += symbol.c_str();
          helpful_note += "' was passed with block type, but must be non-block";
          added_not_provided_note = true;
        }
      } else {
        ASSERT((call_site_names[symbol] & NAME) != 0);
        if ((candidate_names[symbol] & ANY_NAME) == 0) {
          helpful_note += "\n" "The argument '--";
          helpful_note += symbol.c_str();
          helpful_note += "' was passed with non-block type, but must be block";
          added_not_provided_note = true;
        }
      }
    }
  }
  // Go through the named args that are mentioned by at least one candidate and
  // check if they are required by all candidates but not provided.
  for (auto symbol : candidate_names.keys()) {
    if ((candidate_names[symbol] & (REQUIRED_NAME | REQUIRED_BLOCK_NAME)) != 0) {
      if (!call_site_names.contains_key(symbol)) {
        helpful_note += "\n" "Required named argument '--";
        helpful_note += symbol.c_str();
        helpful_note += "' not provided";
        added_not_provided_note = true;
      }
    }
  }
  // If that didn't yield a helpful note, move on to the arguments that are
  // always allowed, but were not provided.
  if (!added_not_provided_note) {
    for (auto symbol : candidate_names.keys()) {
      if ((candidate_names[symbol] & (EVERY_NAME | EVERY_BLOCK_NAME)) != 0) {
        if (!call_site_names.contains_key(symbol)) {
          helpful_note += "\n" "Valid named arguments include '--";
          helpful_note += symbol.c_str();
          helpful_note += "'";
          added_not_provided_note = true;
        }
      }
    }
    // Move on to the arguments that are sometimes allowed, but were not
    // provided.
    bool allowed_message_added = false;
    for (auto symbol : candidate_names.keys()) {
      if (!call_site_names.contains_key(symbol) && ((candidate_names[symbol] & (EVERY_NAME | EVERY_BLOCK_NAME)) == 0)) {
        if (!allowed_message_added) {
          helpful_note += "\n" "Some overloads ";
          if (added_not_provided_note) helpful_note += "also ";
          helpful_note += "allow arguments named";
          allowed_message_added = true;
        } else {
          helpful_note += ",";
        }
        helpful_note += " '--";
        helpful_note += symbol.c_str();
        helpful_note += "'";
      }
    }
  }
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
  auto current = klass;
  while (true) {
    for (auto method : current->methods()) {
      if (method->name() == selector.name()) {
        candidates_builder.add(method);
      }
    }
    current = current->super();
    if (current == null) break;
    candidates_builder.add(ClassScope::SUPER_CLASS_SEPARATOR);
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
