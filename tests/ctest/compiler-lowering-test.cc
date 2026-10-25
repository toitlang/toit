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
  auto range = Source::Range::invalid();
  auto name = Symbol::synthetic("test");
  auto klass = zone_new<resolution::Class>(name, resolution::Class::CLASS, false, range, range);
  auto type = resolution::Type(klass).to_nullable();
  auto method = zone_new<resolution::MethodStatic>(name, klass, ResolutionShape(0),
      resolution::Method::GLOBAL_FUN, range, range);
  method->set_return_type(type);
  auto global = zone_new<resolution::Global>(name, true, range, range);
  global->set_explicit_return_type(type);
  // Both a method cycle and a global cycle must preserve declaration identities.
  auto self = zone_new<resolution::ReferenceMethod>(method, range);
  auto recursive_call = zone_new<resolution::CallStatic>(self, CallShape(0),
      List<resolution::Expression*>(), range);
  global->set_body(zone_new<resolution::ReferenceGlobal>(global, true, range));

  auto local = zone_new<resolution::Local>(name, false, false, range);
  local->set_type(type);  // Inferred, not explicit.
  local->mark_guaranteed_inferred_type();
  local->mark_captured();
  auto captured = zone_new<resolution::CapturedLocal>(local, 0, range);
  auto code = zone_new<resolution::Code>(name,
      ListBuilder<resolution::Parameter*>::build(captured),
      zone_new<resolution::ReferenceLocal>(captured, 0, range), false, range);
  code->set_captured_count(1);
  auto define = zone_new<resolution::AssignmentDefine>(local,
      zone_new<resolution::LiteralNull>(range), range);
  auto body = zone_new<resolution::Sequence>(
      ListBuilder<resolution::Expression*>::build(define, code, recursive_call), range);
  method->set_body(body);
  auto program = zone_new<resolution::Program>(ListBuilder<resolution::Class*>::build(klass),
      ListBuilder<resolution::Method*>::build(method),
      ListBuilder<resolution::Global*>::build(global),
      ListBuilder<resolution::Class*>::build(klass),
      ListBuilder<resolution::Method*>::build(method),
      ListBuilder<resolution::Type>::build(type), method, method, klass);

  auto lowered = lower_to_ir(program);
  auto lowered_method = lowered->methods()[0];
  auto lowered_body = lowered_method->body()->as_Sequence();
  auto lowered_local = lowered_body->expressions()[0]->as_AssignmentDefine()->local();
  auto lowered_code = lowered_body->expressions()[1]->as_Code();
  auto lowered_capture = lowered_code->parameters()[0]->as_CapturedLocal();
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
