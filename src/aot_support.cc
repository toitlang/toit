#include "aot_support.h"

void run(toit::Process* process, toit::Object** sp) __attribute__((weak));

void run(toit::Process* process, toit::Object** sp) {
  UNIMPLEMENTED();
}

void add_int_int(RUN_PARAMS) {
  UNIMPLEMENTED();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void sub_int_smi(RUN_PARAMS) {
  UNIMPLEMENTED();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void sub_int_int(RUN_PARAMS) {
  UNIMPLEMENTED();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

void lte_int_int(RUN_PARAMS) {
  UNIMPLEMENTED();
  run_func continuation = reinterpret_cast<run_func>(extra);
  TAILCALL return continuation(RUN_ARGS);
}

Object** allocate(Object** sp, Process* process, int index, int fields, int size, TypeTag tag) {
  ObjectHeap* heap = process->object_heap();
  Object* result = heap->allocate_instance(tag, Smi::from(index), Smi::from(size));
  if (result == null) {
    UNIMPLEMENTED();
  }

  Instance* instance = Instance::cast(result);
  Object* null_object = process->program()->null_object();
  for (int i = 0; i < fields; i++) {
    instance->at_put(i, null_object);
  }

  PUSH(result);
  heap->check_install_heap_limit();
  return sp;
}

void allocate(RUN_PARAMS) {
  ObjectHeap* heap = process->object_heap();
  Smi* index = Smi::from(reinterpret_cast<word>(x2));
  Object* result = heap->allocate_instance(index);
  if (result == null) {
    UNIMPLEMENTED();
  }

  Program* program = process->program();
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
