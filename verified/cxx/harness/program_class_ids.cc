// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "interpreter_v2.cc"
#undef protected
#undef private

#include "../annotated/model/program_class_ids.h"

using namespace toit;

extern Program image;
extern V2MethodTable methods;
extern Smi* arbitrary_class_id();

// program.h undefines its list after declaring the getters.
#define FOR_EACH_CLASS_ID(CHECK) \
  CHECK(string_class_id) \
  CHECK(array_class_id) \
  CHECK(byte_array_class_id) \
  CHECK(byte_array_cow_class_id) \
  CHECK(byte_array_slice_class_id) \
  CHECK(string_slice_class_id) \
  CHECK(string_byte_slice_class_id) \
  CHECK(list_class_id) \
  CHECK(list_slice_class_id) \
  CHECK(map_class_id) \
  CHECK(tombstone_class_id) \
  CHECK(stack_class_id) \
  CHECK(null_class_id) \
  CHECK(true_class_id) \
  CHECK(false_class_id) \
  CHECK(object_class_id) \
  CHECK(double_class_id) \
  CHECK(large_integer_class_id) \
  CHECK(smi_class_id) \
  CHECK(task_class_id) \
  CHECK(large_array_class_id) \
  CHECK(lazy_initializer_class_id) \
  CHECK(exception_class_id)

int main() {
  static_assert(sizeof(uword) * 8 == CXXV_WORD_BITS, "target word width");
  toit_v2_program tables;
  v2_program_tables(&image, &methods, nullptr, &tables);
  CXXV_ASSERT(tables.builtin_class_ids == reinterpret_cast<const uword*>(image._builtin_class_ids),
              "the Rust tables borrow the native class-id array");

#define COUNT_CLASS_ID(name) + 1
  static_assert(Program::BUILTIN_CLASS_IDS_COUNT == 0 FOR_EACH_CLASS_ID(COUNT_CLASS_ID), "cover all built-in class IDs");
#undef COUNT_CLASS_ID
  // Initialize slots independently so a getter selecting a neighboring slot is detectable.
#define INIT_CLASS_ID(name) image._builtin_class_ids[Program::name##_INDEX] = arbitrary_class_id();
  FOR_EACH_CLASS_ID(INIT_CLASS_ID)
#undef INIT_CLASS_ID

#define CHECK_NATIVE_CLASS_ID(name) \
  CXXV_ASSERT(image.name() == image._builtin_class_ids[Program::name##_INDEX], #name " native slot"); \
  CXXV_ASSERT(image.class_id(Program::name##_INDEX) == image.name(), #name " indexed lookup");
  FOR_EACH_CLASS_ID(CHECK_NATIVE_CLASS_ID)
#undef CHECK_NATIVE_CLASS_ID

  // Exercise the very same aliases as the VeriFast clients against the native named methods.
#define Program_class_id(p, index) ((p)->class_id(index))
#define CHECK_MODEL_CLASS_ID(name) CXXV_ASSERT(Program_##name(&image) == image.name(), #name " model slot")
  CHECK_MODEL_CLASS_ID(array_class_id);
  CHECK_MODEL_CLASS_ID(list_class_id);
  CHECK_MODEL_CLASS_ID(list_slice_class_id);
  CHECK_MODEL_CLASS_ID(map_class_id);
  CHECK_MODEL_CLASS_ID(large_array_class_id);
  CHECK_MODEL_CLASS_ID(tombstone_class_id);
  CHECK_MODEL_CLASS_ID(byte_array_cow_class_id);
  CHECK_MODEL_CLASS_ID(byte_array_slice_class_id);
  CHECK_MODEL_CLASS_ID(string_byte_slice_class_id);
  CHECK_MODEL_CLASS_ID(string_slice_class_id);
#undef CHECK_MODEL_CLASS_ID
#undef Program_class_id
}
