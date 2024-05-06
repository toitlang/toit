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

#include "selector.h"
#include <algorithm>

#include "ast.h"
#include "ir.h"
#include "set.h"

namespace toit {
namespace compiler {

void CallBuilder::prefix_argument(ir::Expression* arg) {
  auto old_args = args_;
  args_.clear();
  add_argument(arg, Symbol::invalid());
  args_.insert(args_.end(), old_args.begin(), old_args.end());
}

void CallBuilder::add_argument(ir::Expression* arg, Symbol name) {
  args_.push_back(Arg(arg, arg->is_block(), name));
  if (name.is_valid()) named_count_++;
  if (arg->is_block()) block_count_++;
}

void CallBuilder::add_arguments(List<ir::Expression*> args) {
  for (auto arg : args) add_argument(arg, Symbol::invalid());
}

CallShape CallBuilder::shape() {
  if (named_count_ == 0) {
    return CallShape(args_.size(), block_count_);
  } else {
    std::vector<Arg> sorted_args = args_;  // Make a copy.
    sort_arguments(&sorted_args);

    int named_count = 0;
    int named_block_count = 0;
    for (auto arg : sorted_args) {
      if (arg.name.is_valid()) named_count++;
      if (arg.name.is_valid() && arg.is_block) named_block_count++;
    }
    List<Symbol> names = ListBuilder<Symbol>::allocate(named_count);
    int unnamed_args_count = sorted_args.size() - named_count;
    for (int i = 0; i < named_count; i++) {
      names[i] = sorted_args[i + unnamed_args_count].name;
      ASSERT(names[i].is_valid());
    }
    return CallShape(sorted_args.size(), block_count_, names, named_block_count, false);
  }
}

ir::Expression* CallBuilder::call_constructor(ir::ReferenceMethod* target) {
  auto method_shape = target->target()->resolution_shape();
  bool has_implicit_this = true;
  return do_call_static(method_shape, has_implicit_this, [&](CallShape call_shape, List<ir::Expression*> args) {
    return _new ir::CallConstructor(target, call_shape, args, range_);
  });
}
ir::Expression* CallBuilder::call_static(ir::ReferenceMethod* target) {
  auto method_shape = target->target()->resolution_shape();
  bool has_implicit_this = false;
  return do_call_static(method_shape, has_implicit_this, [&](CallShape call_shape, List<ir::Expression*> args) {
    return _new ir::CallStatic(target, call_shape, args, range_);
  });
}
ir::Expression* CallBuilder::call_builtin(ir::Builtin* builtin) {
  ResolutionShape method_shape(builtin->arity());
  bool has_implicit_this = false;
  return do_call_static(method_shape, has_implicit_this, [&](CallShape call_shape, List<ir::Expression*> args) {
    return _new ir::CallBuiltin(builtin, call_shape, args, range_);
  });
}
ir::Expression* CallBuilder::call_block(ir::Expression* block) {
  return do_block_call(block, [&](ir::Expression* block, CallShape call_shape, List<ir::Expression*> args) {
    return _new ir::CallBlock(block, call_shape, args, range_);
  });
}
ir::Expression* CallBuilder::call_instance(ir::Dot* dot) {
  return call_instance(dot, Source::Range::invalid());
}
ir::Expression* CallBuilder::call_instance(ir::Dot* dot, Source::Range range) {
  if (!range.is_valid()) range = range_;
  return do_call_instance(dot, [&](ir::Dot* dot, CallShape call_shape, List<ir::Expression*> args) {
    return _new ir::CallVirtual(dot, call_shape, args, range);
  });
}

void CallBuilder::sort_parameters(std::vector<ast::Parameter*>& parameters) {
  struct {
    bool operator()(ast::Parameter* a, ast::Parameter* b) const {
      // Two sections, in each of which we first have non-block args, then block-args.
      // The named block|non-block section is furthermore alphabetically sorted.
      if (a->is_named() != b->is_named()) return !a->is_named();
      if (a->is_block() != b->is_block()) return !a->is_block();
      if (a->is_named()) {
        return strcmp(a->name()->data().c_str(), b->name()->data().c_str()) < 0;
      }
      // Not named, and same blockness: consider equal for the stable sort.
      return false;
    }
  } parameter_less;
  std::stable_sort(parameters.begin(), parameters.end(), parameter_less);
}

// Sorts the arguments for instance calls.
// The same ordering is also used for creating the call-shape.
void CallBuilder::sort_arguments(std::vector<Arg>* args) {
  struct {
    // This needs to stay in sync with [ResolutionShape::for_static_method].
    bool operator()(const Arg& a, const Arg& b) const {
      // Two sections, in each of which we first have non-block args, then block-args.
      // The named block|non-block section is furthermore alphabetically sorted.
      if (a.is_named() != b.is_named()) return !a.is_named();
      if (a.is_block != b.is_block) return !a.is_block;
      if (a.is_named()) return strcmp(a.name.c_str(), b.name.c_str()) < 0;
      // Not named, and same blockness: consider equal for the stable sort.
      return false;
    }
  } arg_less;
  std::stable_sort((*args).begin(), (*args).end(), arg_less);
}

// Hoists arguments out of the call if necessary.
//
// Updates the expression in the [args_] vector with references to the temporary variables.
//
// This is necessary for blocks, and calls that have named arguments.
//
// Blocks must be stored in locals (so that the reference to them can point to the
// stack where they are stored).
//
// If the call has named arguments, creates temporary variables to ensure that the
// evaluation order is correct.
//
// The given [fun] function may freely reorder all arguments without
// worrying about evaluation order.
ir::Expression* CallBuilder::with_hoisted_args(ir::Expression* target,
                                               std::function<ir::Expression* (ir::Expression*)> fun) {

  // Just a few shortcuts.
  if (target == null || !target->is_block()) {
    if (named_count_ == 0 && block_count_ == 0) return fun(target);
    if (block_count_ == 0 && args_.size() <= 1) return fun(target);
  }

  ListBuilder<ir::Expression*> sequence_exprs;
  auto create_temporary_if_necessary = [&] (ir::Expression* expression) {
    // Block-code can not be in the middle of a call. They must be evaluated separately and
    // get referenced through a `ReferenceBlock`.
    if (expression->is_Code()) {
      auto code = expression->as_Code();
      auto block = _new ir::Block(Symbol::synthetic("<block>"), code->range());
      sequence_exprs.add(_new ir::AssignmentDefine(block, code, code->range()));
      return (_new ir::ReferenceBlock(block, 0, expression->range()))->as_Expression();
    }
    // If there are no named arguments, then we don't need to create temporaries for any
    // other type.
    if (named_count_ == 0) return expression;

    if (expression->is_Reference()) return expression;
    if (expression->is_Literal()) return expression;

    auto temporary = _new ir::Local(Symbol::synthetic("<tmp>"),
                                    true,   // Final.
                                    expression->is_block(),
                                    expression->range());
    sequence_exprs.add(_new ir::AssignmentDefine(temporary, expression, expression->range()));
    return (_new ir::ReferenceLocal(temporary, 0, expression->range()))->as_Expression();
  };

  // Create temporaries, so that we can guarantee the evaluation order.
  if (target != null) {
    target = create_temporary_if_necessary(target);
  }
  for (auto& arg : args_) {
    arg.expression = create_temporary_if_necessary(arg.expression);
  }

  if (sequence_exprs.is_empty()) return fun(target);

  sequence_exprs.add(fun(target));
  return _new ir::Sequence(sequence_exprs.build(), range_);
}

ir::Expression* CallBuilder::do_call_static(ResolutionShape shape,
                                            bool has_implicit_this,
                                            std::function<ir::Call* (CallShape shape, List<ir::Expression*>)> create_call) {
  return with_hoisted_args(null, [&](ir::Expression* _) {
    // For simplicity, remove the implicit this from the shape if necessary.
    if (has_implicit_this) shape = shape.without_implicit_this();
    int provided_count = args_.size();
    int needed_count = shape.max_arity();
    List<ir::Expression*> ir_arguments = ListBuilder<ir::Expression*>::allocate(needed_count);

    if (provided_count == needed_count && named_count_ == 0) {
      // Shortcut for the usual case where there are no named arguments, and we don't need to fill
      // optional arguments.
      for (size_t i = 0; i < args_.size(); i++) {
        ir_arguments[i] = args_[i].expression;
      }
      CallShape call_shape(needed_count, block_count_);
      if (has_implicit_this) call_shape = call_shape.with_implicit_this();
      return create_call(call_shape, ir_arguments);
    }

    size_t argument_index = 0;
    int unnamed_non_block_count = shape.max_unnamed_non_block();
    int unnamed_block_count = shape.unnamed_block_count();

    auto next_ir_arg = [&](bool must_be_non_block) {
      // Skip over named arguments. Those are handled differently.
      while (argument_index < args_.size() &&
              args_[argument_index].is_named()) {
        argument_index++;
      }
      // Fill up non-block and block arguments independently.
      if (argument_index < args_.size()) {
        if (must_be_non_block && args_[argument_index].is_block) {
          // Fill up the non-block arg.
          return (_new ir::LiteralNull(range_))->as_Expression();
        }
        return args_[argument_index++].expression;
      }
      if (!must_be_non_block) FATAL("Block arguments can't have default value");
      return (_new ir::LiteralNull(range_))->as_Expression();
    };

    int ir_argument_index = 0;
    for (int i = 0; i < unnamed_non_block_count; i++) {
      ir_arguments[ir_argument_index++] = next_ir_arg(true);
    }
    for (int i = 0; i < unnamed_block_count; i++) {
      ir_arguments[ir_argument_index++] = next_ir_arg(false);
    }

    UnorderedMap<Symbol, Arg> named_mapping;
    for (auto arg : args_) {
      if (arg.is_named()) named_mapping[arg.name] = arg;
    }
    int named_non_block_count = shape.names().length() - shape.named_block_count();
    int used_names_count = 0;

    for (int i = 0; i < shape.names().length(); i++) {
      auto name = shape.names()[i];
      bool is_block = i >= named_non_block_count;
      auto probe = named_mapping.find(name);
      if (probe != named_mapping.end()) {
        used_names_count++;
        ir_arguments[ir_argument_index++] = probe->second.expression;
        if (is_block != probe->second.is_block) FATAL("Block mismatch");
        continue;
      }
      if (!shape.optional_names()[i]) FATAL("Not optional argument");
      ir_arguments[ir_argument_index++] = _new ir::LiteralNull(range_);
    }
    ASSERT(used_names_count == named_mapping.size());

    CallShape call_shape(needed_count, block_count_,
                         shape.names(), shape.named_block_count(), false);
    if (has_implicit_this) call_shape = call_shape.with_implicit_this();
    return create_call(call_shape, ir_arguments);
  });
}

ir::Expression* CallBuilder::do_call_instance(ir::Dot* dot,
                                              std::function<ir::Call* (ir::Dot* dot, CallShape shape, List<ir::Expression*>)> create_call) {
  return with_hoisted_args(dot->receiver(), [&](ir::Expression* new_receiver) {
    dot->replace_receiver(new_receiver);
    int arity = args_.size();
    CallShape call_shape(0);
    if (named_count_ == 0) {
      call_shape = CallShape(arity, block_count_).with_implicit_this();
    } else {
      // Sort the arguments in-place.
      // At this point we can change the args-vector, since it may contain references to temporary variables
      // anyway.
      sort_arguments(&args_);
      auto names = ListBuilder<Symbol>::allocate(named_count_);
      int named_block_count = 0;
      for (int i = 0; i < named_count_; i++) {
        auto arg = args_[args_.size() - named_count_ + i];
        names[i] = arg.name;
        ASSERT(names[i].is_valid());
        if (arg.is_block) named_block_count++;
      }
      call_shape = CallShape(arity, block_count_, names, named_block_count, false).with_implicit_this();
    }
    auto ir_arguments = ListBuilder<ir::Expression*>::allocate(arity);
    for (size_t i = 0; i < args_.size(); i++) ir_arguments[i] = args_[i].expression;

    return create_call(dot, call_shape, ir_arguments);
  });
}

ir::Expression* CallBuilder::do_block_call(ir::Expression* block,
                                           std::function<ir::Call* (ir::Expression* block, CallShape shape, List<ir::Expression*>)> create_call) {
  return with_hoisted_args(block, [&](ir::Expression* new_block) {
    int arity = args_.size();
    auto ir_arguments = ListBuilder<ir::Expression*>::allocate(arity);
    for (size_t i = 0; i < args_.size(); i++) ir_arguments[i] = args_[i].expression;
    CallShape call_shape = CallShape(arity, block_count_).with_implicit_this();
    return create_call(new_block, call_shape, ir_arguments);
  });
}

void CallBuilder::match_arguments_with_parameters(CallShape call_shape,
                                                  ResolutionShape resolution_shape,
                                                  const std::function<void (int argument_index, int parameter_index)> callback) {
  ASSERT(resolution_shape.accepts(call_shape));
  int arg_index = 0;
  int parameter_index = 0;
  for (int i = 0; i < call_shape.unnamed_non_block_count(); i++) {
    ASSERT(!call_shape.name_for(arg_index).is_valid());
    callback(arg_index++, parameter_index++);
  }

  parameter_index = resolution_shape.max_unnamed_non_block();
  for (int i = 0; i < call_shape.unnamed_block_count(); i++) {
    ASSERT(!call_shape.name_for(arg_index).is_valid());
    callback(arg_index++, parameter_index++);
  }

  parameter_index = resolution_shape.max_unnamed_non_block() + resolution_shape.unnamed_block_count();
  auto parameter_names = resolution_shape.names();
  int names_offset = parameter_index;
  for (auto name : call_shape.names()) {
    while (parameter_names[parameter_index - names_offset] != name) {
      parameter_index++;
    }
    callback(arg_index++, parameter_index++);
  }
}

} // namespace toit::compiler
} // namespace toit

