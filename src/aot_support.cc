#include "aot_support.h"

void run(toit::Process* process, toit::Object** sp) __attribute__((weak));

void run(toit::Process* process, toit::Object** sp) {
  UNIMPLEMENTED();
}

#define AOT_RELATIONAL(mnemonic)                             \
bool aot_##mnemonic(Object* a, Object* b) {                  \
  UNIMPLEMENTED();                                           \
  return false;                                              \
}                                                            \
void aot_##mnemonic(RUN_PARAMS) {                            \
  UNIMPLEMENTED();                                           \
  run_func continuation = reinterpret_cast<run_func>(extra); \
  TAILCALL return continuation(RUN_ARGS);                    \
}

AOT_RELATIONAL(lt)
AOT_RELATIONAL(lte)
AOT_RELATIONAL(gt)
AOT_RELATIONAL(gte)
#undef AOT_RELATIONAL

Object** aot_add(Object** sp, Wonk* wonk) {
  UNIMPLEMENTED();
  return sp;
}

void aot_add(RUN_PARAMS) {
  UNIMPLEMENTED();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

Object** aot_sub(Object** sp, Wonk* wonk) {
  UNIMPLEMENTED();
  return sp;
}

void aot_sub(RUN_PARAMS) {
  UNIMPLEMENTED();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void allocate(RUN_PARAMS) {
  ObjectHeap* heap = wonk->heap;
  Smi* index = Smi::from(reinterpret_cast<word>(x2));
  Object* result = heap->allocate_instance(index);
  if (result == null) {
    UNIMPLEMENTED();
  }

  Program* program = wonk->process->program();
  Instance* instance = Instance::cast(result);
  int fields = Instance::fields_from_size(program->instance_size_for(instance));
  for (int i = 0; i < fields; i++) {
    instance->at_put(i, null_object);
  }

  PUSH(result);
  heap->check_install_heap_limit();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void invoke_primitive(RUN_PARAMS) {
  PrimitiveEntry* primitive = reinterpret_cast<PrimitiveEntry*>(x2);
  Primitive::Entry* entry = reinterpret_cast<Primitive::Entry*>(primitive->function);
  int arity = primitive->arity;
  Object* result = entry(wonk->process, sp + Interpreter::FRAME_SIZE + arity - 1);
  // TODO(kasper): Check for failures.
  run_func continuation = reinterpret_cast<run_func>(STACK_AT(1));
  DROP(arity + 1);
  STACK_AT_PUT(0, result);
  TAILCALL return continuation(RUN_ARGS);
}

void load_global(RUN_PARAMS) {
  int index = Smi::cast(STACK_AT(0))->value();
  // TODO(kasper): Check bounds.
  STACK_AT_PUT(0, wonk->globals[index]);
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void store_field(RUN_PARAMS) {
  int index = reinterpret_cast<word>(x2);
  Object* value = STACK_AT(0);
  Instance* instance = Instance::cast(STACK_AT(1));
  instance->at_put(index, value);
  STACK_AT_PUT(1, value);
  DROP1();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void store_field_pop(RUN_PARAMS) {
  int index = reinterpret_cast<word>(x2);
  Object* value = STACK_AT(0);
  Instance* instance = Instance::cast(STACK_AT(1));
  instance->at_put(index, value);
  DROP(2);
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void store_global(RUN_PARAMS) {
  Object* value = POP();
  int index = Smi::cast(POP())->value();
  // TODO(kasper): Check bounds.
  wonk->globals[index] = value;
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}
