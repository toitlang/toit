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

#include "printing.h"
#include "visitor.h"
#include "objects_inline.h"
#include "heap.h"
#include "bytecodes.h"
#include "process.h"

namespace toit {

#ifdef TOIT_DEBUG

void print_object_console(Object* object) {
  ConsolePrinter p(null);
  print_object(&p, object);
}

void print_object_short_console(Object* object, bool is_top_level) {
  ConsolePrinter p(null);
  print_object_short(&p, object, is_top_level);
}

void print_name_console(String* string) {
  ConsolePrinter p(null);
  print_name(&p, string);
}

#define BYTECODE_PRINT(name, length, format, print) print,
static const char* opcode_print[] { BYTECODES(BYTECODE_PRINT) "Illegal" };
#undef BYTECODE_PRINT

#define BYTECODE_LENGTH(name, length, format, print) length,
static int opcode_length[] { BYTECODES(BYTECODE_LENGTH) -1 };
#undef BYTECODE_LENGTH

#define BYTECODE_FORMAT(name, length, format, print) format,
static BytecodeFormat opcode_format[] { BYTECODES(BYTECODE_FORMAT) };
#undef BYTECODE_FORMAT

#define THE_LENGTH(name, length) length,
static const int format_length[] { BYTECODE_FORMATS(THE_LENGTH) -1 };
#undef THE_LENGTH

void print_name(Printer* printer, String* string) {
  const int MAX = 300;
  String::Bytes bytes(string);
  printer->print_buffer(bytes.address(), Utils::min(bytes.length(), MAX));
  if (MAX < string->length()) printer->printf("...");
}

#define MODULE_NAME(name, entries) #name,
static const char* primitive_module_names[] { MODULES(MODULE_NAME) };
#undef MODULE_NAME

// The `bci` is used for relative jumps. It can be 0, in which case the printer just
//   emits the relative offset.
void print_bytecode(Printer* printer, uint8* bcp, int bci) {
  Opcode opcode = static_cast<Opcode>(bcp[0]);
  int index = bcp[1];
  int length = opcode_length[opcode];
  BytecodeFormat format = opcode_format[opcode];

  int format_len = format_length[format];
  ASSERT(length == format_len);

  printer->printf("%s", opcode_print[opcode]);
  switch (format) {
    case OP:
      // nothing more to add.
      break;
    case OP_SU:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BU:
      printer->printf(" %u", index);
      break;
    case OP_SS:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BS:
      printer->printf(" S%u", index);
      break;
    case OP_SL:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BL: {
        if (printer->program() != null) {
          printer->printf(" '");
          print_object_short(printer, printer->program()->literals.at(index));
          printer->printf("'");
        } else {
          printer->printf(" L%u", index);
        }
      }
      break;
    case OP_SC:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BC: {
      printer->printf(" C%u", index);
      break;
    }
    case OP_SG:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BG:
      printer->printf(" G%u", index);
      break;
    case OP_SF:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BF:
      printer->printf(" T%u", bci + index);
      break;
    case OP_SB_SB:
      index = Utils::read_unaligned_uint16(bcp + 1);
      printer->printf(" T%d", bci - index);
      break;
    case OP_SCI:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BCI:
      printer->printf(" CI%d%s", index >> 1, (index & 1) == 0 ? "" : "?");
      break;
    case OP_SII:
      index = Utils::read_unaligned_uint16(bcp + 1);
    case OP_BII:
      printer->printf(" II%d%s", index >> 1, (index & 1) == 0 ? "" : "?");
      break;
    case OP_BLC:
      printer->printf(" L%dCI%d", index >> 5, index & 0x1F);
      break;
    case OP_BS_BU:
      printer->printf(" S%u %u", bcp[1], bcp[2]);
      break;
    case OP_SD: {
      int index = Utils::read_unaligned_uint16(bcp + 1);
      printer->printf(" D%u", index);
      break;
    }
    case OP_SD_BS_BU: {
      int index = Utils::read_unaligned_uint16(bcp + 1);
      printer->printf(" D%u S%u %u", index, bcp[3], bcp[4]);
      break;
    }
    case OP_SO: {
      int offset = Utils::read_unaligned_uint16(bcp + 1);
      printer->printf(" O%u", offset);
      break;
    }
    case OP_WU:
      printer->printf(" %u", Utils::read_unaligned_uint32(bcp + 1));
      break;
    case OP_SS_SO: {
      index = Utils::read_unaligned_uint16(bcp + 1);
      int offset = Utils::read_unaligned_uint16(bcp + 3);
      printer->printf(" S%u O%u", index, offset);
      break;
    }
    case OP_BS_SO: {
      int offset = Utils::read_unaligned_uint16(bcp + 2);
      printer->printf(" S%u O%u", index, offset);
      break;
    }
    case OP_BU_SO: {
      int offset = Utils::read_unaligned_uint16(bcp + 2);
      printer->printf(" %u O%u", bcp[1], offset);
      break;
    }
    case OP_SU_SU: {
      index = Utils::read_unaligned_uint16(bcp + 1);
      printer->printf(" %u %u", index, Utils::read_unaligned_uint16(bcp + 3));
      break;
    }
    case OP_BU_SU: {
      if (opcode == PRIMITIVE) {
        const char* module = primitive_module_names[bcp[1]];
        printer->printf(" %s::%u", module, Utils::read_unaligned_uint16(bcp + 2));
      } else {
        printer->printf(" %u %u", index, Utils::read_unaligned_uint16(bcp + 2));
      }
      break;
    }
    case OP_BU_WU: {
      ASSERT(opcode == NON_LOCAL_BRANCH)
      uint32 absolute_bci = Utils::read_unaligned_uint32(bcp + 2);
      printer->printf(" %d %d", absolute_bci, index);
      break;
    }
  }
}

void print_bytecode(Printer* printer, Method method, int bci) {
  uint8* bcp = &method.entry()[bci];
  print_bytecode(printer, bcp, bci);
}

/// Prints the method with the given `method_id`.
/// The `program` may be null, but more information is given if provided.
/// Decodes bytecodes_size bytes of the method. There isn't any information in
///   available to know how many bytecodes are in a method, so users have to
///   provide this value. Ideally it shouldn't be higher than the actual number of
///   bytecodes.
void print_method_console(Method method, int method_id, int bytecode_size) {
  ConsolePrinter printer(null);
  const char* type;
  if (method.is_normal_method()) {
    type = "method";
  } else if (method.is_lambda_method()) {
    type = "lambda";
  } else {
    ASSERT(method.is_block_method());
    type = "block";
  }
  printer.printf("a %s %d\n", type, method_id);
  printer.printf("  arity: %d\n", method.arity());
  printer.printf("  value (captured_count or selector_offset): %d\n", method.captured_count());
  int index = 0;
  while (index < bytecode_size) {
    printer.printf("  %3d: ", index);
    Opcode opcode = static_cast<Opcode>(method.entry()[index]);
    int length = opcode_length[opcode];
    print_bytecode(&printer, method, index);
    printer.printf("\n");
    index += length;
  }
}

void print_method_console(Method method, int bytecode_size) {
  print_method_console(method, reinterpret_cast<uword>(method.header_bcp()), bytecode_size);
}

void print_method_console(int method_id, Program* program, int bytecode_size) {
  if (program != null) {
    Method method(program->bytecodes, method_id);
    print_method_console(method, bytecode_size);
    return;
  }

  ConsolePrinter printer(null);
  printer.printf("a method %d\n");
}

void print_method_console(Smi* method_id, Program* program, int bytecode_size) {
  print_method_console(method_id->value(), program, bytecode_size);
}

void print_bytecode_console(uint8* bcp) {
  ConsolePrinter printer(null);
  Opcode opcode = static_cast<Opcode>(bcp[0]);
  int length = opcode_length[opcode];
  unsigned effective = 0;
  if (length > 1) {
    unsigned argument = bcp[1];
    effective = (effective << BYTE_BIT_SIZE) | argument;
    if (effective != argument) {
      printer.printf(" (effective %d)", effective);
    }
  }
  print_bytecode(&printer, bcp, 0);
}


class PrintVisitor : public Visitor {
 public:
  PrintVisitor() {}
  ~PrintVisitor() {}
 protected:
};

class ShortPrintVisitor : public PrintVisitor {
 public:
  explicit ShortPrintVisitor(Printer* printer, bool toplevel) : printer_(printer), toplevel_(toplevel) {}
  ~ShortPrintVisitor() {}

 protected:
  void visit_smi(Smi* smi) {
    printer_->printf("%ld", smi->value());
  }

  void visit_string(String* string) {
    const int MAX = 1280;
    if (!toplevel_) printer_->printf("\"");
    String::Bytes bytes(string);
    printer_->print_buffer(bytes.address(), Utils::min(bytes.length(), MAX));
    if (MAX < string->length()) printer_->printf("...");
    if (!toplevel_) printer_->printf("\"");
  }

  void visit_array(Array* array) {
    printer_->printf("an Array [%d]", array->length());
  }

  void visit_byte_array(ByteArray* byte_array) {
    int length = byte_array->raw_length();
    if (length < 0) length = -1 - length;
    if (byte_array->has_external_address()) {
      printer_->printf("an external ByteArray (tag:%ld) [%d]", byte_array->external_tag(), length);
    } else {
      printer_->printf("a ByteArray [%d]", length);
    }
  }

  void visit_stack(Stack* stack) {
    printer_->printf("a Stack [%d, %d]", stack->top(), stack->length());
  }

  void visit_instance(Instance* instance) {
    if (!toplevel_) printer_->printf("`");
    printer_->printf("instance<%ld>", instance->class_id()->value());
    if (!toplevel_) printer_->printf("`");
  }

  void visit_oddball(HeapObject* oddball) {
    if (printer_->program() == null) {
      printer_->printf("true/false/null(%ld)", oddball->class_id()->value());
    }
    if (oddball == printer_->program()->true_object()) {
      printer_->printf("true");
    } else if (oddball == printer_->program()->false_object()) {
      printer_->printf("false");
    } else if (oddball == printer_->program()->null_object()) {
      printer_->printf("null");
    } else {
      UNREACHABLE();
    }
  }

  void visit_double(Double* value) {
    printer_->printf("%lf", value->value());
  }

  void visit_large_integer(LargeInteger* large_integer) {
    printer_->printf("%lldL", large_integer->value());
  }

  void visit_task(Task* value) {
    printer_->printf("task-%d", value->id());
  }

 private:
  Printer* printer_;
  bool toplevel_;
};

class LongPrintVisitor : public PrintVisitor {
 public:
  explicit LongPrintVisitor(Printer* printer) : printer_(printer), sub_(printer, false) {}

 protected:
  void print_heap_address(HeapObject* object) {
    printer_->printf(" [%p]", object);
  }

  void visit_smi(Smi* smi) {
    printer_->printf("%ld", smi->value());
  }

  void visit_string(String* string) {
    print_heap_address(string);
    printer_->printf("string '");
    String::Bytes bytes(string);
    printer_->print_buffer(bytes.address(), bytes.length());
    printer_->printf("'\n");
  }

  void visit_array(Array* array) {
    print_heap_address(array);
    printer_->printf("Array [%d]\n", array->length());
    for (int index = 0; index < array->length(); index++) {
      printer_->printf(" - %d: ", index);
      sub_.accept(array->at(index));
      printer_->printf("\n");
    }
  }

  void visit_byte_array(ByteArray* byte_array) {
    print_heap_address(byte_array);
    ByteArray::Bytes bytes(byte_array);
    printer_->printf("ByteArray [%d]\n", bytes.length());
    for (int index = 0; index < bytes.length(); index++) {
      printer_->printf(" - %d: %d", index, bytes.at(index));
      printer_->printf("\n");
    }
  }

  void visit_stack(Stack* stack) {
    print_heap_address(stack);
    printer_->printf("Stack [%d,%d]\n", stack->length(), stack->length());
  }

  void visit_instance(Instance* instance) {
    print_heap_address(instance);
    printer_->printf("Instance of class %ld\n", instance->class_id()->value());
    int fields = Instance::fields_from_size(printer_->program()->instance_size_for(instance));
    for (int index = 0; index < fields; index++) {
      printer_->printf(" - %d: ", index);
      sub_.accept(instance->at(index));
      printer_->printf("\n");
    }
  }

  void visit_oddball(HeapObject* oddball) {
    print_heap_address(oddball);
    if (printer_->program() == null) {
      printer_->printf("true/false/null(%ld)", oddball->class_id()->value());
    }
    if (oddball == printer_->program()->true_object()) {
      printer_->printf("true");
    } else if (oddball == printer_->program()->false_object()) {
      printer_->printf("false");
    } else if (oddball == printer_->program()->null_object()) {
      printer_->printf("null");
    }
  }

  void visit_double(Double* value) {
    printer_->printf("double %lf\n", value->value());
  }

  void visit_large_integer(LargeInteger* large_integer) {
    printer_->printf("large integer %lldL\n", large_integer->value());
  }

  void visit_task(Task* value) {
    printer_->printf("a Task\n");
    visit_instance(value);
  }

 private:
  Printer* printer_;
  ShortPrintVisitor sub_;
};

void print_object(Printer* printer, Object* object) {
  LongPrintVisitor p(printer);
  p.accept(object);
}

void print_object_short(Printer* printer, Object* object, bool is_top_level) {
  ShortPrintVisitor p(printer, is_top_level);
  p.accept(object);
}

void Printer::print_buffer(const uint8_t* s, int len) {
  const int BUF_LEN = 16;
  char buf[BUF_LEN];
  for (int i = 0; i < len; ) {
    unsigned chunk = Utils::min(len - i, BUF_LEN - 1);
    memcpy(buf, s + i, chunk);
    buf[chunk] = '\0';
    if (strlen(buf) == chunk) {
      printf("%s", buf);
    } else {
      // Slow version can handle null characters.
      for (unsigned j = 0; j < chunk; j++) {
        printf("%c", buf[j]);
      }
    }
    i += chunk;
  }
}

// When we overwrite part of the output with dots, we need to remove any
// partial UTF-8 character sequences so it's still a valid UTF-8 sequence.
static void zap_utf8_forwards(char* from, char* limit) {
  for (char* p = from; p < limit; p++) {
    if ((*p & 0x80) == 0) return;
    if ((*p & 0xc0) == 0xc0) return;
    *p = '.';
  }
}

static void zap_utf8_backwards(char* from, char* limit) {
  for (char* p = from - 1; p >= limit; p--) {
    char c = *p;
    if ((c & 0x80) == 0) return;
    *p = '.';
    if ((c & 0xc0) == 0xc0) return;
  }
}

void BufferPrinter::printf(const char* format, ...) {
  va_list ap;
  va_start(ap, format);
  int chars = vsnprintf(ptr_, remaining_, format, ap);
  va_end(ap);

  // If the buffer overflows, then cut out the middle.  We do this by putting
  // elision dots in the middle and moving the end backwards.  Note that if
  // there are n bytes and vsnprintf returns n, then that's an overflow because
  // there was no space for the terminating null, and in this case nothing was
  // written.
  if (chars >= remaining_) {
    char* middle = buffer_ + (buffer_len_ >> 1);
    const char* dots = "...\n...";
    const int dots_len = strlen(dots);
    memcpy(middle, dots, dots_len);
    zap_utf8_forwards(middle + dots_len, buffer_ + buffer_len_);
    zap_utf8_backwards(middle, buffer_);
    char* dots_end = middle + dots_len;
    if (ptr_ < dots_end) {
      // We were less than half way through the buffer, but a single printf
      // caused an overflow.
      ptr_ = dots_end;
      remaining_ = buffer_ + buffer_len_ - ptr_;
      chars = 0;
    } else {
      // There was some data after the elision dots.
      int quarter = buffer_len_ >> 2;
      if (ptr_ < dots_end + quarter) {
        // We were less than three quarters through the buffer, but a single
        // printf caused an overflow.  Remove everything after the dots.
        ptr_ = dots_end;
        remaining_ = buffer_ + buffer_len_ - ptr_;
      } else {
        // We were more than three quarters through the buffer when we
        // overflowed. Copy the excess after the three quarters mark back to
        // the halfway mark.
        int copy = ptr_ - (dots_end + quarter);
        ASSERT(dots_end + quarter + copy <= buffer_ + buffer_len_);
        memcpy(dots_end, dots_end + quarter, copy);
        ptr_ -= quarter;
        remaining_ += quarter;
      }
      // Retry the printf.
      ASSERT(ptr_ + remaining_ == buffer_ + buffer_len_);
      va_list ap2;
      va_start(ap2, format);
      chars = vsnprintf(ptr_, remaining_, format, ap2);
      va_end(ap2);
      if (chars > remaining_) {
        // We overflowed again.
        const char* end_dots = "...\n";
        const int end_dots_length = strlen(end_dots);
        char* dots_start = buffer_ + buffer_len_ - end_dots_length;
        memcpy(dots_start, end_dots, end_dots_length);
        zap_utf8_backwards(dots_start, buffer_);
        chars = remaining_;
      }
    }
  }
  remaining_ -= chars;
  ptr_ += chars;
  ASSERT(ptr_ + remaining_ == buffer_ + buffer_len_);
  ASSERT(ptr_ >= buffer_ && remaining_ >= 0);
}

#endif

}
