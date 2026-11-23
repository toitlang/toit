// Copyright (C) 2018 Toitware ApS.
// Copyright (C) 2026 Toit contributors.
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

#include "objects_inline.h"
#include "encoder.h"
#include "encoder_string_prefix.h"
#include "visitor.h"

namespace toit {

class EncodeVisitor : public Visitor {
 public:
  explicit EncodeVisitor(ProgramOrientedEncoder* encoder) : encoder_(encoder), level_(0) {};

  void visit_byte_array(const uint8* bytes, word length) {
    encoder_->write_byte_array_header(length);
    for (word i = 0; i < length; i++) {
      encoder_->write_byte(bytes[i]);
    }
  }

 private:
  EncodeVisitor(ProgramOrientedEncoder* encoder, int level) : encoder_(encoder), level_(level) {};

  // Restrictions when encoding collections.
  const word MAX_NOF_ARRAY_ELEMENTS = 10;
  // Arrays and lists can contain themselves. Deeper ones are encoded as null.
  const int MAX_NESTING_LEVEL = 16;

  // Whether an array or list at this level is left out. Once the buffer has
  // overflowed, the result is discarded, so stop visiting; this also bounds
  // the work for collections that contain themselves several times.
  bool skip_collection() {
    if (encoder_->buffer()->has_overflow()) return true;
    if (level_ >= MAX_NESTING_LEVEL) {
      encoder_->write_byte('Z');
      return true;
    }
    return false;
  }

  void visit_smi(Smi* smi) {
    encoder_->write_int(Smi::value(smi));
  }
  void visit_string(String* string) {
    encoder_->write_byte('S');
    String::Bytes bytes(string);
    int printed = encoder_string_prefix(bytes.address(), bytes.length());
    bool truncated = printed < bytes.length();
    encoder_->write_int(printed + (truncated ? 3 : 0));
    for (int i = 0; i < printed; i++) encoder_->write_byte(bytes.at(i));
    if (truncated) {
      encoder_->write_byte('.');
      encoder_->write_byte('.');
      encoder_->write_byte('.');
    }
  }

  void visit_array(Array* array) {
    if (skip_collection()) return;
    visit_elements(array, array->length(), 'A');
  }

  void visit_byte_array(ByteArray* byte_array) {
    encoder_->write_byte_array(byte_array);
  }

  void visit_stack(Stack* stack);

  // Whether the given List_ has an array as backing and a size within it.
  // The fields are ordinary instance fields that Toit code can set to
  // anything; other lists are encoded as plain instances.
  static bool is_valid_list(Instance* instance) {
    Object* backing = instance->at(Instance::LIST_ARRAY_INDEX);
    Object* size = instance->at(Instance::LIST_SIZE_INDEX);
    if (!is_array(backing) || !is_smi(size)) return false;
    word value = Smi::value(size);
    return 0 <= value && value <= Array::cast(backing)->length();
  }

  void visit_elements(Array* backing_array, word size, uint8 tag) {
    encoder_->write_header(2, tag);
    encoder_->write_int(size);
    encoder_->write_byte('[');
    encoder_->write_byte('#');
    const word limit = Utils::min(size, MAX_NOF_ARRAY_ELEMENTS);
    encoder_->write_int(limit);
    EncodeVisitor sub(encoder_, level_ + 1);
    for (int i = 0; i < limit; i++) {
      sub.accept(backing_array->at(i));
    }
  }

  void visit_instance(Instance* instance) {
    Smi* class_id = instance->class_id();
    if (class_id == encoder_->program()->list_class_id() && is_valid_list(instance)) {
      // The backing storage in a list can be either an array -- or a
      // large array. Only optimize if it isn't large.
      // We use the same layout assumptions for List_ as the interpreter.
      if (skip_collection()) return;
      visit_elements(
          Array::cast(instance->at(Instance::LIST_ARRAY_INDEX)),
          Smi::value(instance->at(Instance::LIST_SIZE_INDEX)),
          'L');
    } else {
      encoder_->write_header(1, 'I');
      encoder_->write_int(Smi::value(class_id));
    }
  }

  void visit_oddball(HeapObject* oddball) {
    Program* program = encoder_->program();
    if (oddball == program->null_object()) encoder_->write_byte('Z');
    else if (oddball == program->true_object()) encoder_->write_byte('T');
    else if (oddball == program->false_object()) encoder_->write_byte('F');
    else UNREACHABLE();
  }

  void visit_double(Double* d) {
    encoder_->write_double(d->value());
  }

  void visit_large_integer(LargeInteger* large_integer) {
    encoder_->write_int(large_integer->value());
  }

  void visit_task(Task* value) {
    visit_instance(value);
  }

  ProgramOrientedEncoder* encoder_;
  int level_;
};

}  // namespace toit
