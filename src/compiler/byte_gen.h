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

#include <vector>

#include "dispatch_table.h"
#include "emitter.h"
#include "ir.h"
#include "list.h"
#include "source_mapper.h"

namespace toit {
namespace compiler {

class ProgramBuilder;

class ByteGen : private ir::Visitor {
 public:
  ByteGen(ir::Method* lookup_failure,
          int max_captured_count,
          DispatchTable* dispatch_table,
          UnorderedMap<ir::Class*, int>* typecheck_indexes,
          SourceMapper* source_mapper,
          ProgramBuilder* program_builder)
      : lookup_failure_(lookup_failure)
      , max_captured_count_(max_captured_count)
      , dispatch_table_(dispatch_table)
      , typecheck_indexes_(typecheck_indexes)
      , source_mapper_(source_mapper)
      , program_builder_(program_builder)
      , method_(null)
      , method_mapper_(SourceMapper::MethodMapper::invalid())
      , emitter_(null)
      , local_heights_()
      , locals_count_(0)
      , break_target_(null)
      , continue_target_(null)
      , loop_height_(-1)
      , is_for_value_(false) {}

  int assemble_global(ir::Global* global);
  int assemble_method(ir::Method* method,
                      int dispatch_offset,
                      bool is_field_accessor);

 private:
  int assemble_function(ir::Method* function,
                        int dispatch_offset,
                        bool is_field_accessor,
                        SourceMapper::MethodMapper method_mapper);

  int _assemble_block(ir::Code* node);
  int _assemble_lambda(ir::Code* node);
  int _assemble_nested_function(ir::Node* body,
                                int arity,
                                bool is_block,
                                int captured_count,   // Only used if it is a lambda.
                                bool body_has_explicit_return,
                                bool should_push_old_emitter,
                                SourceMapper::MethodMapper method_mapper);

  void update_absolute_positions(int absolute_entry_bci,
                                 const List<AbsoluteUse*>& uses,
                                 const List<AbsoluteReference>& references);

 private:
  ir::Method* const lookup_failure_;
  int const max_captured_count_;
  DispatchTable* const dispatch_table_;
  UnorderedMap<ir::Class*, int>* const typecheck_indexes_;
  SourceMapper* const source_mapper_;
  ProgramBuilder* const program_builder_;

  // Updated only at the outermost method/global.
  // This means that nested blocks/lambdas share the same `method_`.
  ir::Method* method_;

  // Updated for outermost method/global *and* nested blocks/lambdas.
  SourceMapper::MethodMapper method_mapper_;
  Emitter* emitter_;
  std::vector<Emitter*> outer_emitters_stack_;

  // The height of every local.
  int local_heights_[128];
  // The number of locals that have been registered so far.
  int locals_count_;

  AbsoluteLabel* break_target_;
  AbsoluteLabel* continue_target_;
  int loop_height_;

  bool is_for_value_;

  Emitter* emitter() const { return emitter_; }
  DispatchTable* dispatch_table() { return dispatch_table_; }
  SourceMapper::MethodMapper method_mapper() const { return method_mapper_; }
  ProgramBuilder* program_builder() const { return program_builder_; }

  int register_local() {
    return register_local(emitter()->height());
  }

  int register_local(int height) {
    local_heights_[locals_count_] = height;
    return locals_count_++;
  }

  int local_height(int index) {
    ASSERT(0 <= index && index < locals_count_);
    return local_heights_[index];
  }

  int register_string_literal(Symbol identifier);
  int register_string_literal(const char* str);
  int register_string_literal(const char* str, int length);
  int register_byte_array_literal(List<uint8> data);
  int register_double_literal(double data);
  int register_integer64_literal(int64 data);

  bool is_for_value() const { return is_for_value_; }
  bool is_for_effect() const { return !is_for_value_; }

  void visit(ir::Node* node);
  void visit_for_value(ir::Node* node);
  void visit_for_effect(ir::Node* node);
  void visit_for_control(ir::Expression* condition, Label* yes, Label* no, Label* fallthrough);

  void visit_Builtin(ir::Builtin* node);
  void visit_Global(ir::Global* node);
  void visit_Class(ir::Class* node);
  void visit_Field(ir::Field* node);
  void _generate_method(ir::Method* node);
  void visit_MethodInstance(ir::MethodInstance* node);
  void visit_MonitorMethod(ir::MonitorMethod* node);
  void visit_MethodStatic(ir::MethodStatic* node);
  void visit_Constructor(ir::Constructor* node);
  void visit_AdapterStub(ir::AdapterStub* node);
  void visit_IsInterfaceStub(ir::IsInterfaceStub* node);
  void visit_FieldStub(ir::FieldStub* node);
  void visit_Code(ir::Code* node);
  void visit_Nop(ir::Nop* node);
  void visit_Sequence(ir::Sequence* node);
  void visit_TryFinally(ir::TryFinally* node);
  void visit_If(ir::If* node);
  void visit_Not(ir::Not* node);
  void visit_While(ir::While* node);
  void visit_LoopBranch(ir::LoopBranch* node);
  void visit_LogicalBinary(ir::LogicalBinary* node);
  void visit_FieldLoad(ir::FieldLoad* node);
  void visit_FieldStore(ir::FieldStore* node);
  template<typename T, typename T2>
  void _generate_call(ir::Call* node,
                      const T& compile_target,
                      List<ir::Expression*> arguments,
                      const T2& compile_invocation);
  void visit_Super(ir::Super* node);
  void visit_CallConstructor(ir::CallConstructor* node);
  void visit_CallStatic(ir::CallStatic* node);
  void visit_Lambda(ir::Lambda* node);
  void visit_CallVirtual(ir::CallVirtual* node);
  void visit_CallBlock(ir::CallBlock* node);
  void visit_CallBuiltin(ir::CallBuiltin* node);
  void visit_AssignmentLocal(ir::AssignmentLocal* node);
  void visit_AssignmentGlobal(ir::AssignmentGlobal* node);
  void visit_AssignmentDefine(ir::AssignmentDefine* node);
  Emitter* _load_block_at_depth(int depth);
  void visit_ReferenceLocal(ir::ReferenceLocal* node);
  void visit_ReferenceBlock(ir::ReferenceBlock* node);
  void visit_ReferenceGlobal(ir::ReferenceGlobal* node);
  void visit_Typecheck(ir::Typecheck* node);
  void visit_Return(ir::Return* node);
  void visit_LiteralNull(ir::LiteralNull* node);
  void visit_LiteralUndefined(ir::LiteralUndefined* node);
  void visit_LiteralInteger(ir::LiteralInteger* node);
  void visit_LiteralFloat(ir::LiteralFloat* node);
  void visit_LiteralString(ir::LiteralString* node);
  void visit_LiteralByteArray(ir::LiteralByteArray* node);
  void visit_LiteralBoolean(ir::LiteralBoolean* node);
  void visit_PrimitiveInvocation(ir::PrimitiveInvocation* node);

  void visit_Program(ir::Program* node) { UNREACHABLE(); }
  void visit_Method(ir::Method* node) { UNREACHABLE(); }
  void visit_Expression(ir::Expression* node) { UNREACHABLE(); }
  void visit_Error(ir::Error* node) { UNREACHABLE(); }
  void visit_Call(ir::Call* node) { UNREACHABLE(); }
  void visit_Assignment(ir::Assignment* node) { UNREACHABLE(); }
  void visit_Reference(ir::Reference* node) { UNREACHABLE(); }
  void visit_ReferenceClass(ir::ReferenceClass* node) { UNREACHABLE(); }
  void visit_ReferenceMethod(ir::ReferenceMethod* node) { UNREACHABLE(); }
  void visit_Local(ir::Local* node) { UNREACHABLE(); }
  void visit_Parameter(ir::Parameter* node) { UNREACHABLE(); }
  void visit_CapturedLocal(ir::CapturedLocal* node) { UNREACHABLE(); }
  void visit_Block(ir::Block* node) { UNREACHABLE(); }
  void visit_Literal(ir::Literal* node) { UNREACHABLE(); }
  void visit_Dot(ir::Dot* node) { UNREACHABLE(); }
  void visit_LspSelectionDot(ir::LspSelectionDot* node) { UNREACHABLE(); }
};

} // namespace toit::compiler
} // namespace toit

