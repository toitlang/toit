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

#pragma once

#include <stdarg.h>

#include "top.h"
#include "bytecodes.h"
#include "objects.h"

namespace toit {

#ifdef TOIT_DEBUG

class Printer {
 public:
  Printer(Program* program) : _program(program) {}

  virtual void printf(const char* format, ...) = 0;

  // For printing strings.  %s relies on a terminating null, but for this
  // you get to specify the length.
  void print_buffer(const uint8_t* buffer, int length);

  Program* program() { return _program; }
 private:
  Program* _program;
};

class ConsolePrinter : public Printer {
 public:
  explicit ConsolePrinter(Program* program) : Printer(program) {}
  virtual void printf(const char* format, ...) {
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
  }
};

class BufferPrinter : public Printer {
 public:
  BufferPrinter(Program* program, char* buffer, int buffer_len)
    : Printer(program), _ptr(buffer), _buffer(buffer), _buffer_len(buffer_len), _remaining(buffer_len) {}

  int length() const {
    return _ptr - _buffer;
  }

  virtual void printf(const char* format, ...);

 private:
  char* _ptr;
  char* _buffer;
  int _buffer_len;
  int _remaining;
};

void print_object(Printer* printer, Object* object);
void print_object_short(Printer* printer, Object* object, bool is_top_level = true);
void print_name(Printer* printer, String* string);
void print_heap(Printer* printer, ObjectHeap* heap, const char* title);
void print_bytecode(Printer* printer, uint8* bcp, int bci);
void print_bytecode(Printer* printer, Method method, int bci);

void print_method_console(Method method, int bytecode_size);
void print_method_console(int method_id, Program* program, int bytecode_size);
void print_method_console(Smi* method_id, Program* program, int bytecode_size);
void print_object_short_console(Object* object, bool is_top_level = true);
void print_name_console(String* string);
void print_heap_console(ObjectHeap* heap, const char* title);
void print_bytecode_console(uint8* bcp);

#endif

} // namespace toit
