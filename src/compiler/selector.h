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

#include <functional>
#include <vector>

#include "list.h"
#include "map.h"
#include "shape.h"
#include "sources.h"
#include "symbol.h"

/**
 * A selector is the combination of 'name' and 'shape'.
 */

namespace toit {
namespace compiler {

namespace ir {
  class Call;
  class Dot;
  class Expression;
  class ReferenceLocal;
  class ReferenceMethod;
  class Builtin;
}

namespace ast {
  class Parameter;
}

template<typename Shape>
class Selector {
 public:
  Selector(Symbol name, Shape shape) : _name(name), _shape(shape) {}

  Symbol name() const { return _name; }

  Shape shape() const { return _shape; }

  bool operator==(const Selector& other) const {
    return _name == other._name && _shape == other._shape;
  }

  bool operator!=(const Selector& other) const {
    return !(*this == other);
  }

  size_t hash() const {
    return (_name.hash() << 16) ^ _shape.hash();
  }

  bool less(const Selector<Shape>& other) const {
    if (_name.c_str() != other._name.c_str()) {
      return _name.c_str() < other._name.c_str();
    }
    return _shape.less(other._shape);
  }

  bool is_valid() const { return _name.is_valid(); }

 private:
  Symbol _name;
  Shape _shape;
};

class CallBuilder {
 public:
  explicit CallBuilder(Source::Range range)
      : _range(range)
      , _named_count(0)
      , _block_count(0) {}

  CallShape shape();
  List<ir::Expression*> arguments() {
    auto result = ListBuilder<ir::Expression*>::allocate(_args.size());
    for (size_t i = 0; i < _args.size(); i++) {
      result[i] = _args[i].expression;
    }
    return result;
  }

  void prefix_argument(ir::Expression* arg);
  void add_argument(ir::Expression* arg, Symbol name);
  void add_arguments(List<ir::Expression*> args);

  ir::Expression* call_constructor(ir::ReferenceMethod* target);
  ir::Expression* call_static(ir::ReferenceMethod* target);
  ir::Expression* call_builtin(ir::Builtin* builtin);
  ir::Expression* call_block(ir::Expression* block);  // Code or reference to block.
  ir::Expression* call_instance(ir::Dot* dot);
  ir::Expression* call_instance(ir::Dot* dot, Source::Range range);

  bool has_block_arguments() const { return _block_count > 0; }
  bool has_named_arguments() const { return _named_count > 0; }

  /// Sorts the parameters corresponding to how the CallBuilder does the call.
  static void sort_parameters(std::vector<ast::Parameter*>& parameters);

  static void match_arguments_with_parameters(CallShape call_shape,
                                              ResolutionShape resolution_shape,
                                              const std::function<void (int argument_index, int parameter_index)> callback);
 private:
  struct Arg {
    Arg() : expression(null), is_block(false), name(Symbol::invalid()) {}
    Arg(ir::Expression* expression, bool is_block, Symbol name)
        : expression(expression), is_block(is_block), name(name) {}

    ir::Expression* expression;
    bool is_block;
    Symbol name;  // Symbol::invalid() if not given.

    bool is_named() const { return name.is_valid(); }
  };
  std::vector<Arg> _args;
  Source::Range _range;
  int _named_count;
  int _block_count;

  // Sorts the arguments for instance calls.
  // The same ordering is also used for creating the call-shape.
  void sort_arguments(std::vector<Arg>* args);

  // If the call has named arguments, creates temporary variables to ensure that the
  // evaluation order is correct.
  // Updates the expression in the [_args] vector with references to the temporary variables.
  //
  // The given [fun] function may freely reorder all arguments without
  // worrying about evaluation order.
  ir::Expression* with_hoisted_args(ir::Expression* target,
                                    std::function<ir::Expression* (ir::Expression*)> fun);

  ir::Expression* do_call_static(ResolutionShape shape,
                                 bool has_implicit_this,
                                 std::function<ir::Call* (CallShape shape, List<ir::Expression*>)> create_call);
  ir::Expression* do_call_instance(ir::Dot* dot,
                                   std::function<ir::Call* (ir::Dot* dot, CallShape shape, List<ir::Expression*>)> create_call);
  ir::Expression* do_block_call(ir::Expression* block,
                                std::function<ir::Call* (ir::Expression* block, CallShape shape, List<ir::Expression*>)> create_call);
};

} // namespace toit::compiler
} // namespace toit

namespace std {
  template <typename Shape> struct hash<::toit::compiler::Selector<Shape>> {
    std::size_t operator()(const ::toit::compiler::Selector<Shape>& selector) const {
      return selector.hash();
    }
  };
  template <typename Shape> struct less<::toit::compiler::Selector<Shape>> {
    bool operator()(const ::toit::compiler::Selector<Shape>& a, const ::toit::compiler::Selector<Shape>& b) const {
      return a.less(b);
    }
  };
}  // namespace std
