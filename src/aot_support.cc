#include "aot_support.h"

void run(toit::Process* process, toit::Object** sp) __attribute__((weak));

void run(toit::Process* process, toit::Object** sp) {
  UNIMPLEMENTED();
}

Object** add_int_int(Object** sp) {
  UNIMPLEMENTED();
  return sp;
}

Object** sub_int_int(Object** sp) {
  UNIMPLEMENTED();
  return sp;
}

Object** sub_int_smi(Object** sp) {
  UNIMPLEMENTED();
  return sp;
}

bool lte_ints_slow(Object* a, Object* b) {
  UNIMPLEMENTED();
  return false;
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
