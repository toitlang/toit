// Copyright (C) 2026 Toit contributors.
//
// The install-time checks of a program image (wave 12): the native
// V2Verifier::image_layout_error (CXXV_PART 1) and builtin_classes_error
// (CXXV_PART 2) of src/verifier_v2.cc on a crafted image.
//
// The image is one object of the harness: a Program followed by
// CXXV_IMAGE_WORDS words. Every table of the Program (the List and Table
// fields: their data pointer and length) is at an arbitrary offset from
// the image (any address) with an arbitrary length, every word after the
// Program arbitrary (an immediate, or a reference at any offset), the
// program size arbitrary up to the image's size. ESBMC's pointer checks
// make every read of the checks a proof obligation: a read outside the
// image (or misaligned) fails. Part 1 asserts what a null result of
// image_layout_error means (every table and the method table literal
// inside the image, with the readers' alignment), part 2 that
// builtin_classes_error reads the class bits table (inside the image, as
// part 1 gives it) only at the ids it checked, for arbitrary builtin class
// ids; its facts for a null result are proved by VeriFast
// (../annotated/loader/builtin_classes.render). Not covered:
// builtin_roots_error (the roots as smis or objects of the image, as the
// conversion accepts them: no verdict in 30 minutes on LP64, ESBMC
// resolving each root's integer address against the image), whose reads
// are the root objects' headers and an array root's length word.
//
// The restrictions below on how pointers are made (pointer arithmetic on
// the image, not arbitrary integers; literal words not read from the
// Program's own fields) work around ESBMC's integer/pointer model, which
// gives a pointer made from an arbitrary integer, or loaded from memory
// that holds an integer, no consistent integer value: each conversion
// back can differ, which no machine does.

#include "prelude.h"
#define private public
#define protected public
#include "verifier_v2.cc"
#undef protected
#undef private

using namespace toit;

#ifndef CXXV_IMAGE_WORDS
#define CXXV_IMAGE_WORDS 8
#endif

// The image: the Program and the words after it, as one object.
struct Image {
  alignas(Program) uint8 program[sizeof(Program)];
  uword words[CXXV_IMAGE_WORDS];
};
static Image image;

// A table pointer at any offset from the image (so any address: the
// offset is a word), made by pointer arithmetic on the image: ESBMC gives
// a pointer made from an arbitrary integer no consistent integer value
// (each conversion back to an integer may differ), which no machine has.
template <typename T> static T* arbitrary_pointer() {
  return reinterpret_cast<T*>(reinterpret_cast<uint8*>(&image) + nondet_word());
}

static bool inside_at(uword begin, uword end, uword a, word length, word element_size, uword alignment) {
  if (length <= 0) return true;
  return (a & (alignment - 1)) == 0 && a >= begin && a <= end &&
      static_cast<uword>(length) * static_cast<uword>(element_size) <= end - a;
}

static bool inside(uword begin, uword end, const void* data, word length, word element_size, uword alignment) {
  return inside_at(begin, end, reinterpret_cast<uword>(data), length, element_size, alignment);
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Program* program = reinterpret_cast<Program*>(image.program);
  for (int i = 0; i < CXXV_IMAGE_WORDS; i++) {
#if CXXV_PART == 1
    // A word is a smi or another immediate (any word whose low bits are not
    // the heap tag), or a reference at any offset from the image, inside it
    // or not. A reference is made by pointer arithmetic on the image, not
    // from an arbitrary integer: ESBMC resolves an arbitrary integer against
    // every object of its address model (string literals included), and an
    // integer inside the image could then come out as a pointer to another
    // object (out of its bounds), which no machine has.
    uword w = nondet_ulong();
    if (is_heap_object(reinterpret_cast<Object*>(w))) {
      word offset = nondet_word();
      w = reinterpret_cast<uword>(reinterpret_cast<uint8*>(&image) + offset) + Object::HEAP_TAG;
    }
    // An object a word refers to does not start in the Program: its header
    // would be a pointer of a Program field (below). Objects after the
    // Program and outside the image are covered.
    CXXV_ASSUME(!is_heap_object(reinterpret_cast<Object*>(w)) ||
                w - Object::HEAP_TAG >= reinterpret_cast<uword>(&image.words) ||
                w - Object::HEAP_TAG < reinterpret_cast<uword>(&image));
    // Stored as the object reference the checks load (ESBMC models a
    // pointer loaded from memory that holds an integer as an invalid
    // pointer whose integer value is unconstrained at each conversion).
    reinterpret_cast<Object**>(image.words)[i] = reinterpret_cast<Object*>(w);
#else
    image.words[i] = nondet_ulong();
#endif
  }
  program->global_variables.array_ = arbitrary_pointer<Object*>();
  program->global_variables.length_ = nondet_int();
  program->literals.array_ = arbitrary_pointer<Object*>();
  program->literals.length_ = nondet_int();
  // The literal words the checks read (the last one) come from the words
  // after the Program, or from outside the image: ESBMC gives a pointer
  // stored in a Program field (the tables' data pointers) a provenance,
  // and reading that word as an object reference converts it to an
  // integer anew at each use (a different value each time), which no
  // machine does. The words after the Program are arbitrary integers, so
  // every value of the last literal is still covered.
  CXXV_ASSUME(reinterpret_cast<uword>(program->literals.array_) >= reinterpret_cast<uword>(&image.words) ||
              reinterpret_cast<uword>(program->literals.array_) + WORD_SIZE <= reinterpret_cast<uword>(&image));
  program->dispatch_table = List<int32>(arbitrary_pointer<int32>(), nondet_word());
  program->class_check_ids = List<uint16>(arbitrary_pointer<uint16>(), nondet_word());
  program->interface_check_offsets = List<uint16>(arbitrary_pointer<uint16>(), nondet_word());
  program->class_bits = List<uint16>(arbitrary_pointer<uint16>(), nondet_word());
  program->bytecodes = List<uint8>(arbitrary_pointer<uint8>(), nondet_word());
  word program_size = nondet_word();
  CXXV_ASSUME(program_size <= static_cast<word>(sizeof(Image)));

#if CXXV_PART != 1
  // Part 2 starts from tables the layout check accepted: the class
  // bits and the literals inside the image (part 1 proves that this is
  // what its null result means).
  program->class_bits = List<uint16>(reinterpret_cast<uint16*>(image.words), nondet_word());
  CXXV_ASSUME(0 <= program->class_bits.length() &&
              program->class_bits.length() <= static_cast<word>(sizeof(image.words) / sizeof(uint16)));
  program->literals.length_ = 0;
  program->global_variables.length_ = 0;
  program->dispatch_table = List<int32>();
  program->class_check_ids = List<uint16>();
  program->interface_check_offsets = List<uint16>();
  program->bytecodes = List<uint8>();
  program_size = sizeof(Image);
#endif
  const char* layout = V2Verifier::image_layout_error(program, program_size);
  if (layout != nullptr) return 0;

  uword begin = reinterpret_cast<uword>(&image);
  uword end = begin + program_size;
#if CXXV_PART == 1
  CXXV_ASSERT(program_size >= static_cast<word>(sizeof(Program)), "the image holds its Program");
  CXXV_ASSERT(inside(begin, end, program->global_variables.array(), program->global_variables.length(),
                     WORD_SIZE, WORD_SIZE), "global variables inside the image");
  CXXV_ASSERT(inside(begin, end, program->literals.array(), program->literals.length(), WORD_SIZE, WORD_SIZE),
              "literals inside the image");
  CXXV_ASSERT(inside(begin, end, program->dispatch_table.data(), program->dispatch_table.length(), 4, 4),
              "dispatch table inside the image");
  CXXV_ASSERT(inside(begin, end, program->class_check_ids.data(), program->class_check_ids.length(), 2, 2),
              "class check ids inside the image");
  CXXV_ASSERT(inside(begin, end, program->interface_check_offsets.data(), program->interface_check_offsets.length(),
                     2, 2), "interface check offsets inside the image");
  CXXV_ASSERT(inside(begin, end, program->class_bits.data(), program->class_bits.length(), 2, 2),
              "class bits inside the image");
  CXXV_ASSERT(inside(begin, end, program->bytecodes.data(), program->bytecodes.length(), 1, 1),
              "bytecodes inside the image");
  int count = program->literals.length();
  if (count > 0) {
    Object* last = program->literals.array()[count - 1];
    if (is_heap_object(last)) {
      uword object = reinterpret_cast<uword>(last) - Object::HEAP_TAG;
      // On integers: converted back to a pointer, ESBMC resolves the
      // integer against every object of its address model, not
      // necessarily the one the checked code saw (no machine does that).
      CXXV_ASSERT(inside_at(begin, end, object, 2, WORD_SIZE, WORD_SIZE),
                  "the last literal's header and length inside the image");
      if (is_byte_array(last)) {
        ByteArray* array = ByteArray::cast(last);
        ByteArray::Bytes bytes(array);
        CXXV_ASSERT(bytes.address() != nullptr && inside(begin, end, bytes.address(), bytes.length(), 1, 1),
                    "the method table literal's content inside the image");
      }
    }
  }
#elif CXXV_PART == 2
  // The builtin class ids: arbitrary words.
  for (int i = 0; i < Program::BUILTIN_CLASS_IDS_COUNT; i++) {
    program->_builtin_class_ids[i] = reinterpret_cast<Smi*>(nondet_ulong());
  }
  V2Verifier::builtin_classes_error(program);
#endif
}
