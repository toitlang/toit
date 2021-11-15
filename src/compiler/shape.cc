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

#include <algorithm>
#include <vector>

#include "../top.h"

#include "shape.h"

#include "ast.h"
#include "ir.h"
#include "set.h"

namespace toit {
namespace compiler {

namespace {  // anonymous.

struct Parameter {
  Symbol name;
  bool is_optional;
  bool is_block;

  // Compares this parameter to the other.
  // Only looks at the name and blocks, but not optionality.
  // Blocks are after non-blocks.
  // Invalid parameters are considered greater than all others.
  int compare_to(const Parameter& other) {
    if (is_valid() != other.is_valid()) return is_valid() ? -1 : 1;
    if (!is_valid()) return 0;
    if (is_block != other.is_block) return is_block ? 1 : -1;
    return strcmp(name.c_str(), other.name.c_str());
  }

  bool is_valid() const { return name.is_valid(); }
  static Parameter invalid() {
    return {
      .name = Symbol::invalid(),
      .is_optional = false,
      .is_block = false,
    };
  }

};

class NameIterator {
 public:
  NameIterator(const ResolutionShape& shape) : _shape(shape), _index(0) {}

  Parameter current() const {
    auto names = _shape.names();
    if (_index >= names.length()) return Parameter::invalid();
    Symbol name = names[_index];
    bool is_optional = _shape.optional_names()[_index];
    bool is_block = _index >= names.length() - _shape.named_block_count();
    return {
      .name = name,
      .is_optional = is_optional,
      .is_block = is_block,
    };
  }

  Parameter advance() {
    if (_index < _shape.names().length()) _index++;
    return current();
  }

  // Advances to the given name..
  // Skips over all parameters that are less (according to [Parameter.compare.to]).
  // If this shape doesn't contain the name returns an invalid parameter.
  Parameter advance_to(Symbol name, bool is_block) {
    Parameter target =  {
      .name = name,
      .is_optional = false,  // Optionality doesn't matter for [compare_to].
      .is_block = is_block,
    };

    while (current().compare_to(target) < 0) advance();

    auto current_param = current();
    if (current_param.compare_to(target) == 0) {
      return current_param;
    }
    return Parameter::invalid();
  }

  ResolutionShape shape() const { return _shape; }

 private:
  ResolutionShape _shape;
  int _index;
};

}  // anonymous namespace.

PlainShape ResolutionShape::to_plain_shape() const {
  return PlainShape(_call_shape);
}

bool ResolutionShape::overlaps_with(const ResolutionShape& other) {
  if (is_setter() != other.is_setter()) return false;
  if (is_setter()) return true;

  if (total_block_count() != other.total_block_count()) return false;
  if (unnamed_block_count() != other.unnamed_block_count()) return false;
  if (min_unnamed_non_block() > other.max_unnamed_non_block()) return false;
  if (max_unnamed_non_block() < other.min_unnamed_non_block()) return false;

  NameIterator iter1(*this);
  NameIterator iter2(other);

  auto param1 = iter1.current();
  auto param2 = iter2.current();
  while (param1.is_valid() || param2.is_valid()) {
    // Invariant: param1 contains the value of iter1.
    //        and param2 contains the value of iter2.
    int comp = param1.compare_to(param2);
    bool flipped = false;
    if (comp > 0) {
      flipped = true;
      comp = -comp;
      auto tmp = param1;
      param1 = param2;
      param2 = tmp;
    }

    if (comp < 0 && !param1.is_optional) return false;

    if (comp < 0) {
      if (flipped) {
        // Switch back to maintain the invariant of the loop.
        param1 = param2;
        param2 = iter2.advance();
      } else {
        param1 = iter1.advance();
      }
    } else {
      param1 = iter1.advance();
      param2 = iter2.advance();
    }
  }
  return true;
}

/// Whether the given [shape] is fully shadowed by the [overriders].
/// If the response is false, fills the [see_through] call-shape with a
/// non-intercepted example.
/// The [taken_names] vector is used to build the [see_through] example at the
/// end.
/// All shapes of the [overrider_iterators] must overlap with the shape.
/// All shapes of the [overrider_iterators] must accept the [taken_names].
static bool is_fully_shadowed_positional_phase(const NameIterator& shape_iterator,
                                               const std::vector<NameIterator> overrider_iterators,
                                               const std::vector<Symbol> taken_names,
                                               CallShape* see_through) {
  auto shape = shape_iterator.shape();
  // We only care for the non-block parameters, as the block ones must match.
  int min_positional = shape.min_unnamed_non_block();
  int max_positional = shape.max_unnamed_non_block();

  std::vector<bool> positionals(max_positional - min_positional + 1);

  for (auto overrider_iterator : overrider_iterators) {
    // For each overrider mark the positional parameters that are covered by the
    // by the overrider.
    auto overrider = overrider_iterator.shape();
    int min_overrider = overrider.min_unnamed_non_block();
    int max_overrider = overrider.max_unnamed_non_block();
    int min = std::max(min_positional, min_overrider);
    int max = std::min(max_positional, max_overrider);
    for (int i = min; i <= max; i++) {
      positionals[i - min_positional] = true;
    }
  }

  // Find the first positional position that isn't covered by any overrider.
  for (size_t i = 0; i < positionals.size(); i++) {
    if (!positionals[i]) {
      // We have a call that isn't fully shadowed.
      // Build the corresponding see-through shape.
      int total_block_count = shape.total_block_count();
      int named_block_count = shape.named_block_count();
      int unnamed_block_count = total_block_count - named_block_count;
      bool is_setter = shape.is_setter();
      ASSERT(!is_setter);
      // The taken_names list contains blocks.
      int arity = min_positional + i + unnamed_block_count + taken_names.size();
      auto names = ListBuilder<Symbol>::build_from_vector(taken_names);
      *see_through = CallShape(arity, total_block_count, names, named_block_count, is_setter);
      return false;
    }
  }
  return true;
}

/// Whether the given [shape] is fully shadowed by the [overriders].
/// If the response is false, fills the [see_through] call-shape with a
/// non-intercepted example.
/// The [taken_names] vector is used to build the [see_through] example at the
/// end.
/// All shapes of the overrider-iterators must overlap with the shape.
/// The [overriders] parameter is taken as pointer and modified. Callers must
///    be able to deal with this. (It's just an optimization).
static bool is_fully_shadowed_names_phase(NameIterator shape,
                                          std::vector<NameIterator>* overriders,
                                          std::vector<Symbol> taken_names,
                                          CallShape* see_through) {
  for (auto param = shape.current(); param.is_valid(); param = shape.advance()) {
    // We know that all overriders must satisfy non-optional named parameters.
    if (!param.is_optional) {
      taken_names.push_back(param.name);
      // Advance all overriders.
      for (auto& overrider : *overriders) { // Note the `&`. We are modifying the iterators in the vector.
        auto overrider_param = overrider.advance_to(param.name, param.is_block);
        ASSERT(overrider_param.is_valid());
      }
      continue;
    }

    if (overriders->empty()) {
      // We know already now that the result is false.
      // We just need to accumulate all the taken names so we can create the
      // see_through example.
      // Since this parameter is optional, we just assume it's not taken.
      // This 'if' is purely an optimization. We would have done the exact same
      // thing below (but with allocating three vectors).
      continue;
    }

    // Group the overriders into three sets:
    std::vector<NameIterator> taken;     // Where the overrider requires the named param.
    std::vector<NameIterator> non_taken; // Where the overrider doesn't have the named param.
    std::vector<NameIterator> optional;  // Where the overrider's named param is also optional.
    for (auto& overrider : *overriders) { // Note the `&`. We are modifying the iterators in the vector.
      auto overrider_param = overrider.advance_to(param.name, param.is_block);
      if (!overrider_param.is_valid()) {
        non_taken.push_back(overrider);
      } else if (overrider_param.is_optional) {
        optional.push_back(overrider);
      } else {
        taken.push_back(overrider);
      }
    }
    if (taken.empty() && non_taken.empty()) {
      // The overriders are also all optional.
      // Assume we don't take the name (for the see_through example), and continue with
      // the next iteration.
      // Since we modified the iterators in the vector we can just continue the
      // iteration.
      continue;
    }

    // Duplicate the optional iterators.
    taken.insert(taken.end(), optional.begin(), optional.end());
    non_taken.insert(non_taken.end(), optional.begin(), optional.end());

    // Consume the current named argument.
    shape.advance();

    // We recursively continue for the non-taken branch.
    // We use the non-taken branch first, as we can
    // just pass in the current 'taken_names' vector this way.
    // Note that the `non_taken` vector is modified by the function, but we don't
    // use that one anymore.
    bool is_non_taken_fully_shadowed =
        is_fully_shadowed_names_phase(shape, &non_taken, taken_names, see_through);
    if (!is_non_taken_fully_shadowed) return false;

    taken_names.push_back(param.name);
    // Note that the `taken` vector is modified by the function, but we don't
    // use that one anymore.
    // We could just update the 'overriders' vector and continue the loop
    // (paying attention not to advance the shape), but the recursive call
    // shouldn't be too expensive and makes things more uniform.
    return is_fully_shadowed_names_phase(shape, &taken, taken_names, see_through);
  }
  // We went through all named parameters of the shape.
  // We know that all overriders overlap, so all remaining names in the overriders
  // must be optional, and we can skip looking at them.
  return is_fully_shadowed_positional_phase(shape, *overriders, taken_names, see_through);
}

bool ResolutionShape::is_fully_shadowed_by(const std::vector<ResolutionShape> overriders,
                                           CallShape* see_through) {
  *see_through = CallShape::invalid();

  // Start by filtering the overriders that clearly can't have any influence on
  // the result.
  std::vector<ResolutionShape> overlapping;
  for (auto shape : overriders) {
    if (overlaps_with(shape)) overlapping.push_back(shape);
  }

  if (overlapping.empty()) return false;

  // If we have overlap, and this shape doesn't take optional parameters, then
  // there must be a full match.
  if (!has_optional_parameters()) return true;

  std::vector<NameIterator> overrider_iterators;
  overrider_iterators.reserve(overlapping.size());
  for (auto shape : overlapping) {
    overrider_iterators.push_back(NameIterator(shape));
  }
  NameIterator this_iterator(*this);
  return is_fully_shadowed_names_phase(this_iterator, &overrider_iterators, {}, see_through);
}

bool ResolutionShape::accepts(const CallShape& call_shape) {
  auto call_names = call_shape.names();
  int call_named_block = call_shape.named_block_count();
  int call_named_non_block = call_shape.named_non_block_count();
  int call_unnamed_block = call_shape.unnamed_block_count();
  int call_unnamed_non_block = call_shape.unnamed_non_block_count();

  if (is_setter() != call_shape.is_setter()) return false;

  if (call_unnamed_non_block < min_unnamed_non_block() ||
      call_unnamed_non_block > max_unnamed_non_block()) {
    return false;
  }

  // Blocks are never optional. Neither unnamed, nor named.
  if (call_unnamed_block != unnamed_block_count()) return false;
  if (call_named_block != named_block_count()) return false;

  auto parameter_names = names();
  int parameter_named_non_block = parameter_names.length() - named_block_count();

  int argument_index = 0;
  int parameter_index = 0;
  while (argument_index < call_names.length()) {
    auto argument_name = call_names[argument_index];
    while (parameter_index < parameter_names.length()) {
      bool found = parameter_names[parameter_index] == argument_name;
      if (found) break;
      if (!_optional_names[parameter_index]) return false;
      parameter_index++;
    }
    bool argument_is_block = argument_index >= call_named_non_block;
    bool parameter_is_block = parameter_index >= parameter_named_non_block;
    if (argument_is_block != parameter_is_block) return false;
    argument_index++;
    parameter_index++;
  }
  for (; parameter_index < parameter_names.length(); parameter_index++) {
    if (!_optional_names[parameter_index]) return false;
  }
  return true;
}

ResolutionShape ResolutionShape::for_static_method(ast::Method* method) {
  auto parameters = method->parameters();
  std::vector<ast::Parameter*> copy(parameters.begin(), parameters.end());
  struct {
    // This needs to stay in sync with [CallBuilder::sort_arguments].
    bool operator()(const ast::Parameter* a, const ast::Parameter* b) const {
      // Three sections, in each of which we first have non-block args, then block-args.
      // Section 1: unnamed parameters.
      // Section 2: named parameters. First non-block. Then block-args.
      if (a->is_named() != b->is_named()) return !a->is_named();
      if (a->is_block() != b->is_block()) return !a->is_block();
      if (a->is_named()) return strcmp(a->name()->data().c_str(), b->name()->data().c_str()) < 0;
      // Not named, and same blockness: consider equal for the sort.
      return false;
    }
  } parameter_less;
  std::sort(copy.begin(), copy.end(), parameter_less);

  int arity = parameters.length();
  int total_block_count = 0;
  int optional_unnamed = 0;
  int named_block_count = 0;
  ListBuilder<Symbol> names;
  std::vector<bool> optional_names;

  UnorderedSet<Symbol> used_names;
  for (size_t i = 0; i < copy.size(); i++) {
    auto parameter = copy[i];
    bool has_default = parameter->default_value() != null;
    bool is_block = parameter->is_block();
    bool is_named = parameter->is_named();
    if (is_block && has_default) {
      // This is an error and will be reported when the function is analyzed.
      has_default = false;
    }

    Symbol name = is_named ? parameter->name()->data() : Symbol::invalid();
    if (is_block) {
      total_block_count++;
      if (is_named) named_block_count++;
    }
    if (!is_named && has_default) {
      optional_unnamed++;
    }
    if (is_named) {
      if (used_names.contains(name)) {
        // Duplicated names will be reported as errors later.
        // We still deduplicate the names, as the compiler otherwise tries to do
        //   direct calls, which leads to all kinds of problems.
        // We ensure that the names are different symbols.
        const char* copied_name = strdup(name.c_str());
        name = Symbol::synthetic(copied_name);
      }
      names.add(name);
      used_names.insert(name);
      optional_names.push_back(has_default);
    }
  }

  bool is_setter = method->is_setter();

  return ResolutionShape(arity,
                         total_block_count,
                         names.build(),
                         named_block_count,
                         is_setter,
                         optional_unnamed,
                         optional_names);
}

ResolutionShape ResolutionShape::for_instance_method(ast::Method* method) {
  return for_static_method(method).with_implicit_this();
}

CallShape CallShape::for_static_call_no_named(List<ir::Expression*> arguments) {
  int block_count = 0;
  for (auto argument : arguments) {
    if (argument->is_block()) block_count++;
  }
  return CallShape(arguments.length(), block_count);
}

CallShape CallShape::for_instance_call_no_named(List<ir::Expression*> arguments) {
  return for_static_call_no_named(arguments).with_implicit_this();
}

PlainShape CallShape::to_plain_shape() const {
  return PlainShape(*this);
}

} // namespace toit::compiler
} // namespace toit

