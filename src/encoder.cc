// Copyright (C) 2018 Toitware ApS.
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

#include "objects_inline.h"
#include "encoder.h"
#include "visitor.h"
#include "heap.h"
#include "bytecodes.h"
#include "profiler.h"
#include "utils.h"
#include "uuid.h"

namespace toit {

class EncodeVisitor : public Visitor {
 public:
  explicit EncodeVisitor(ProgramOrientedEncoder* encoder) : encoder_(encoder), level_(0) {};

  void visit_byte_array(const uint8* bytes, int length) {
    encoder_->write_byte_array_header(length);
    for (int i = 0; i < length; i++) {
      encoder_->write_byte(bytes[i]);
    }
  }

 private:
  EncodeVisitor(ProgramOrientedEncoder* encoder, int level) : encoder_(encoder), level_(level) {};

  // Restrictions when encoding collections.
  const int MAX_NOF_STRING_ELEMENTS = 104;
  const int MAX_NOF_BYTEARRAY_ELEMENTS = 40;
  const int MAX_NOF_ARRAY_ELEMENTS = 10;

  void visit_smi(Smi* smi) {
    encoder_->write_int(smi->value());
  }
  void visit_string(String* string) {
    encoder_->write_byte('S');
    String::Bytes bytes(string);
    const char* OVERFLOW_DOTS = "...";
    int printed = bytes.length();
    const bool overflow = printed > MAX_NOF_STRING_ELEMENTS;
    if (overflow) {
      printed = MAX_NOF_STRING_ELEMENTS;
      // Don't chop up UTF-8 sequences.
      while ((bytes.at(printed) & 0xc0) == 0x80 && printed > 0) printed--;
    }
    const int limit = printed + (overflow ? strlen(OVERFLOW_DOTS) : 0);
    encoder_->write_int(limit);
    for (int i = 0; i < printed; i++) {
      encoder_->write_byte(bytes.at(i));
    }
    if (overflow) {
      for (const char* p = OVERFLOW_DOTS; *p; p++) {
        encoder_->write_byte(*p);
      }
    }
  }

  void visit_array(Array* array) {
    encoder_->write_header(2, 'A');
    encoder_->write_int(array->length());
    encoder_->write_byte('[');
    encoder_->write_byte('#');
    const int limit = Utils::min(array->length(), MAX_NOF_ARRAY_ELEMENTS);
    encoder_->write_int(limit);
    EncodeVisitor sub(encoder_, level_ + 1);
    for (int i = 0; i < limit; i++) {
      sub.accept(array->at(i));
    }
  }

  void visit_byte_array(ByteArray* byte_array) {
    encoder_->write_byte('[');
    encoder_->write_byte('$');
    encoder_->write_byte('U');
    encoder_->write_byte('#');
    ByteArray::Bytes bytes(byte_array);
    const int limit = Utils::min(bytes.length(), MAX_NOF_BYTEARRAY_ELEMENTS);
    encoder_->write_int(limit);
    for (int i = 0; i < limit; i++) {
      encoder_->write_byte(bytes.at(i));
    }
  }

  void visit_stack(Stack* stack);

  void visit_list(Instance* instance, Array* backing_array, int size) {
    encoder_->write_header(2, 'L');
    encoder_->write_int(size);
    encoder_->write_byte('[');
    encoder_->write_byte('#');
    const int limit = Utils::min(size, MAX_NOF_ARRAY_ELEMENTS);
    encoder_->write_int(limit);
    EncodeVisitor sub(encoder_, level_ + 1);
    for (int i = 0; i < limit; i++) {
      sub.accept(backing_array->at(i));
    }
  }

  void visit_instance(Instance* instance) {
    Smi* class_id = instance->class_id();
    if (class_id == encoder_->program()->list_class_id() && is_array(instance->at(Instance::LIST_ARRAY_INDEX))) {
      // The backing storage in a list can be either an array -- or a
      // large array. Only optimize if it isn't large.
      // We use the same layout assumptions for List_ as the interpreter.
      visit_list(
          instance,
          Array::cast(instance->at(Instance::LIST_ARRAY_INDEX)),
          Smi::cast(instance->at(Instance::LIST_SIZE_INDEX))->value());
    } else {
      encoder_->write_header(1, 'I');
      encoder_->write_int(class_id->value());
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

 public:
  void visit_frame(int index, int absolute_bci) {
    encoder_->write_header(2, 'F');
    encoder_->write_int(index);
    encoder_->write_int(absolute_bci);
  }

 private:
  ProgramOrientedEncoder* encoder_;
  int level_;
};

#ifdef IOT_DEVICE
#define MAX_NUMBER_OF_STACK_FRAMES  40  // About 629 bytes of stack trace, max.
#else
#define MAX_NUMBER_OF_STACK_FRAMES 100
#endif


class EncodeFrameCallback : public FrameCallback {
 public:
  EncodeFrameCallback(EncodeVisitor* visitor, int number_of_frames) : visitor_(visitor), number_of_frames_(number_of_frames), count_(0) {}

  void do_frame(Stack* stack, int number, int absolute_bci) {
     if (_include(number)) {
       visitor_->visit_frame(number, absolute_bci);
       count_++;
     }
  }

  int number_of_frames_written() {
    return count_;
  }

  int number_of_frames_to_write() {
    return Utils::min(number_of_frames_, MAX_NUMBER_OF_STACK_FRAMES);
  }

 private:

  bool _include(int index) {
    // Skew the boundary a little to get more from the bottom
    // of the stack, even though some stack frames are discarded
    // because they are system frames that make no sense to the
    // user.
    int boundary_1 = MAX_NUMBER_OF_STACK_FRAMES / 3;
    int boundary_2 = MAX_NUMBER_OF_STACK_FRAMES - boundary_1;
    // This means we only dump the top and bottom frames if we have more than 20 stack frames.
    return (index < boundary_1) || (number_of_frames_ - index) <= boundary_2;
  }

  EncodeVisitor* const visitor_;
  int const number_of_frames_;
  int count_;
};

void EncodeVisitor::visit_stack(Stack* stack) {
  FrameCallback nothing;
  int number_of_frames = stack->frames_do(encoder_->program(), &nothing);
  EncodeVisitor sub(encoder_, level_ + 1);
  EncodeFrameCallback doit(&sub, number_of_frames);
  encoder_->write_byte('[');
  encoder_->write_byte('#');
  encoder_->write_int(2);
  encoder_->write_int('S');
  encoder_->write_byte('[');
  encoder_->write_byte('#');
  int const nof = doit.number_of_frames_to_write();
  encoder_->write_int(nof);
  stack->frames_do(encoder_->program(), &doit);
  ASSERT(nof == doit.number_of_frames_written());
}


ProgramOrientedEncoder::ProgramOrientedEncoder(Program* program, Buffer* buffer)
  : Encoder(buffer),
    program_(program) {
  // Always encode header information to identify:
  // - Program SDK version
  // - VM SDK model
  // - Program UUID
  write_byte('[');
  write_byte('#');
  write_int(5);
  write_int('X'); // The tag is always the first element.
  EncodeVisitor visitor(this);
  // Program SDK version
  visitor.accept(program->app_sdk_version());
  // VM SDK version
  write_string(vm_sdk_model());
  // UUID
  const uint8* application_uuid = program->id();
  visitor.visit_byte_array(application_uuid, UUID_SIZE);
  // Last element is the payload.
}

bool ProgramOrientedEncoder::encode(Object* object) {
  EncodeVisitor visitor(this);
  visitor.accept(object);
  return true;
}

bool ProgramOrientedEncoder::encode_error(Object* type, Object* message, Stack* stack) {
  write_byte('[');
  write_byte('#');
  write_int(4);
  write_int('E');
  EncodeVisitor visitor(this);
  visitor.accept(type);
  visitor.accept(message);
  visitor.accept(stack);
  return !buffer()->has_overflow();
}

bool ProgramOrientedEncoder::encode_error(Object* type, const char* message, Stack* stack) {
  write_byte('[');
  write_byte('#');
  write_int(4);
  write_int('E');
  EncodeVisitor visitor(this);
  visitor.accept(type);
  write_string(message);
  visitor.accept(stack);
  return !buffer()->has_overflow();
}

bool ProgramOrientedEncoder::encode_profile(Profiler* profiler, String* title, int cutoff) {
  profiler->encode_on(this, title, cutoff);
  return !buffer()->has_overflow();
}

void Encoder::write_byte(uint8 c) {
  buffer_->put_byte(c);
}

void Encoder::write_header(int size, uint8 tag) {
  write_byte('[');
  write_byte('#');
  write_int32(size + 1);
  write_int(tag); // The tag is always the first element.
}

const int64 MY_INT8_MIN = -128;
const int64 MY_INT8_MAX = 127;
const int64 MY_INT16_MIN = -32768;
const int64 MY_INT16_MAX = 32767;
const int64 MY_INT32_MIN = -2147483647;
const int64 MY_INT32_MAX = 2147483647;
const int64 MY_UINT8_MAX = 255;

void Encoder::write_int(int64 i) {
  if (i >= 0 && i <= MY_UINT8_MAX) {
    buffer_->put_byte('U');
    buffer_->put_byte(i);
  } else if (i >= MY_INT8_MIN && i <= MY_INT8_MAX) {
    buffer_->put_byte('i');
    buffer_->put_byte(i);
  } else if (i >= MY_INT16_MIN && i <= MY_INT16_MAX) {
    buffer_->put_byte('I');
    buffer_->put_int16(i);
  } else if (i >= MY_INT32_MIN && i <= MY_INT32_MAX) {
    buffer_->put_byte('l');
    buffer_->put_int32(i);
  } else {
    buffer_->put_byte('L');
    buffer_->put_int64(i);
  }
}

void Encoder::write_int32(int64 i) {
  ASSERT(i >= MY_INT32_MIN && i <= MY_INT32_MAX);
  buffer_->put_byte('l');
  buffer_->put_int32(i);
}

void Encoder::write_double(double value) {
  buffer_->put_byte('D');
  auto raw = bit_cast<int64>(value);
  buffer_->put_int64(raw);
}

void Encoder::write_byte_array_header(int length) {
  write_byte('[');
  write_byte('$');
  write_byte('U');
  write_byte('#');
  write_int(length);
}

void Encoder::write_string(const char* string) {
  uword length = strlen(string);
  write_byte('S');
  write_int(length);
  for (uword i = 0; i < length; i++) {
    write_byte(string[i]);
  }
}

} // namespace toit
