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
#include "encoder_visitor.h"
#include "heap.h"
#include "bytecodes.h"
#include "profiler.h"
#include "utils.h"
#include "uuid.h"

namespace toit {

#ifdef TOIT_FREERTOS
#define MAX_NUMBER_OF_STACK_FRAMES  40  // About 629 bytes of stack trace, max.
#else
#define MAX_NUMBER_OF_STACK_FRAMES 100
#endif


class EncodeFrameCallback : public FrameCallback {
 public:
  EncodeFrameCallback(Encoder* encoder, int number_of_frames) : encoder_(encoder), number_of_frames_(number_of_frames), count_(0) {}

  void do_frame(Stack* stack, int number, int absolute_bci) {
    if (_include(number)) {
      encoder_->write_header(2, 'F');
      encoder_->write_int(number);
      encoder_->write_int(absolute_bci);
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
    return (index < boundary_1) || (number_of_frames_ - index) <= boundary_2;
  }

  Encoder* const encoder_;
  int const number_of_frames_;
  int count_;
};

void EncodeVisitor::visit_stack(Stack* stack) {
  int number_of_frames = stack->frames_do(encoder_->program(), nullptr);
  EncodeFrameCallback doit(encoder_, number_of_frames);
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
  const uint8* snapshot_uuid = program->snapshot_uuid();
  visitor.visit_byte_array(snapshot_uuid, UUID_SIZE);
  // Last element is the payload.
}

bool ProgramOrientedEncoder::encode(Object* object) {
  EncodeVisitor visitor(this);
  visitor.accept(object);
  // The size of an overflowed buffer is larger than its content.
  return !buffer()->has_overflow();
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

bool ProgramOrientedEncoder::encode_error(Object* type, Object* const* elements, word count, Stack* stack) {
  write_byte('[');
  write_byte('#');
  write_int(4);
  write_int('E');
  EncodeVisitor visitor(this);
  visitor.accept(type);
  // The encoding of an array (EncodeVisitor::visit_array).
  write_header(2, 'A');
  write_int(count);
  write_byte('[');
  write_byte('#');
  write_int(count);
  for (word i = 0; i < count; i++) {
    visitor.accept(elements[i]);
  }
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

void Encoder::write_header(word size, uint8 tag) {
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

void Encoder::write_byte_array_header(word length) {
  write_byte('[');
  write_byte('$');
  write_byte('U');
  write_byte('#');
  write_int(length);
}

void Encoder::write_byte_array(ByteArray* array) {
  // External proxies hold native objects, so they have no payload to encode.
  if (array->has_external_address() && array->external_tag() != RawByteTag) {
    write_byte_array_header(0);
    return;
  }
  ByteArray::Bytes bytes(array);
  const word limit = Utils::min(bytes.length(), word{40});
  write_byte_array_header(limit);
  for (word i = 0; i < limit; i++) write_byte(bytes.at(i));
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
