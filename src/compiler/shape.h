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

#pragma once

#include <string>
#include <vector>

#include "list.h"
#include "symbol.h"

/**
 * A Shape can either be a CallShape, a PlainShape or a ResolutionShape.
 *
 * The ResolutionShape is used during resolution and may represent multiple
 * different ways to call a method.
 * PlainShapes and CallShapes, on the other hand, only encode one specific
 * shape. We use PlainShapes for methods (after resolution) and CallShapes for
 * call-sites.
 *
 * Before switching to PlainShapes we need to add the corresponding stubs which
 * makes methods only accept one particular call. (For static calls we just
 * adapt the call-site, so we won't need any stubs).
 *
 * For simplicity, we almost always compute shapes from existing parameter or
 * argument lists.
 * This way, we can easily adapt the shapes, when more features are added (such as
 * optional or named arguments).
 */

namespace toit {
namespace compiler {

namespace ir {
  class Expression;
}

namespace ast {
  class Method;
}

class PlainShape;

/// The shape of a call.
///
/// Contrary to the actual call arguments, the shape does not keep track of
/// the actual order of arguments. It contains just enough information to
/// uniquely identify the target of a call.
///
/// For example, the shape for a call like `foo --znamed 1 --named 2 3` does not
/// reflect the order of 1, 2 and 3. Instead, it just states that the call has
/// one unnamed argument (3) and two named arguments `named` and `znamed` (in
/// alphabetical order).
class CallShape {
 public:
  // A simple shape for static functions calls.
  explicit CallShape(int arity, int block_count = 0)
      : arity_(arity)
      , total_block_count_(block_count)
      , names_(List<Symbol>())
      , named_block_count_(0)
      , is_setter_(false) { }

  /// Creates a call shape.
  ///
  /// - [arity]: the number of *all* arguments.
  /// - [block_count]: the number of *all* block arguments.
  /// - [named_block_count]: the number of named block arguments. named_block_count <= block_count.
  /// - [names]: the list of names. named_block_count <= names.length() <= arity.
  ///            The names must be sorted alphabetically section-wise for non-block and block arguments.
  CallShape(int arity, int total_block_count, List<Symbol> names, int named_block_count,
    bool is_setter)
      : arity_(arity)
      , total_block_count_(total_block_count)
      , names_(names)
      , named_block_count_(named_block_count)
      , is_setter_(is_setter) {
    ASSERT(_names_are_sorted());
  }

  static CallShape invalid() { return CallShape(-1); }

  bool is_valid() const { return arity_ >= 0; }
  bool is_setter() const { return is_setter_; }

  /// The arity of the method/call.
  /// Includes blocks, implicit `this` (where given), and named arguments.
  int arity() const { return arity_; }

  /// The total number of arguments that are blocks.
  int total_block_count() const {
    return total_block_count_;
  }

  /// The number of unnamed non-block arguments.
  int unnamed_non_block_count() const {
    return arity() - names().length() - unnamed_block_count();
  }
  int unnamed_block_count() const {
    return total_block_count_ - named_block_count_;
  }
  /// The number of arguments that are named *and* are blocks.
  int named_block_count() const {
    return named_block_count_;
  }
  /// The number of arguments that are named *and* are blocks.
  int named_non_block_count() const {
    return names_.length() - named_block_count_;
  }

  /// Whether argument [i] is a block.
  bool is_block(int i) const {
    int unnamed_args_count = arity_ - names_.length();
    int unnamed_block_count = total_block_count_ - named_block_count_;
    int unnamed_non_blocks = unnamed_args_count - unnamed_block_count;
    if (i < unnamed_non_blocks) return false;
    if (i < unnamed_args_count) return true;
    return i >= arity_ - named_block_count_;
  }

  // The names of the arguments.
  //
  // The names apply to the last arguments. In other words: named arguments are
  // passed last.
  // The last `named_block_count` named arguments are blocks.
  // Names are sorted alphabetically in two sections. The non-block arguments first,
  // then the block arguments.
  List<Symbol> names() const { return names_; }

  /// Returns the name of argument [i].
  ///
  /// Returns Symbol::invalid() if the argument is not named.
  Symbol name_for(int i) const {
    int unnamed_args_count = arity_ - names_.length();
    if (i < unnamed_args_count) return Symbol::invalid();
    return names_[i - unnamed_args_count];
  }
  bool has_named_arguments() const { return names_.length() > 0; }

  bool operator==(const CallShape& other) const {
    if (is_setter() == other.is_setter()
        && arity() == other.arity()
        && total_block_count_ == other.total_block_count_
        && named_block_count_ == other.named_block_count_
        && names_.length() == other.names_.length()) {
      for (int i = 0; i < names_.length(); i++) {
        if (names_[i] != other.names_[i]) return false;
      }
      return true;
    }
    return false;
  }

  bool operator!=(const CallShape& other) const {
    return !(*this == other);
  }

  static CallShape for_static_call_no_named(List<ir::Expression*> arguments);
  static CallShape for_instance_call_no_named(List<ir::Expression*> arguments);
  static CallShape for_static_setter() { return CallShape(1, 0, List<Symbol>(), 0, true); }
  static CallShape for_static_getter() { return CallShape(0, 0, List<Symbol>(), 0, false); }
  static CallShape for_instance_setter() { return CallShape(2, 0, List<Symbol>(), 0, true); }
  static CallShape for_instance_getter() { return CallShape(1, 0, List<Symbol>(), 0, false); }

  CallShape with_implicit_this() const {
    return CallShape(arity_ + 1, total_block_count_, names_, named_block_count_, is_setter_);
  }
  CallShape without_implicit_this() const {
    ASSERT(unnamed_non_block_count() > 0);
    return CallShape(arity_ - 1, total_block_count_, names_, named_block_count_, is_setter_);
  }

  /// This shape where all optional arguments are given.
  PlainShape to_plain_shape() const;

  size_t hash() const {
    if (is_setter()) return 91231513;

    int result = (arity() << 8)
        ^ total_block_count()
        ^ (named_block_count() << 6)
        ^ (names().length() << 4);
    for (int i = 0; i < names().length(); i++) {
      result ^= names()[i].hash() << (i % 16);
    }
    return result;
  }

  bool less(const CallShape& other) const {
    if (is_setter() != other.is_setter()) return is_setter();
    if (arity() != other.arity()) return arity() < other.arity();
    if (total_block_count() != other.total_block_count()) return total_block_count() < other.total_block_count();
    if (named_block_count() != other.named_block_count()) return named_block_count() < other.named_block_count();
    auto a_names = names();
    auto b_names = other.names();
    if (a_names.length() != b_names.length()) return a_names.length() < b_names.length();
    for (int i = 0; i < a_names.length(); i++) {
      if (a_names[i].c_str() != b_names[i].c_str()) return a_names[i].c_str() < b_names[i].c_str();
    }
    return false;
  }

 private:
  int arity_;
  int total_block_count_;
  List<Symbol> names_;
  int named_block_count_;
  bool is_setter_;

  bool _names_are_sorted() {
    // The names are sorted in two sections: non-blocks and blocks.
    for (int j = 0; j < 2; j++) {
      int start = (j == 0) ? 0 : (names_.length() - named_block_count_);
      int end = (j == 0) ? (names_.length() - named_block_count_) : names_.length();
      for (int i = start + 1; i < end; i++) {
        if (strcmp(names_[i - 1].c_str(), names_[i].c_str()) > 0) return false;
      }
    }
    return true;
  }
};

/// The shape an instance method takes after resolution.
///
/// At this point methods are fixed. That is, they don't take optional parameters,
/// and named parameters are set. If there are some, then they are required.
///
/// After resolution there is a clear 1-to-1 correspondence between a CallShape and the
/// shape of a method. (This is visible in the implementation of this class, which is
/// just a wrapper around the CallShape counterpart).
class PlainShape {
 public:
  explicit PlainShape(const CallShape& shape) : call_shape_(shape) {}

  bool operator==(const PlainShape& other) const { return call_shape_ == other.call_shape_; }
  bool operator!=(const PlainShape& other) const { return !(*this == other); }

  static PlainShape invalid() { return PlainShape(CallShape::invalid()); }
  bool is_valid() const { return call_shape_.is_valid(); }
  /// Whether the method was marked as setter. This does not imply that the
  ///   the method takes the correct number of arguments.
  bool is_setter() const { return call_shape_.is_setter(); }

  int arity() const { return call_shape_.arity(); }
  int total_block_count() const { return call_shape_.total_block_count(); }
  int named_block_count() const { return call_shape_.named_block_count(); }
  int unnamed_block_count() const { return call_shape_.unnamed_block_count(); }
  List<Symbol> names() const { return call_shape_.names(); }

  CallShape to_equivalent_call_shape() const { return call_shape_; }

  size_t hash() const {
    return call_shape_.hash();
  }

  bool less(const PlainShape& other) const {
    return call_shape_.less(other.call_shape_);
  }

 private:
  CallShape call_shape_;
};

class ResolutionShape {
 public:
  // A simple shape for static functions.
  explicit ResolutionShape(int arity)
      : call_shape_(arity, 0, List<Symbol>(), 0, false)
      , optional_unnamed_(0)
      , optional_names_(std::vector<bool>()) { }

  static ResolutionShape invalid() { return ResolutionShape(-1); }
  bool is_valid() const { return call_shape_.is_valid(); }
  /// Whether the method was marked as setter. This does not imply that the
  ///   the method takes the correct number of arguments.
  bool is_setter() const { return call_shape_.is_setter(); }

  /// The maximum arity of the function.
  ///
  /// This number includes `this` (if applicable), all named, and optional
  /// parameters (including the ones with default-values).
  int max_arity() const { return call_shape_.arity(); }

  int total_block_count() const { return call_shape_.total_block_count(); }

  /// The minimal number of unnamed non-block arguments.
  int min_unnamed_non_block() const {
    return call_shape_.unnamed_non_block_count() - optional_unnamed_;
  }
  /// The maximal number of *unnamed* non-block arguments.
  int max_unnamed_non_block() const {
    return call_shape_.unnamed_non_block_count();
  }

  // The number of *unnamed* block arguments.
  int unnamed_block_count() const { return call_shape_.unnamed_block_count(); }

  /// The names of all parameters.
  ///
  /// Some of these might be optional. See [optional_names] to see which ones.
  List<Symbol> names() const { return call_shape_.names(); }

  /// The number of blocks among the names. These are last in the [names] list.
  int named_non_block_count() const { return call_shape_.names().length(); }

  /// The number of blocks among the names. These are last in the [names] list.
  int named_block_count() const { return call_shape_.named_block_count(); }

  /// A bit-vector, encoding which names are optional (and thus
  /// have a default value.
  ///
  std::vector<bool> optional_names() const {
    return optional_names_;
  }

  bool has_optional_parameters() const {
    if (is_setter()) return false;
    if (optional_unnamed_ != 0) return true;
    for (size_t i = 0; i < optional_names_.size(); i++) {
      if (optional_names_[i]) return true;
    }
    return false;
  }

  bool operator==(const ResolutionShape& other) const {
    return call_shape_ == other.call_shape_ &&
       optional_unnamed_ == other.optional_unnamed_ &&
       optional_names_ == other.optional_names_;
  }

  bool operator!=(const ResolutionShape& other) const {
    return !(*this == other);
  }

  static ResolutionShape for_instance_method(ast::Method* method);
  static ResolutionShape for_static_method(ast::Method* method);
  static ResolutionShape for_instance_field_accessor(bool is_getter) {
    if (is_getter) return ResolutionShape(0).with_implicit_this();
    return ResolutionShape(CallShape::for_instance_setter());

  }
  ResolutionShape with_implicit_this() const {
    return ResolutionShape(call_shape_.with_implicit_this(),
                           optional_unnamed_,
                           optional_names_);
  }
  ResolutionShape without_implicit_this() const {
    return ResolutionShape(call_shape_.without_implicit_this(),
                           optional_unnamed_,
                           optional_names_);
  }

  /// Returns the method's shape as if all optional parameters were given.
  PlainShape to_plain_shape() const;

  bool accepts(const CallShape& shape);

  /// Returns whether this and the other shape have an overlap.
  bool overlaps_with(const ResolutionShape& other);

  /// Returns whether the given list of overriders fully shadow this shape.
  /// If the response is false, but this shape is partially shadowed, fills the
  /// [see_through] shape with an example of a call-shape that would not be
  /// intercepted by the overriders.
  /// If it is not shadowed at all, then the [see_through] shape is invalid.
  bool is_fully_shadowed_by(const std::vector<ResolutionShape> overriders, CallShape* see_through);

  size_t hash() const {
    return call_shape_.hash()
        ^ (optional_unnamed_ << 7)
        ^ (std::hash<std::vector<bool>>()(optional_names_) << 12);
  }

  bool less(const ResolutionShape& other) const {
    if (call_shape_ != other.call_shape_) {
      return call_shape_.less(other.call_shape_);
    }
    if (optional_unnamed_ != other.optional_unnamed_) {
      return optional_unnamed_ < other.optional_unnamed_;
    }
    return optional_names_ < other.optional_names_;
  }

 private:
  ResolutionShape(int arity,
                  int total_block_count,
                  List<Symbol> names,
                  int named_block_count,
                  bool is_setter,
                  int optional_unnamed,
                  const std::vector<bool>& optional_names)
      : call_shape_(arity, total_block_count, names, named_block_count, is_setter)
      , optional_unnamed_(optional_unnamed)
      , optional_names_(optional_names) { }

  ResolutionShape(const CallShape& call_shape,
                  int optional_unnamed,
                  const std::vector<bool>& optional_names)
      : call_shape_(call_shape)
      , optional_unnamed_(optional_unnamed)
      , optional_names_(optional_names) { }

  explicit ResolutionShape(const CallShape& call_shape)
      : call_shape_(call_shape)
      , optional_unnamed_(0)
      , optional_names_(std::vector<bool>()) { }

  friend class ListBuilder<ResolutionShape>;
  ResolutionShape() :call_shape_(CallShape::invalid()) { }

  CallShape call_shape_;
  int optional_unnamed_;
  std::vector<bool> optional_names_;
};

} // namespace toit::compiler
} // namespace toit

namespace std {
  template <> struct hash<::toit::compiler::CallShape> {
    std::size_t operator()(const ::toit::compiler::CallShape& shape) const {
      return shape.hash();
    }
  };
  template <> struct less<::toit::compiler::CallShape> {
    bool operator()(const ::toit::compiler::CallShape& a,
                    const ::toit::compiler::CallShape& b) const {
      return a.less(b);
    }
  };

  template <> struct hash<::toit::compiler::PlainShape> {
    std::size_t operator()(const ::toit::compiler::PlainShape& shape) const {
      return shape.hash();
    }
  };
  template <> struct less<::toit::compiler::PlainShape> {
    bool operator()(const ::toit::compiler::PlainShape& a,
                    const ::toit::compiler::PlainShape& b) const {
      return a.less(b);
    }
  };

  template <> struct hash<::toit::compiler::ResolutionShape> {
    std::size_t operator()(const ::toit::compiler::ResolutionShape& shape) const {
      return shape.hash();
    }
  };

  template <> struct less<::toit::compiler::ResolutionShape> {
    bool operator()(const ::toit::compiler::ResolutionShape& a,
                    const ::toit::compiler::ResolutionShape& b) const {
      return a.less(b);
    }
  };
}  // namespace std
