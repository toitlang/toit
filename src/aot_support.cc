#include "aot_support.h"

toit::Object* run(toit::Process* process, toit::Object** sp) __attribute__((weak));

toit::Object* run(toit::Process* process, toit::Object** sp) {
  UNIMPLEMENTED();
  return null;
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
