// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/compiler/ir.h"
#include "../../src/compiler/lowering.h"
#include "../../src/compiler/resolution.h"

namespace toit {
namespace compiler {

static void check(bool condition) {
  if (!condition) FATAL("Compiler lowering test failed");
}

static void test() {
  AllowThrowingNew allow;
  Zone zone;
  auto range = Source::Range(Source::Position::from_token(0));
  auto name = Symbol::synthetic("test");
  auto klass = resolution::make<resolution::ClassInfo>(name, resolution::ClassInfo::CLASS, false, range, range);
  auto type = resolution::Type(klass).to_nullable();
  auto method = resolution::make<resolution::MethodStaticInfo>(name, klass, ResolutionShape(0),
      resolution::MethodInfo::GLOBAL_FUN, range, range);
  method->set_return_type(type);
  auto global = resolution::make<resolution::GlobalInfo>(name, true, range, range);
  global->set_explicit_return_type(type);
  // Both a method cycle and a global cycle must preserve declaration identities.
  auto self = resolution::make<resolution::ReferenceMethodInfo>(method, range);
  auto recursive_call = resolution::make<resolution::CallStaticInfo>(self, CallShape(0),
      List<resolution::ExpressionView>(), range);
  global->set_body(resolution::make<resolution::ReferenceGlobalInfo>(global, true, range));

  auto local = resolution::make<resolution::LocalInfo>(name, false, false, range);
  local->set_type(type);  // Inferred, not explicit.
  local->mark_guaranteed_inferred_type();
  local->mark_captured();
  auto captured = resolution::make<resolution::CapturedLocalInfo>(local, 0, range);
  auto code = resolution::make<resolution::CodeInfo>(name,
      ListBuilder<resolution::ParameterView>::build(captured),
      resolution::make<resolution::ReferenceLocalInfo>(captured, 0, range), false, range);
  code->set_captured_count(1);
  auto define = resolution::make<resolution::AssignmentDefineInfo>(local,
      resolution::make<resolution::LiteralNullInfo>(range), range);
  ListBuilder<resolution::ExpressionView> expressions;
  expressions.add(define);
  expressions.add(code);
  expressions.add(recursive_call);
  const Token::Kind comparisons[] = { Token::EQ, Token::LT, Token::LTE, Token::GT, Token::GTE };
  const Opcode opcodes[] = { INVOKE_EQ, INVOKE_LT, INVOKE_LTE, INVOKE_GT, INVOKE_GTE };
  auto receiver = resolution::make<resolution::LiteralNullInfo>(range);
  auto target = resolution::make<resolution::DotInfo>(receiver, name);
  for (auto comparison : comparisons) {
    auto call = resolution::make<resolution::CallVirtualInfo>(target,
        CallShape(0).with_implicit_this(), List<resolution::ExpressionView>(), range);
    call->set_comparison_kind(comparison);
    expressions.add(call);
  }
  expressions.add(resolution::make<resolution::CallVirtualInfo>(target,
      CallShape(0).with_implicit_this(), List<resolution::ExpressionView>(), range));
  auto bytes = ListBuilder<uint8>::build(uint8(7));
  expressions.add(resolution::make<resolution::LiteralByteArrayInfo>(bytes, range));
  auto body = resolution::make<resolution::SequenceInfo>(expressions.build(), range);
  method->set_body(body);
  auto program = resolution::make<resolution::ProgramInfo>(ListBuilder<resolution::ClassView>::build(klass),
      ListBuilder<resolution::MethodView>::build(method),
      ListBuilder<resolution::GlobalView>::build(global),
      ListBuilder<resolution::ClassView>::build(klass),
      ListBuilder<resolution::MethodView>::build(method),
      ListBuilder<resolution::Type>::build(type), method, method, klass);

  auto lowered = lower_to_ir(program);
  auto lowered_method = lowered->methods()[0];
  auto lowered_body = lowered_method->body()->as_Sequence();
  auto lowered_local = lowered_body->expressions()[0]->as_AssignmentDefine()->local();
  auto lowered_code = lowered_body->expressions()[1]->as_Code();
  auto lowered_capture = lowered_code->parameters()[0]->as_CapturedLocal();
  for (int i = 0; i < 5; i++) {
    check(lowered_body->expressions()[3 + i]->as_CallVirtual()->opcode() == opcodes[i]);
  }
  check(lowered_body->expressions()[8]->as_CallVirtual()->opcode() == INVOKE_VIRTUAL);
  check(lowered_method == lowered->entry_points()[0]);
  check(lowered_method == lowered->lookup_failure());
  check(lowered_method->holder() == lowered->classes()[0]);
  check(lowered_method->return_type().klass() == lowered->classes()[0]);
  check(lowered_method->return_type().is_nullable());
  check(lowered_body->expressions()[2]->as_CallStatic()->target()->target() == lowered_method);
  check(lowered->globals()[0]->body()->as_ReferenceGlobal()->target() == lowered->globals()[0]);
  check(lowered->globals()[0]->has_explicit_type());
  check(lowered_capture->local() == lowered_local);
  check(lowered_code->body()->as_ReferenceLocal()->target() == lowered_capture);
  check(!lowered_local->has_explicit_type());
  check(lowered_local->has_guaranteed_type());
  check(lowered_local->type().klass() == lowered->classes()[0]);
  check(lowered_local->is_captured());
  // Two lowerings must be independent, including mutable lists and local state.
  auto second = lower_to_ir(program);
  lowered_body->expressions()[0] = zone_new<ir::Nop>(range);
  lowered_local->register_mutation();
  lowered_body->expressions()[9]->as_LiteralByteArray()->data()[0] = 99;
  check(bytes[0] == 7);
  check(second->methods()[0]->body()->as_Sequence()->expressions()[9]->as_LiteralByteArray()->data()[0] == 7);
  check(body->expressions()[0] == define);
  check(local->mutation_count() == 0);
  check(second->methods()[0]->body()->as_Sequence()->expressions()[0]->is_AssignmentDefine());
  check(second->classes()[0] != lowered->classes()[0]);
}

} // namespace toit::compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::compiler::test();
  return 0;
}
