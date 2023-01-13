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
