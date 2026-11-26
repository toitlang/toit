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

#include <string>

#include "byte_gen.h"
#include "bytecode_format.h"
#include "emitter.h"
#include "program_builder.h"

#include "../interpreter.h"
#include "../flags.h"
#include "../objects_inline.h"

#define __ emitter()->

namespace toit {
namespace compiler {

using namespace ir;

int ByteGen::assemble_method(Method* method,
                             int dispatch_offset,
                             bool is_field_accessor) {
  return assemble_function(method,
                           dispatch_offset,
                           is_field_accessor,
                           source_mapper_->register_method(method));
}

int ByteGen::assemble_global(ir::Global* global) {
  return assemble_function(global,
                           -1,     // dispatch_offset.
                           false,  // is_field_accessor.
                           source_mapper_->register_global(global));
}

int ByteGen::assemble_function(ir::Method* function,
                               int dispatch_offset,
                               bool is_field_accessor,
                               SourceMapper::MethodMapper method_mapper) {
  ASSERT(!method_mapper_.is_valid());
  ASSERT(method_ == null);
  ASSERT(emitter_ == null);

  method_mapper_ = method_mapper;
  method_ = function;
  int arity = function->plain_shape().arity();
  Emitter emitter(arity);
  locals_count_ = 0;
  emitter_ = &emitter;

  visit(function);
  terminate_body();
  relax_branches();

  auto bytecodes = emitter.bytecodes();
  int max_height = emitter.max_height();

  int field_index = 0;
  if (is_field_accessor) {
    field_index = function->as_FieldStub()->field()->resolved_index();
  }
  int id = program_builder_->create_method(dispatch_offset,
                                           is_field_accessor,
                                           arity,
                                           bytecodes,
                                           max_height,
                                           receiver_range(function),
                                           field_index);

  method_mapper_.finalize(program_builder_->source_id_for(id), bytecodes.length());

  update_absolute_positions(program_builder_->absolute_bci_for(id),
                            emitter.build_absolute_uses(),
                            emitter.build_absolute_references());

  method_ = null;
  method_mapper_ = SourceMapper::MethodMapper::invalid();
  emitter_ = null;

  return id;
}

int ByteGen::_assemble_block(Code* node) {
  ASSERT(node->is_block());

  int arity = node->parameters().length() + 1;  // Add one for the implicit block argument.
  // The parameters are already shifted so that they can deal with the
  // extra block parameter.
  ASSERT(arity == 1 || node->parameters()[0]->index() != 0);

  auto mapper = method_mapper_.register_block(node);
  return _assemble_nested_function(node->body(),
                                   arity,
                                   true,  // A block.
                                   0,     // Ignored captured_count
                                   mapper);
}

int ByteGen::_assemble_lambda(Code* node) {
  ASSERT(!node->is_block());
  int arity = node->parameters().length();
  auto mapper = method_mapper_.register_lambda(node);
  return _assemble_nested_function(node->body(),
                                   arity,
                                   false, // Not a block.
                                   node->captured_count(),
                                   mapper);
}

int ByteGen::_assemble_nested_function(Node* body,
                                       int arity,
                                       bool is_block,
                                       int captured_count,
                                       SourceMapper::MethodMapper method_mapper) {
  auto old_emitter = emitter_;
  outer_emitters_stack_.push_back(old_emitter);

  Emitter nested_emitter(arity);
  emitter_ = &nested_emitter;
  auto old_mapper = method_mapper_;
  method_mapper_ = method_mapper;

  visit_for_value(body);
  __ ret();
  terminate_body();
  relax_branches();

  List<uint8> bytecodes = nested_emitter.bytecodes();
  int max_height = nested_emitter.max_height();
  int id = -1;
  if (is_block) {
    id = program_builder()->create_block(arity, bytecodes, max_height);
  } else {
    id = program_builder()->create_lambda(captured_count, arity, bytecodes, max_height);
  }
  method_mapper_.finalize(program_builder_->source_id_for(id), bytecodes.length());

  update_absolute_positions(program_builder_->absolute_bci_for(id),
                            nested_emitter.build_absolute_uses(),
                            nested_emitter.build_absolute_references());


  method_mapper_ = old_mapper;
  emitter_ = old_emitter;
  outer_emitters_stack_.pop_back();
  return id;
}

void ByteGen::update_absolute_positions(int absolute_entry_bci,
                                        const List<AbsoluteUse*>& uses,
                                        const List<AbsoluteReference>& references) {
  // Update the uses first, since they could point to one of the labels.
  for (auto use : uses) {
    use->make_absolute(absolute_entry_bci);
  }

  // Compute the positions, and patch all uses.
  for (auto ref : references) {
    int absolute_label_bci = ref.absolute_position(absolute_entry_bci);
    // Format 2 encodes the target of a non-local branch relative to the
    // entry of the method it branches into (the method of the target
    // frame).
    int encoded = is_format2() ? absolute_label_bci - absolute_entry_bci : absolute_label_bci;
    for (auto label_use : ref.absolute_uses()) {
      ASSERT(label_use->has_absolute_position());
      program_builder_->patch_uint32_at(label_use->absolute_position(), encoded);
    }
    ref.free_absolute_uses();
  }
}

ReceiverRange ByteGen::receiver_range(Method* method) {
  if (!is_format2() || method == null || !method->has_implicit_this()) return ReceiverRange();
  auto holder = method->holder();
  if (holder == null) return ReceiverRange();
  if (holder->kind() != Class::CLASS && holder->kind() != Class::MONITOR) return ReceiverRange();
  if (holder->start_id() < 0 || holder->end_id() <= holder->start_id()) return ReceiverRange();
  return ReceiverRange(holder->start_id(), holder->end_id());
}

bool ByteGen::is_declared_this(Expression* node) {
  if (!is_format2()) return false;
  if (!outer_emitters_stack_.empty()) return false;  // In a block or lambda.
  if (!receiver_range(method_).is_valid()) return false;
  if (!node->is_ReferenceLocal()) return false;
  auto ref = node->as_ReferenceLocal();
  if (ref->block_depth() != 0) return false;
  if (!ref->target()->is_Parameter()) return false;
  return ref->target()->as_Parameter()->index() == 0;
}

void ByteGen::relax_branches() {
  if (!is_format2()) return;
  // Format 3 (verified/spec/format/22-format3-branches-frames.md): the
  // short branches. The recorded source positions move with the code.
  emitter()->relax_branches();
  auto emitter = this->emitter();
  if (method_mapper_.is_valid()) {
    method_mapper_.relocate([emitter](int position) { return emitter->relocated(position); });
  }
}

void ByteGen::terminate_body() {
  if (!is_format2()) return;
  if (emitter()->ends_with_terminator()) return;
  // Only reachable if a method the compiler knows not to return does
  // return, or for the bodies of interface-check stubs, which are never
  // called. Every format-2 method ends in a terminator.
  __ load_null();
  __ _throw();
  emitter()->forget(1);
}

void ByteGen::visit(Node* node) {
#ifdef TOIT_DEBUG
  bool is_for_value = this->is_for_value();
  int height = emitter()->height();
  int locals = locals_count_;
#endif
  node->accept(this);
#ifdef TOIT_DEBUG
  ASSERT(is_for_value == this->is_for_value());
  int definitions = locals_count_ - locals;
  int expected = height + definitions + (is_for_value ? 1 : 0);
  if (emitter()->height() != expected) {
    printf("wrong stack height; expected %d but was %d\n", expected, emitter()->height());
    FATAL("internal error");
  }
#endif
}

void ByteGen::visit_for_effect(Node* node) {
  bool saved = is_for_value_;
  is_for_value_ = false;
  visit(node);
  is_for_value_ = saved;
}

void ByteGen::visit_for_value(Node* expression) {
  bool saved = is_for_value_;
  is_for_value_ = true;
  visit(expression);
  is_for_value_ = saved;
}

void ByteGen::visit_for_control(Expression* expression,
                                Label* yes,
                                Label* no,
                                Label* fallthrough) {
  if (expression->is_LiteralNull() ||
      (expression->is_LiteralBoolean() && !expression->as_LiteralBoolean()->value())) {
    // Condition evaluates to `false`.
    if (fallthrough != no) __ branch(Emitter::UNCONDITIONAL, no);
    return;
  }

  if (expression->is_Code() ||
      expression->is_Literal() ||
      (expression->is_ReferenceLocal() && expression->is_block())) {
    // Condition evaluates to `true`.
    if (fallthrough != yes) __ branch(Emitter::UNCONDITIONAL, yes);
    return;
  }

  if (expression->is_Not()) {
    visit_for_control(expression->as_Not()->value(), no, yes, fallthrough);
    return;
  }

  if (expression->is_LogicalBinary()) {
    auto logical = expression->as_LogicalBinary();
    bool is_and = logical->op() == LogicalBinary::AND;
    Label maybe;
    if (is_and) {
      visit_for_control(logical->left(), &maybe, no, &maybe);
    } else {
      visit_for_control(logical->left(), yes, &maybe, &maybe);
    }

    __ bind(&maybe);

    visit_for_control(logical->right(), yes, no, fallthrough);
    return;
  }

  if (yes == fallthrough && expression->is_CallBuiltin()) {
    auto builtin = expression->as_CallBuiltin();
    if (builtin->target()->kind() == Builtin::IDENTICAL) {
      bool left_is_null = builtin->arguments()[0]->is_LiteralNull();
      bool right_is_null = builtin->arguments()[1]->is_LiteralNull();
      if (left_is_null || right_is_null) {
        Expression* other = builtin->arguments()[left_is_null ? 1 : 0];
        visit_for_value(other);
        __ branch(Emitter::IF_NOT_NULL, no);
        return;
      }
    }
  }

  visit_for_value(expression);
  if (yes == fallthrough) {
    __ branch(Emitter::IF_FALSE, no);
  } else if (no == fallthrough) {
    __ branch(Emitter::IF_TRUE, yes);
  } else {
    ASSERT(fallthrough == null);
    __ branch(Emitter::IF_TRUE, yes);
    __ branch(Emitter::UNCONDITIONAL, no);
  }
}

void ByteGen::visit_Class(Class* node) { UNREACHABLE(); }
void ByteGen::visit_Field(Field* node) { UNREACHABLE(); }

void ByteGen::_generate_method(Method* node) {
  if (Flags::compiler) printf("-compiling %s\n", node->name().c_str());

  // No need to build the interface-stub.
  if (node->is_IsInterfaceOrMixinStub()) return;
  ASSERT(!node->is_dead());
  visit_for_effect(node->body());
  // Bodies that end in a call to a non-returning method (or a monitor
  // method's call to 'locked_') would otherwise fall off the end of the
  // method into the next method's header. The bytecode verifier and the
  // method-entry computation of the VM require an explicit terminator.
  // The emitter's height is not reliable here (block tokens of such calls
  // are forgotten rather than popped), so use a terminator that does not
  // encode the height.
  Opcode last = emitter()->previous_opcode();
  if (last != RETURN && last != RETURN_NULL && last != INVOKE_STATIC_TAIL) {
    __ load_null();
    __ _throw();
    // The body is visited for effect: the thrown value is not left on the
    // stack (the stack-height check in 'visit' expects no new value).
    emitter()->forget(1);
  }
}

void ByteGen::visit_MethodInstance(MethodInstance* node) { _generate_method(node); }
void ByteGen::visit_MonitorMethod(MonitorMethod* node) { _generate_method(node); }
void ByteGen::visit_MethodStatic(MethodStatic* node) { _generate_method(node); }
void ByteGen::visit_Constructor(Constructor* node) { _generate_method(node); }
void ByteGen::visit_AdapterStub(AdapterStub* node) { _generate_method(node); }
void ByteGen::visit_MixinStub(MixinStub* node) { _generate_method(node); }
void ByteGen::visit_IsInterfaceOrMixinStub(IsInterfaceOrMixinStub* node) { _generate_method(node); }
void ByteGen::visit_FieldStub(FieldStub* node) { _generate_method(node); }

void ByteGen::visit_Global(Global* node) { _generate_method(node); }

void ByteGen::visit_Code(Code* node) {
  if (is_for_effect()) return;

  // Push a block-construction token on the stack now, so that references
  // using load_outer are relative to the height of the stack, as if they were
  // locals or parameters.
  emitter_->remember(1, ExpressionStack::BLOCK_CONSTRUCTION_TOKEN);


  int id = node->is_block()
      ? _assemble_block(node)
      : _assemble_lambda(node);

  // Push the method id on the stack.
  __ load_method(id);

  // Pop the block-token, and replace it with the top of the stack (which is
  // an ExpressionStack::Object).
  emitter_->forget(2);
  emitter_->remember(1, ExpressionStack::OBJECT);
}

void ByteGen::visit_Nop(Nop* node) {
  if (is_for_effect()) return;
  // Empty sequences may be translated to nops. If we need a
  // value for such a sequence, it is safe to produce null.
  __ load_null();
}

void ByteGen::visit_Sequence(Sequence* node) {
  int old_locals_count = locals_count_;
  int old_height = emitter()->height();

  List<Expression*> expressions = node->expressions();
  int length = expressions.length();
  for (int i = 0; i < length - 1; i++) {
    visit_for_effect(expressions[i]);
  }

  if (length > 0) {
    // Visit in current state.
    visit(expressions[length - 1]);
  } else if (is_for_value()) {
    // Produce a value for the empty block if we need one.
    __ load_null();
  }

  // Pop all the locals of this sequence.
  int introduced_locals = locals_count_ - old_locals_count;
  if (is_for_value() && introduced_locals > 0) {
    // We need to store the value that is currently on the top of the stack
    // in the slot that is currently occupied by the first variable.
    __ store_local(old_height);
  }

  // Avoid popping locals at the end of the method or after returns
  // and non-local loop branches. It is dead code.
  int extra = locals_count_ - old_locals_count;
  bool end_of_method = node == method_->body();
  bool ends_with_return = length > 0 && expressions.last()->is_Return();
  bool ends_with_branch = length > 0 && expressions.last()->is_LoopBranch();
  if (end_of_method || ends_with_return || ends_with_branch) {
    emitter()->forget(extra);
  } else {
    __ pop(extra);
  }

  ASSERT(emitter()->height() == old_height + (is_for_value() ? 1 : 0));
  locals_count_ = old_locals_count;
}

void ByteGen::visit_TryFinally(TryFinally* node) {
  // Create the try block.
  int block_slot = emitter_->height();
  visit_for_value(node->body());

  if (is_format2()) {
    // TRY calls the try block with a handler, and continues with the
    // finally code when the block returns or is unwound. The finally code
    // finds the exception (or null), a token for the unwinding in
    // progress, and the reason on the stack, in the same slots as the
    // result, target and reason of format 1.
    __ try_finally();
  } else {
    __ link();
    int link_height = emitter_->height();

    __ load_block(block_slot);
    int after_body_height = emitter_->height();
    // The unwind code relies on the fact that there is only one stack-slot used
    // between the block-call and the pushed link information.
    ASSERT(after_body_height == link_height + 1);
    __ invoke_block(1);
    __ pop(1);

    // Unlink, invoke finally block, and continue unwinding.
    __ unlink();
  }

  int old_locals_count = locals_count_;
  auto handler_parameters = node->handler_parameters();
  if (!handler_parameters.is_empty()) {
    ASSERT(handler_parameters.length() == 2);
    int exception_height = emitter()->height() - Interpreter::LINK_RESULT_SLOT;
    int reason_height = emitter()->height() - Interpreter::LINK_REASON_SLOT;
    auto reason = handler_parameters[0];
    auto exception = handler_parameters[1];
    reason->set_index(register_local(reason_height));
    exception->set_index(register_local(exception_height));
  }
  visit_for_effect(node->handler());

  if (!handler_parameters.is_empty()) {
    ASSERT(locals_count_ == old_locals_count + 2);
    locals_count_ = old_locals_count;
  }
  __ unwind();

  __ pop(1); // Pop the pushed block.
  if (is_for_value()) __ load_null();
}

void ByteGen::visit_If(If* node) {
  Label yes_label, no_label, done_label;

  auto ir_condition = node->condition();
  auto ir_yes = node->yes();
  auto ir_no = node->no();

  if (is_for_value() && ir_no->is_Literal()) {
    // Produce the value of the if in case we
    // branch past the 'yes' block.
    visit_for_value(ir_no);
    visit_for_control(ir_condition, &yes_label, &no_label, &yes_label);
    // Visit the 'yes' part in the current state.
    __ bind(&yes_label);
    __ pop(1);
    visit(ir_yes);
    __ bind(&no_label);
  } else if (is_for_value() && ir_yes->is_Literal()) {
    // Produce the value of the if in case we
    // branch past the 'yes' block.
    visit_for_value(ir_yes);
    visit_for_control(ir_condition, &yes_label, &no_label, &no_label);
    // Visit the 'no' part in the current state.
    __ bind(&no_label);
    __ pop(1);
    visit(ir_no);
    __ bind(&yes_label);
  } else {

    visit_for_control(ir_condition, &yes_label, &no_label, &yes_label);

    // Visit the 'yes' part in the current state.
    __ bind(&yes_label);
    visit(ir_yes);

    if (is_for_value()) {
      __ branch(Emitter::UNCONDITIONAL, &done_label);
      emitter()->forget(1);
    } else if (ir_no->is_Nop() || ir_no->is_Literal()) {
      // We avoid emitting a branch at the end of the 'yes' part if we know that
      // the 'no' part will not generate any code.
      ASSERT(is_for_effect());
    } else {
      __ branch(Emitter::UNCONDITIONAL, &done_label);
    }

    __ bind(&no_label);
    visit(ir_no);

    __ bind(&done_label);
  }
}

void ByteGen::visit_Not(Not* node) {
  if (is_for_effect()) {
    visit_for_effect(node->value());
    return;
  }
  Label done, yes, no;
  visit_for_control(node->value(), &no, &yes, &yes);
  __ bind(&yes);
  __ load_true();
  __ branch(Emitter::UNCONDITIONAL, &done);
  emitter()->forget(1);
  __ bind(&no);
  __ load_false();
  __ bind(&done);
}

void ByteGen::visit_While(While* node) {
  ASSERT(is_for_effect());
  Label entry, loop;
  AbsoluteLabel done, update;

  __ bind(&entry);
  visit_for_control(node->condition(), &loop, &done, &loop);

  auto old_break = break_target_;
  auto old_continue = continue_target_;
  int old_loop_height = loop_height_;
  break_target_ = &done;
  continue_target_ = &update;
  loop_height_ = emitter()->height();

  // Visit body in current state.
  __ bind(&loop);
  visit(node->body());

  break_target_ = old_break;
  continue_target_ = old_continue;
  loop_height_ = old_loop_height;

  __ bind(&update);
  visit(node->update());
  __ branch(Emitter::UNCONDITIONAL, &entry);

  __ bind(&done);

  if (done.has_absolute_uses()) {
    emitter()->register_absolute_reference(done.build_absolute_reference());
  }
  if (update.has_absolute_uses()) {
    emitter()->register_absolute_reference(update.build_absolute_reference());
  }
}

void ByteGen::visit_LoopBranch(LoopBranch* node) {
  auto target = node->is_break() ? break_target_ : continue_target_;
  if (node->block_depth() > 0) {
    auto outer_emitter = _load_block_at_depth(node->block_depth());
    __ nl_branch(target, outer_emitter->height() - loop_height_);
    emitter()->remember(is_for_value() ? 1 : 0);
  } else {
    ASSERT(target != null);
    int extra = emitter()->height() - loop_height_;
    auto extra_types = emitter()->stack_types(extra);
    __ pop(extra);
    __ branch(Emitter::UNCONDITIONAL, target);
    emitter()->remember(extra_types);
    emitter()->remember(is_for_value() ? 1 : 0);
  }
}

void ByteGen::visit_LogicalBinary(LogicalBinary* node) {
  bool is_and = node->op() == LogicalBinary::AND;

  if (is_for_effect()) {
    Label done, maybe, yes, no;
    if (is_and) {
      visit_for_control(node->left(), &maybe, &done, &maybe);
    } else {
      visit_for_control(node->left(), &done, &maybe, &maybe);
    }
    __ bind(&maybe);
    visit_for_effect(node->right());
    __ bind(&done);
    return;
  }
  Label done, maybe, yes, no;
  visit_for_value(node->left());
  __ dup();
  Emitter::Condition condition = is_and ? Emitter::IF_FALSE : Emitter::IF_TRUE;
  __ branch(condition, &done);
  __ pop(1);
  visit_for_value(node->right());
  __ bind(&done);
  if (is_for_effect()) __ pop(1);
}

void ByteGen::visit_FieldLoad(FieldLoad* node) {
  int index = node->field()->resolved_index();
  if (index <= 0xff && is_declared_this(node->receiver())) {
    if (is_for_value()) __ load_field_this(index);
    return;
  }
  visit_for_value(node->receiver());
  __ load_field(index);
  if (is_for_effect()) {
    __ pop(1);
  }
}

void ByteGen::visit_FieldStore(FieldStore* node) {
  int index = node->field()->resolved_index();
  if (index <= 0xff && is_declared_this(node->receiver())) {
    visit_for_value(node->value());
    __ store_field_this(index);
    if (is_for_effect()) __ pop(1);
    return;
  }
  visit_for_value(node->receiver());
  visit_for_value(node->value());
  __ store_field(index);
  if (is_for_effect()) {
    __ pop(1);
  }
}

int ByteGen::register_string_literal(Symbol identifier) {
  return register_string_literal(identifier.c_str());
}

int ByteGen::register_string_literal(const char* str) {
  return register_string_literal(str, strlen(str));
}

int ByteGen::register_string_literal(const char* str, int length) {
  return program_builder()->add_string(str, length);
}

int ByteGen::register_byte_array_literal(List<uint8> data) {
  return program_builder()->add_byte_array(data);
}

int ByteGen::register_double_literal(double data) {
  return program_builder()->add_double(data);
}

int ByteGen::register_integer64_literal(int64 data) {
  return program_builder()->add_integer(data);
}

template<typename T, typename T2>
void ByteGen::_generate_call(Call* node,
                             const T& compile_target,
                             List<Expression*> arguments,
                             const T2& compile_invocation) {
  compile_target();

  for (auto argument : arguments) {
    visit_for_value(argument);
  }

  compile_invocation();

  if (node->range().is_valid()) {
    int bytecode_position = emitter()->position();
    method_mapper_.register_call(node, bytecode_position);
  }

  if (is_for_effect()) __ pop(1);
}

void ByteGen::visit_Super(Super* node) {
  if (node->expression() != null) {
    visit(node->expression());
  }
}

void ByteGen::visit_CallConstructor(CallConstructor* node) {
  int target_class_id = dispatch_table()->id_for(node->klass());

  auto compile_target = [&, this, target_class_id]() {
    __ allocate(target_class_id);
  };


  int target_index = dispatch_table()->slot_index_for(node->target()->target());
  List<Expression*> arguments = node->arguments();

  int arity = arguments.length() + 1;  // One more for the allocated instance.

  auto compile_invocation = [&]() {
    __ invoke_global(target_index, arity);
  };

  _generate_call(node, compile_target, arguments, compile_invocation);
}

void ByteGen::visit_CallStatic(CallStatic* node) {
  List<Expression*> arguments = node->arguments();
  int arity = arguments.length();

  auto compile_target = [&]() {
    // Do nothing.
  };

  int target_index = dispatch_table()->slot_index_for(node->target()->target());

  auto compile_invocation = [&, this, target_index, arity]() {
    __ invoke_global(target_index, arity, node->is_tail_call());
  };

  _generate_call(node, compile_target, arguments, compile_invocation);
}

void ByteGen::visit_Lambda(Lambda* node) {
  visit_CallStatic(node);
}

void ByteGen::visit_CallVirtual(CallVirtual* node) {
  auto compile_target = [&, this, node]() {
    visit_for_value(node->target()->receiver());
  };

  List<Expression*> arguments = node->arguments();
  CallShape shape = node->shape();
  int arity = shape.arity();

  auto compile_invocation = [&]() {
    auto target_selector = node->target()->selector();
    Selector<PlainShape> selector(target_selector, shape.to_plain_shape());
    int offset = dispatch_table()->dispatch_offset_for(selector);
    if (offset != -1) {
      __ invoke_virtual(node->opcode(), offset, arity);
    } else {
      // No method in the whole program implements that selector. This
      // can happen for the equality operator too, if the call cannot be
      // reached because no instances of the possible receivers are ever
      // allocated. If it could be reached, even with null as the receiver,
      // there would be a method for it.
      // Pop all arguments, and push the name of the method on the stack.
      // Then call `lookup_failure`.

      // Note that we don't need to pop the pushed block methods, as this will
      // happen unconditionally in [generate_call].

      __ pop(arity - 1);  // Keep the receiver since we need this as argument lookup_failure_.

      int target_index = dispatch_table()->slot_index_for(lookup_failure_);
      if (shape.is_setter()) {
        std::string name(selector.name().c_str());
        name += "=";
        __ load_literal(register_string_literal(name.c_str()));
      } else {
        __ load_literal(register_string_literal(selector.name().c_str()));
      }
      __ invoke_global(target_index, 2);
    }
  };

  _generate_call(node, compile_target, arguments, compile_invocation);
}

void ByteGen::visit_CallBlock(CallBlock* node) {
  auto compile_target = [&, this, node]() {
    visit_for_value(node->target());
  };

  List<Expression*> arguments = node->arguments();
  int arity = node->shape().arity();

  auto compile_invocation = [&, this, arity]() {
    __ invoke_block(arity);
  };

  _generate_call(node, compile_target, arguments, compile_invocation);
}

void ByteGen::visit_Builtin(Builtin* node) {
  UNREACHABLE();
}

void ByteGen::visit_CallBuiltin(CallBuiltin* node) {
  switch(node->target()->kind()) {
    case Builtin::THROW:
      visit_for_value(node->arguments()[0]);
      __ _throw();
      if (is_for_effect()) emitter()->forget(1);
      break;

    case Builtin::INVOKE_LAMBDA: {
        ASSERT(node->arguments().length() == 1 &&
               node->arguments()[0]->is_LiteralInteger());
        int64 val = node->arguments()[0]->as_LiteralInteger()->value();
        ASSERT(Smi::is_valid(val));
        __ invoke_lambda_tail(val, max_captured_count_);
        if (is_for_value()) emitter()->remember(1);
      }
      break;

    case Builtin::YIELD:
      __ halt(0);
      if (is_for_effect()) __ pop(1);
      break;

    case Builtin::RESET:
      __ halt(3);
      break;

    case Builtin::EXIT:
      visit_for_value(node->arguments()[0]);
      __ halt(1);
      if (is_for_effect()) emitter()->forget(1);
      break;

    case Builtin::DEEP_SLEEP:
      visit_for_value(node->arguments()[0]);
      __ halt(2);
      if (is_for_effect()) emitter()->forget(1);
      break;

    case Builtin::STORE_GLOBAL:
      visit_for_value(node->arguments()[0]);
      visit_for_value(node->arguments()[1]);
      __ store_global_var_dynamic();
      break;

    case Builtin::LOAD_GLOBAL:
      visit_for_value(node->arguments()[0]);
      __ load_global_var_dynamic();
      break;

    case Builtin::INVOKE_INITIALIZER:
      visit_for_value(node->arguments()[0]);
      __ invoke_initializer_tail();
      if (is_for_value()) emitter()->remember(1);
      break;

    case Builtin::GLOBAL_ID: {
      ASSERT(node->arguments()[0]->is_ReferenceGlobal());
      auto global = node->arguments()[0]->as_ReferenceGlobal()->target();
      __ load_integer(global->global_id());
      break;
    }

    case Builtin::IDENTICAL:
      if (is_for_effect()) {
        visit_for_effect(node->arguments()[0]);
        visit_for_effect(node->arguments()[1]);
      } else {
        visit_for_value(node->arguments()[0]);
        visit_for_value(node->arguments()[1]);
        __ identical();
      }
      break;
  }
}

void ByteGen::visit_Typecheck(Typecheck* node) {
  if (node->type().is_any()) {
    // We will not hit this part of the code generation when we're
    // optimizing and that is important, because we will not be
    // registering any 'as' or 'is' check bytecodes, so we risk
    // concluding that the check was never executed and therefore
    // always throws. Hmm.
    if (node->is_as_check()) {
      visit(node->expression());
    } else if (is_for_value()) {
      visit_for_effect(node->expression());
      __ load_true();
    }
    return;
  }

  bool is_interface_check = node->is_interface_check();
  int typecheck_index = (*typecheck_indexes_)[node->type().klass()];
  bool is_nullable = node->type().is_nullable();
  bool is_as_check = node->is_as_check();

  if (is_for_effect() &&
      !is_interface_check &&
      !is_nullable &&
      is_as_check &&
      node->expression()->is_ReferenceLocal() &&
      node->expression()->as_ReferenceLocal()->block_depth() == 0) {
    auto target = node->expression()->as_ReferenceLocal()->target();
    int bytecode_position;
    if (target->is_Parameter()) {
      bytecode_position = __ typecheck_parameter(target->as_Parameter()->index(), typecheck_index);
    } else {
      int height = local_height(target->as_Local()->index());
      bytecode_position = __ typecheck_local(height, typecheck_index);
    }
    method_mapper_.register_as_check(node, bytecode_position);
    return;
  }

  visit_for_value(node->expression());
  Opcode opcode;
  if (is_interface_check) {
    opcode = is_as_check ? AS_INTERFACE : IS_INTERFACE;
  } else {
    opcode = is_as_check ? AS_CLASS : IS_CLASS;
  }
  __ typecheck(opcode, typecheck_index, is_nullable);

  if (is_as_check) {
    int bytecode_position = emitter()->position();
    method_mapper_.register_as_check(node, bytecode_position);
  }
  if (is_for_effect()) __ pop(1);
}

void ByteGen::visit_Return(Return* node) {
  if (node->depth() == -1) {
    if (!outer_emitters_stack_.empty()) {
      visit_for_value(node->value());
      Emitter* outer = _load_block_at_depth(outer_emitters_stack_.size());
      __ nlr(outer->height() - 1, outer->arity());
    } else if (node->value()->is_LiteralNull()) {
      __ ret_null();
      emitter()->remember(1);
    } else {
      visit_for_value(node->value());
      if (node->value()->is_CallStatic() &&
          node->value()->as_Call()->is_tail_call()) {
        // Don't do anything. The call will return for us.
        ASSERT(emitter()->previous_opcode() == INVOKE_STATIC_TAIL);
      } else {
        __ ret();
      }
    }
  } else if (node->depth() == 0) {
    if (node->value()->is_LiteralNull()) {
      __ ret_null();
      emitter()->remember(1);
    } else {
      visit_for_value(node->value());
      __ ret();
    }
  } else {
    visit_for_value(node->value());
    Emitter* outer = _load_block_at_depth(node->depth());
    __ nlr(outer->height() - 1, outer->arity());
  }

  // TODO(florian): we shouldn't be generating code that relies on the stack
  // height after return.  (Old comment from Kasper that still needs to be
  // investigated).
  if (is_for_effect()) emitter()->forget(1);
}


void ByteGen::visit_LiteralNull(LiteralNull* node) {
  if (is_for_value()) {
    __ load_null();
  }
}

void ByteGen::visit_LiteralUndefined(LiteralUndefined* node) {
  if (is_for_value()) {
    __ load_null();
  }
}

void ByteGen::visit_LiteralInteger(LiteralInteger* node) {
  if (is_for_value()) {
    int64 value = node->value();
    if (Smi::is_valid32(value) && value >= 0) __ load_integer(value);
    else  __ load_literal(register_integer64_literal(value));
  }
}

void ByteGen::visit_LiteralFloat(LiteralFloat* node) {
  if (is_for_value()) {
    __ load_literal(register_double_literal(node->value()));
  }
}

void ByteGen::visit_LiteralString(LiteralString* node) {
  if (is_for_value()) {
    const char* value = node->value();
    int length = node->length();
    __ load_literal(register_string_literal(value, length));
  }
}

void ByteGen::visit_LiteralByteArray(LiteralByteArray* node) {
  if (is_for_value()) {
    __ load_literal(register_byte_array_literal(node->data()));
  }
}

void ByteGen::visit_LiteralBoolean(LiteralBoolean* node) {
  if (is_for_effect()) return;
  if (node->value()) {
    __ load_true();
  } else {
    __ load_false();
  }
}

Emitter* ByteGen::_load_block_at_depth(int block_depth) {
  ASSERT(block_depth > 0);
  int stack_size = outer_emitters_stack_.size();
  __ load_parameter(0, ExpressionStack::BLOCK);
  for (int i = 1; i < block_depth; i++) {
    __ load_outer_parameter(0, ExpressionStack::BLOCK, outer_emitters_stack_[stack_size - i]);
  }
  return outer_emitters_stack_[stack_size - block_depth];
}

void ByteGen::visit_ReferenceLocal(ReferenceLocal* node) {
  if (is_for_effect()) return;

  if (node->block_depth() == 0) {
    if (node->target()->is_Parameter()) {
      Parameter* parameter = node->target()->as_Parameter();
      auto type = parameter->is_block() ? ExpressionStack::BLOCK : ExpressionStack::OBJECT;
      __ load_parameter(parameter->index(), type);
    } else if (node->target()->is_Local()) {
      Local* local = node->target()->as_Local();
      __ load_local(local_height(local->index()));
    }
  } else {
    auto outer = _load_block_at_depth(node->block_depth());
    if (node->target()->is_Parameter()) {
      Parameter* parameter = node->target()->as_Parameter();
      auto type = parameter->is_block() ? ExpressionStack::BLOCK : ExpressionStack::OBJECT;
      __ load_outer_parameter(node->target()->index(), type, outer);
    } else {
      __ load_outer_local(local_height(node->target()->index()), outer);
    }
  }
}

void ByteGen::visit_ReferenceBlock(ReferenceBlock* node) {
  if (is_for_effect()) return;
  if (node->block_depth() == 0) {
    __ load_block(local_height(node->target()->index()));
  } else {
    auto outer = _load_block_at_depth(node->block_depth());
    __ load_outer_block(local_height(node->target()->index()), outer);
  }
}

void ByteGen::visit_ReferenceGlobal(ReferenceGlobal* node) {
  bool is_lazy = node->is_lazy() && node->target()->is_lazy();
  if (!is_lazy && is_for_effect()) return;

  __ load_global_var(node->target()->global_id(), is_lazy);
  int bytecode_position = emitter()->position();
  method_mapper_.register_call(node, bytecode_position);

  if (is_for_effect()) __ pop(1);
}

void ByteGen::visit_AssignmentLocal(AssignmentLocal* node) {
  int block_depth = node->block_depth();
  auto local = node->local();
  if (block_depth == 0) {
    visit_for_value(node->right());
    if (local->is_Parameter()) {
      __ store_parameter(local->as_Parameter()->index());
    } else {
      __ store_local(local_height(local->index()));
    }
  } else {
    auto outer = _load_block_at_depth(block_depth);
    visit_for_value(node->right());
    if (local->is_Parameter()) {
      __ store_outer_parameter(local->as_Parameter()->index(), outer);
    } else {
      __ store_outer_local(local_height(local->index()), outer);
    }
  }
  if (is_for_effect()) __ pop(1);
}

void ByteGen::visit_AssignmentGlobal(AssignmentGlobal* node) {
  visit_for_value(node->right());
  __ store_global_var(node->global()->global_id());
  if (is_for_effect()) __ pop(1);
}

void ByteGen::visit_AssignmentDefine(AssignmentDefine* node) {
  auto target = node->left();
  if (target->is_Local()) {
    Local* local = target->as_Local();
    ASSERT(local->index() == -1);
    // TODO(florian): we should know the index of locals at this point.
    local->set_index(register_local());
  } else {
    UNIMPLEMENTED();
  }
  visit_for_value(node->right());
  if (is_for_value()) __ dup();
}

void ByteGen::visit_PrimitiveInvocation(PrimitiveInvocation* node) {
  int module = node->module_index();
  ASSERT(module >= 0);
  int index = node->primitive_index();
  ASSERT(index >= 0);

  if (emitter()->height() != 0) {
    FATAL("Primitive calls must be on empty stack");
  }

  if (node->module() == Symbols::intrinsics && is_format2()) {
    generate_intrinsic_v2(node);
  } else if (node->module() == Symbols::intrinsics) {
    if (node->primitive() == Symbols::smi_repeat) {
      __ load_integer(0);  // Start index.
      // The intrinsic always discards the top value (result of last block execution), so
      // we pass a dummy value on the stack.
      __ load_integer(0);
      __ intrinsic_smi_repeat();
    } else if (node->primitive() == Symbols::array_do) {
      __ load_integer(0);  // Start index.
      // The intrinsic always discards the top value (result of last block execution), so
      // we pass a dummy value on the stack.
      __ load_integer(0);
      __ intrinsic_array_do();
    } else if (node->primitive() == Symbols::hash_find) {
      // Push the 7 state variables (see find_body_ in collections.toit and the
      // HASH_FIND bytecode.
        // state.
        // old_size.
        // deleted_slot.
        // slot.
        // position.
        // slot_step.
        // starting_slot.
      // The intrinsic always expects the top value to be the result of the
      // last block execution, so we pass a dummy value for the first time.
      __ load_n_smis(8);
      __ intrinsic_hash_find();
    } else if (node->primitive() == Symbols::hash_do) {
      __ load_null();  // Start index - beginning or end depending on the reversed argument.
      // The intrinsic always discards the top value (result of last block execution), so
      // we pass a dummy value on the stack.
      __ load_integer(0);
      __ intrinsic_hash_do();
    } else {
      UNREACHABLE();
    }
  } else {
    __ primitive(module, index);
  }

  if (is_for_effect()) __ pop(1);
}

// Proposal (verified/spec/format/19-builtins-proposal.md): the body of
// `find-body_ key hash append-position [not-found] [rebuild] [compare]`
// (lib/core/collections.toit) on the HASH_FIND instruction, which walks the
// index; the Toit code of that method follows as the failure block and runs
// only when HASH_FIND reports an irregular state. This is the same loop:
//
//   while true:                                   // restart
//     slot, step, deleted := (start), 0, none
//     while true:                                 // probe
//       HASH_FIND
//         candidate k at position: if compare.call key k:
//                                    return append-position ? APPEND_ : position
//                                  else continue probing
//         free slot (or the first deleted one): enter the key as Toit does
//         full: old-size := size_; ensure append-position; rebuild.call old-size;
//               restart
//         irregular: fall into the Toit loop
//
// "ensure append-position" is `if not append-position: append-position =
// not-found.call`. Leaves nothing on the stack when it falls through.
void ByteGen::generate_hash_find_v2() {
  ASSERT(emitter()->height() == 0);
  ASSERT(emitter()->arity() == 7);
  const int THIS = 0, KEY = 1, HASH = 2, APPEND = 3, NOT_FOUND = 4, REBUILD = 5, COMPARE = 6;
  // Fields of HashedInsertionOrderedCollection_ (also Instance::MAP_*).
  const int SIZE = 0, SPACES_LEFT = 1, INDEX = 2;
  const int HASH_SHIFT = 12, HASH_MASK = 0xfff;
  bool declared = receiver_range(method_).is_valid();
  auto load_this_field = [&](int field) {
    if (declared) {
      __ load_field_this(field);
    } else {
      __ load_parameter(THIS, ExpressionStack::OBJECT);
      __ load_field(field);
    }
  };
  auto ensure_append = [&]() {
    Label have;
    __ load_parameter(APPEND, ExpressionStack::OBJECT);
    __ branch(Emitter::IF_TRUE, &have);
    __ load_parameter(NOT_FOUND, ExpressionStack::BLOCK);
    __ invoke_block(1);
    __ store_parameter(APPEND);
    __ pop(1);
    __ bind(&have);
  };
  int minus_one = register_integer64_literal(-1);  // APPEND_.
  auto return_append = [&]() {
    __ load_literal(minus_one);
    __ ret();
    __ forget(1);
  };
  Label restart, probe, miss, nomatch, ret_append, empty, rebuild_old, fallback, fresh_done;
  // The probe state, locals 0..2: deleted slot + 1, step (0: start), slot.
  __ bind(&restart);
  __ load_integer(0);
  __ load_integer(0);
  __ load_integer(0);
  __ bind(&probe);
  // Slot is local 2 (top 0), the hash parameter 2 is at top 7, this at 9.
  __ hash_find(&miss, 0, 7);
  // Candidate: [deleted, step, slot, k, position].
  __ load_parameter(COMPARE, ExpressionStack::BLOCK);
  __ load_parameter(KEY, ExpressionStack::OBJECT);
  __ load_local(3);
  __ invoke_block(3);
  __ branch(Emitter::IF_FALSE, &nomatch);
  __ load_parameter(APPEND, ExpressionStack::OBJECT);
  __ branch(Emitter::IF_TRUE, &ret_append);
  __ ret();  // The position.
  __ bind(&ret_append);
  return_append();
  __ bind(&nomatch);
  __ pop(2);
  __ branch(Emitter::UNCONDITIONAL, &probe);
  // Miss: [deleted, step, slot, code].
  __ remember(1);
  __ bind(&miss);
  __ load_local(3);
  __ load_integer(0);
  __ invoke_virtual(INVOKE_GTE, 0, 2);
  __ branch(Emitter::IF_TRUE, &empty);
  __ load_local(3);
  __ load_literal(minus_one);
  __ invoke_virtual(INVOKE_LT, 0, 2);
  __ branch(Emitter::IF_TRUE, &fallback);
  // Full: [deleted, step, slot, code, old-size].
  load_this_field(SIZE);
  ensure_append();
  __ load_parameter(REBUILD, ExpressionStack::BLOCK);
  __ load_local(4);
  __ invoke_block(2);
  __ pop(6);
  __ branch(Emitter::UNCONDITIONAL, &restart);
  // A free slot (code = 2 * slot + 1) or the first deleted one (2 * slot).
  __ remember(4);
  __ bind(&empty);
  load_this_field(SIZE);  // old-size.
  ensure_append();
  load_this_field(SPACES_LEFT);
  __ load_integer(0);
  __ invoke_virtual(INVOKE_EQ, 0, 2);
  __ branch(Emitter::IF_TRUE, &rebuild_old);
  // index_[code >> 1] = ((append-position + 1) << HASH_SHIFT) | (hash & HASH_MASK)
  load_this_field(INDEX);
  __ load_local(3);
  __ load_integer(1);
  __ invoke_virtual(INVOKE_BIT_SHR, 0, 2);
  __ load_parameter(APPEND, ExpressionStack::OBJECT);
  __ load_integer(1);
  __ invoke_virtual(INVOKE_ADD, 0, 2);
  __ load_integer(HASH_SHIFT);
  __ invoke_virtual(INVOKE_BIT_SHL, 0, 2);
  __ load_parameter(HASH, ExpressionStack::OBJECT);
  __ load_integer(HASH_MASK);
  __ invoke_virtual(INVOKE_BIT_AND, 0, 2);
  __ invoke_virtual(INVOKE_BIT_OR, 0, 2);
  __ invoke_virtual(INVOKE_AT_PUT, 0, 3);
  __ pop(1);
  // A free slot: index-spaces-left_--.
  __ load_local(3);
  __ load_integer(1);
  __ invoke_virtual(INVOKE_BIT_AND, 0, 2);
  __ load_integer(0);
  __ invoke_virtual(INVOKE_EQ, 0, 2);
  __ branch(Emitter::IF_TRUE, &fresh_done);
  if (declared) {
    load_this_field(SPACES_LEFT);
    __ load_integer(1);
    __ invoke_virtual(INVOKE_SUB, 0, 2);
    __ store_field_this(SPACES_LEFT);
  } else {
    __ load_parameter(THIS, ExpressionStack::OBJECT);
    load_this_field(SPACES_LEFT);
    __ load_integer(1);
    __ invoke_virtual(INVOKE_SUB, 0, 2);
    __ store_field(SPACES_LEFT);
  }
  __ pop(1);
  __ bind(&fresh_done);
  return_append();
  // No space left: [deleted, step, slot, code, old-size].
  __ bind(&rebuild_old);
  __ load_parameter(REBUILD, ExpressionStack::BLOCK);
  __ load_local(4);
  __ invoke_block(2);
  __ pop(6);
  __ branch(Emitter::UNCONDITIONAL, &restart);
  // Irregular: [deleted, step, slot, code]; the Toit loop follows.
  __ remember(4);
  __ bind(&fallback);
  __ pop(4);
}

void ByteGen::generate_intrinsic_v2(PrimitiveInvocation* node) {
  ASSERT(emitter()->height() == 0);
  // Format 2 has no intrinsic instructions. `smi-repeat` and `array-do`
  // become loops in bytecode; the hash-collection intrinsics fall back to
  // the Toit implementation in their failure block, which receives null.
  bool is_repeat = node->primitive() == Symbols::smi_repeat;
  bool is_do = node->primitive() == Symbols::array_do;
  if (!is_repeat && !is_do) {
    ASSERT(node->primitive() == Symbols::hash_find || node->primitive() == Symbols::hash_do);
    if (node->primitive() == Symbols::hash_find && v2_builtin_enabled(V2_BUILTIN_HASH_FIND)) {
      generate_hash_find_v2();
    }
    __ load_null();
    return;
  }
  // repeat [block]: this is the count, the block is parameter 1.
  // do_ end [block]: this is the backing array, the end parameter 1 and
  //   the block parameter 2. The block receives the element.
  int end_parameter = is_repeat ? 0 : 1;
  int block_parameter = is_repeat ? 1 : 2;
  Label loop, done;
  __ load_integer(0);  // The index, local 0.
  bool fast = is_repeat
      ? v2_builtin_enabled(V2_BUILTIN_REPEAT)
      : v2_builtin_enabled(V2_BUILTIN_ARRAY_DO);
  if (fast) {
    // Proposal (format note 19): the fast loop with the LOOP_REPEAT or
    // LOOP_ARRAY step. The frame is [this, block | i, result] (repeat) or
    // [this, end, block | i, result] (do_): the step's counter is slot 1,
    // the block slot 2, the limit or end slot 3, the array (this) slot 4.
    // The step pops the previous result and either branches back to the
    // INVOKE_BLOCK with the block and the index (repeat) or element (do_)
    // pushed, or falls through to the ordinary loop below, which re-checks
    // everything (and returns at once when the end is reached).
    Label body, test;
    __ load_null();  // The "previous block result" of the first step.
    __ branch(Emitter::UNCONDITIONAL, &test);
    __ forget(1);
    __ remember(1, ExpressionStack::BLOCK);
    __ remember(1);
    __ bind(&body);
    // A block that takes no argument ignores the extra one.
    __ invoke_block(2);
    __ bind(&test);
    __ loop_step(is_repeat ? V2_LOOP_REPEAT : V2_LOOP_ARRAY, &body, 1);
  }
  __ bind(&loop);
  __ load_local(0);
  __ load_parameter(end_parameter, ExpressionStack::OBJECT);
  __ invoke_virtual(INVOKE_LT, 0, 2);
  __ branch(Emitter::IF_FALSE, &done);
  __ load_parameter(block_parameter, ExpressionStack::BLOCK);
  if (is_repeat) {
    __ load_local(0);
  } else {
    __ load_parameter(0, ExpressionStack::OBJECT);
    __ load_local(0);
    __ invoke_virtual(INVOKE_AT, 0, 2);
  }
  // A block that takes no argument ignores the extra one.
  __ invoke_block(2);
  __ pop(1);
  __ load_local(0);
  __ load_integer(1);
  __ invoke_virtual(INVOKE_ADD, 0, 2);
  __ store_local(0);
  __ pop(1);
  __ branch(Emitter::UNCONDITIONAL, &loop);
  __ bind(&done);
  __ ret_null();
  // The failure block that follows is unreachable; it starts with the index
  // in the place of the failure value.
}

} // namespace toit::compiler
} // namespace toit
