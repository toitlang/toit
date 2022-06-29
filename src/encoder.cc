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
  explicit EncodeVisitor(ProgramOrientedEncoder* encoder) : _encoder(encoder), _level(0) {};

  void visit_byte_array(const uint8* bytes, int length) {
    _encoder->write_byte_array_header(length);
    for (int i = 0; i < length; i++) {
      _encoder->write_byte(bytes[i]);
    }
  }

 private:
  EncodeVisitor(ProgramOrientedEncoder* encoder, int level) : _encoder(encoder), _level(level) {};

  // Restrictions when encoding collections.
  const int MAX_NOF_STRING_ELEMENTS = 104;
  const int MAX_NOF_BYTEARRAY_ELEMENTS = 40;
  const int MAX_NOF_ARRAY_ELEMENTS = 10;

  void visit_smi(Smi* smi) {
    _encoder->write_int(smi->value());
  }
  void visit_string(String* string) {
    _encoder->write_byte('S');
    String::Bytes bytes(string);
    const char* OVERFLOW_DOTS = "...";
    const int printed = Utils::min(bytes.length(), MAX_NOF_STRING_ELEMENTS);
    const bool overflow = bytes.length() > MAX_NOF_STRING_ELEMENTS;
    const int limit = printed + (overflow ? strlen(OVERFLOW_DOTS) : 0);
    _encoder->write_int(limit);
    for (int i = 0; i < printed; i++) {
      _encoder->write_byte(bytes.at(i));
    }
    if (overflow) {
      for (const char* p = OVERFLOW_DOTS; *p; p++) {
        _encoder->write_byte(*p);
      }
    }
  }

  void visit_array(Array* array) {
    _encoder->write_header(2, 'A');
    _encoder->write_int(array->length());
    _encoder->write_byte('[');
    _encoder->write_byte('#');
    const int limit = Utils::min(array->length(), MAX_NOF_ARRAY_ELEMENTS);
    _encoder->write_int(limit);
    EncodeVisitor sub(_encoder, _level + 1);
    for (int i = 0; i < limit; i++) {
      sub.accept(array->at(i));
    }
  }

  void visit_byte_array(ByteArray* byte_array) {
    _encoder->write_byte('[');
    _encoder->write_byte('$');
    _encoder->write_byte('U');
    _encoder->write_byte('#');
    ByteArray::Bytes bytes(byte_array);
    const int limit = Utils::min(bytes.length(), MAX_NOF_BYTEARRAY_ELEMENTS);
    _encoder->write_int(limit);
    for (int i = 0; i < limit; i++) {
      _encoder->write_byte(bytes.at(i));
    }
  }

  void visit_stack(Stack* stack);

  void visit_list(Instance* instance, Array* backing_array, int size) {
    _encoder->write_header(2, 'L');
    _encoder->write_int(size);
    _encoder->write_byte('[');
    _encoder->write_byte('#');
    const int limit = Utils::min(size, MAX_NOF_ARRAY_ELEMENTS);
    _encoder->write_int(limit);
    EncodeVisitor sub(_encoder, _level + 1);
    for (int i = 0; i < limit; i++) {
      sub.accept(backing_array->at(i));
    }
  }

  void visit_instance(Instance* instance) {
    Smi* class_id = instance->class_id();
    if (class_id == _encoder->program()->list_class_id() && is_array(instance->at(0))) {
      // The backing storage in a list can be either an array -- or a
      // large array. Only optimize if it isn't large.
      // We use the same layout assumptions for List_ as the interpreter.
      visit_list(instance, Array::cast(instance->at(0)), Smi::cast(instance->at(1))->value());
    } else {
      _encoder->write_header(1, 'I');
      _encoder->write_int(class_id->value());
    }
  }

  void visit_oddball(HeapObject* oddball) {
    Program* program = _encoder->program();
    if (oddball == program->null_object()) _encoder->write_byte('Z');
    else if (oddball == program->true_object()) _encoder->write_byte('T');
    else if (oddball == program->false_object()) _encoder->write_byte('F');
    else UNREACHABLE();
  }

  void visit_double(Double* d) {
    _encoder->write_double(d->value());
  }

  void visit_large_integer(LargeInteger* large_integer) {
    _encoder->write_int(large_integer->value());
  }

  void visit_task(Task* value) {
    visit_instance(value);
  }

 public:
  void visit_frame(int index, int absolute_bci) {
    _encoder->write_header(2, 'F');
    _encoder->write_int(index);
    _encoder->write_int(absolute_bci);
  }

 private:
  ProgramOrientedEncoder* _encoder;
  int _level;
};

#ifdef IOT_DEVICE
#define MAX_NUMBER_OF_STACK_FRAMES  40  // About 629 bytes of stack trace, max.
#else
#define MAX_NUMBER_OF_STACK_FRAMES 100
#endif


class EncodeFrameCallback : public FrameCallback {
 public:
  EncodeFrameCallback(EncodeVisitor* visitor, int number_of_frames) : _visitor(visitor), _number_of_frames(number_of_frames), _count(0) {}

  void do_frame(Stack* stack, int number, int absolute_bci) {
     if (_include(number)) {
       _visitor->visit_frame(number, absolute_bci);
       _count++;
     }
  }

  int number_of_frames_written() {
    return _count;
  }

  int number_of_frames_to_write() {
    return Utils::min(_number_of_frames, MAX_NUMBER_OF_STACK_FRAMES);
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
    return (index < boundary_1) || (_number_of_frames - index) <= boundary_2;
  }

  EncodeVisitor* const _visitor;
  int const _number_of_frames;
  int _count;
};

void EncodeVisitor::visit_stack(Stack* stack) {
  FrameCallback nothing;
  int number_of_frames = stack->frames_do(_encoder->program(), &nothing);
  EncodeVisitor sub(_encoder, _level + 1);
  EncodeFrameCallback doit(&sub, number_of_frames);
  _encoder->write_byte('[');
  _encoder->write_byte('#');
  _encoder->write_int(2);
  _encoder->write_int('S');
  _encoder->write_byte('[');
  _encoder->write_byte('#');
  int const nof = doit.number_of_frames_to_write();
  _encoder->write_int(nof);
  stack->frames_do(_encoder->program(), &doit);
  ASSERT(nof == doit.number_of_frames_written());
}


ProgramOrientedEncoder::ProgramOrientedEncoder(Program* program, Buffer* buffer)
  : Encoder(buffer),
    _program(program) {
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
  _buffer->put_byte(c);
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
    _buffer->put_byte('U');
    _buffer->put_byte(i);
  } else if (i >= MY_INT8_MIN && i <= MY_INT8_MAX) {
    _buffer->put_byte('i');
    _buffer->put_byte(i);
  } else if (i >= MY_INT16_MIN && i <= MY_INT16_MAX) {
    _buffer->put_byte('I');
    _buffer->put_int16(i);
  } else if (i >= MY_INT32_MIN && i <= MY_INT32_MAX) {
    _buffer->put_byte('l');
    _buffer->put_int32(i);
  } else {
    _buffer->put_byte('L');
    _buffer->put_int64(i);
  }
}

void Encoder::write_int32(int64 i) {
  ASSERT(i >= MY_INT32_MIN && i <= MY_INT32_MAX);
  _buffer->put_byte('l');
  _buffer->put_int32(i);
}

void Encoder::write_double(double value) {
  _buffer->put_byte('D');
  auto raw = bit_cast<int64>(value);
  _buffer->put_int64(raw);
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
