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
          ir::Method* as_check_failure,
          int max_captured_count,
          DispatchTable* dispatch_table,
          UnorderedMap<ir::Class*, int>* typecheck_indexes,
          SourceMapper* source_mapper,
          ProgramBuilder* program_builder)
      : _lookup_failure(lookup_failure)
      , _as_check_failure(as_check_failure)
      , _max_captured_count(max_captured_count)
      , _dispatch_table(dispatch_table)
      , _typecheck_indexes(typecheck_indexes)
      , _source_mapper(source_mapper)
      , _program_builder(program_builder)
      , _method(null)
      , _method_mapper(SourceMapper::MethodMapper::invalid())
      , _emitter(null)
      , _local_heights()
      , _locals_count(0)
      , _break_target(null)
      , _continue_target(null)
      , _loop_height(-1)
      , _is_for_value(false) { }

  int assemble_global(ir::Global* global);
  int assemble_method(ir::Method* method,
                      int dispatch_offset,
                      bool is_field_accessor);

  bool is_eager_global(ir::Global* global);

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
  ir::Method* const _lookup_failure;
  ir::Method* const _as_check_failure;
  int const _max_captured_count;
  DispatchTable* const _dispatch_table;
  UnorderedMap<ir::Class*, int>* const _typecheck_indexes;
  SourceMapper* const _source_mapper;
  ProgramBuilder* const _program_builder;

  // Updated only at the outermost method/global.
  // This means that nested blocks/lambdas share the same `_method`.
  ir::Method* _method;

  // Updated for outermost method/global *and* nested blocks/lambdas.
  SourceMapper::MethodMapper _method_mapper;
  Emitter* _emitter;
  std::vector<Emitter*> _outer_emitters_stack;

  // The height of every local.
  int _local_heights[128];
  // The number of locals that have been registered so far.
  int _locals_count;

  AbsoluteLabel* _break_target;
  AbsoluteLabel* _continue_target;
  int _loop_height;

  bool _is_for_value;

  Emitter* emitter() const { return _emitter; }
  DispatchTable* dispatch_table() { return _dispatch_table; }
  SourceMapper::MethodMapper method_mapper() const { return _method_mapper; }
  ProgramBuilder* program_builder() const { return _program_builder; }

  int register_local() {
    return register_local(emitter()->height());
  }

  int register_local(int height) {
    _local_heights[_locals_count] = height;
    return _locals_count++;
  }

  int local_height(int index) {
    ASSERT(0 <= index && index < _locals_count);
    return _local_heights[index];
  }

  int register_string_literal(Symbol identifier);
  int register_string_literal(const char* str);
  int register_string_literal(const char* str, int length);
  int register_byte_array_literal(List<uint8> data);
  int register_double_literal(double data);
  int register_integer64_literal(int64 data);

  bool is_for_value() const { return _is_for_value; }
  bool is_for_effect() const { return !_is_for_value; }

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

