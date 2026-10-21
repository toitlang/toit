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

#include "ast_resolution.h"
#include "resolution.h"

namespace toit {
namespace compiler {

namespace ast { class Parameter; }

class ResolutionCallBuilder {
 public:
  explicit ResolutionCallBuilder(Source::Range range)
      : range_(range)
      , named_count_(0)
      , block_count_(0) {}

  CallShape shape();
  List<resolution::View<resolution::Expression>> arguments() {
    auto result = ListBuilder<resolution::View<resolution::Expression>>::allocate(args_.size());
    for (size_t i = 0; i < args_.size(); i++) {
      result[i] = args_[i].expression;
    }
    return result;
  }

  void prefix_argument(resolution::View<resolution::Expression> arg);
  void add_argument(resolution::View<resolution::Expression> arg, Symbol name);
  void add_arguments(List<resolution::View<resolution::Expression>> args);

  resolution::View<resolution::Expression> call_constructor(resolution::View<resolution::ReferenceMethod> target);
  resolution::View<resolution::Expression> call_static(resolution::View<resolution::ReferenceMethod> target);
  resolution::View<resolution::Expression> call_builtin(resolution::View<resolution::Builtin> builtin);
  resolution::View<resolution::Expression> call_block(resolution::View<resolution::Expression> block);  // Code or reference to block.
  resolution::View<resolution::Expression> call_instance(resolution::View<resolution::Dot> dot);
  resolution::View<resolution::Expression> call_instance(resolution::View<resolution::Dot> dot, Source::Range range);

  bool has_block_arguments() const { return block_count_ > 0; }
  bool has_named_arguments() const { return named_count_ > 0; }

  /// Sorts the parameters corresponding to how the ResolutionCallBuilder does the call.
  static void sort_parameters(std::vector<ast::Parameter*>& parameters);

  static void match_arguments_with_parameters(CallShape call_shape,
                                              ResolutionShape resolution_shape,
                                              const std::function<void (int argument_index, int parameter_index)>& callback);
 private:
  struct Arg {
    Arg() : expression(null), is_block(false), name(Symbol::invalid()) {}
    Arg(resolution::View<resolution::Expression> expression, bool is_block, Symbol name)
        : expression(expression), is_block(is_block), name(name) {}

    resolution::View<resolution::Expression> expression;
    bool is_block;
    Symbol name;  // Symbol::invalid() if not given.

    bool is_named() const { return name.is_valid(); }
  };
  std::vector<Arg> args_;
  Source::Range range_;
  int named_count_;
  int block_count_;

  // Sorts the arguments for instance calls.
  // The same ordering is also used for creating the call-shape.
  void sort_arguments(std::vector<Arg>* args);

  // If the call has named arguments, creates temporary variables to ensure that the
  // evaluation order is correct.
  // Updates the expression in the [args_] vector with references to the temporary variables.
  //
  // The given [fun] function may freely reorder all arguments without
  // worrying about evaluation order.
  resolution::View<resolution::Expression> with_hoisted_args(resolution::View<resolution::Expression> target,
                                    const std::function<resolution::View<resolution::Expression> (resolution::View<resolution::Expression>)>& fun);

  resolution::View<resolution::Expression> do_call_static(ResolutionShape shape,
                                 bool has_implicit_this,
                                 const std::function<resolution::View<resolution::Call> (CallShape shape, List<resolution::View<resolution::Expression>>)>& create_call);
  resolution::View<resolution::Expression> do_call_instance(resolution::View<resolution::Dot> dot,
                                   const std::function<resolution::View<resolution::Call> (resolution::View<resolution::Dot> dot, CallShape shape, List<resolution::View<resolution::Expression>>)>& create_call);
  resolution::View<resolution::Expression> do_block_call(resolution::View<resolution::Expression> block,
                                const std::function<resolution::View<resolution::Call> (resolution::View<resolution::Expression> block, CallShape shape, List<resolution::View<resolution::Expression>>)>& create_call);
};

} // namespace toit::compiler
} // namespace toit
