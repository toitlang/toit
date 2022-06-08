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

#include "interpreter.h"
#include "process.h"
#include "objects_inline.h"

#include <cmath> // isnan, isinf

namespace toit {

// Perform a fast at. Return whether the fast at was performed. The return
// value is in the value parameter.
bool Interpreter::fast_at(Process* process, Object* receiver, Object* arg, bool is_put, Object** value) {
  if (!is_smi(arg)) return false;

  word n = Smi::cast(arg)->value();
  if (n < 0) return false;

  ByteArray* byte_array = null;
  Array* array = null;
  word length = 0;

  if (is_instance(receiver)) {
    Instance* instance = Instance::cast(receiver);
    Smi* class_id = instance->class_id();
    Program* program = process->program();
    Object* array_object;
    // Note: Assignment in condition.
    if (class_id == program->list_class_id() && is_array(array_object = instance->at(0))) {
      // The backing storage in a list can be either an array -- or a
      // large array. Only optimize here if it isn't large.
      array = Array::cast(array_object);
      length = Smi::cast(instance->at(1))->value();
    } else if (class_id == program->byte_array_slice_class_id()) {
      if (!(is_smi(instance->at(1)) && is_smi(instance->at(2)))) return false;

      word from = Smi::cast(instance->at(1))->value();
      word to = Smi::cast(instance->at(2))->value();
      n = from + n;
      if (n >= to) return false;

      Object* data = instance->at(0);
      if (is_byte_array(data)) {
        byte_array = ByteArray::cast(instance->at(0));
      } else if (is_instance(data)) {
        Instance* data_instance = Instance::cast(data);
        if (data_instance->class_id() != program->byte_array_cow_class_id() ||
            (is_put && data_instance->at(1) == program->false_object())) {
          return false;
        }
        byte_array = ByteArray::cast(data_instance->at(0));
      } else {
        return false;
      }
    } else if (class_id == program->large_array_class_id() || class_id == program->list_class_id()) {
      Object* size_object;
      Object* vector_object;
      if (class_id == program->large_array_class_id()) {
        size_object = instance->at(0);
        vector_object = instance->at(1);
      } else {
        // List backed by large array.
        size_object = instance->at(1);
        Instance* large_array = Instance::cast(instance->at(0));
        ASSERT(large_array->class_id() == program->large_array_class_id());
        vector_object = large_array->at(1);
      }
      word size;
      if (is_smi(size_object)) {
        size = Smi::cast(size_object)->value();
      } else {
        return false;
      }
      if (n >= size) return false;
      Object* arraylet;
      if (!fast_at(process, vector_object, Smi::from(n / Array::ARRAYLET_SIZE), /* is_put = */ false, &arraylet)) {
        return false;
      }
      return fast_at(process, arraylet, Smi::from(n % Array::ARRAYLET_SIZE), is_put, value);
    } else if (class_id == program->byte_array_cow_class_id()) {
      if (is_put && instance->at(1) == program->false_object()) return false;
      byte_array = ByteArray::cast(instance->at(0));
    } else {
      return false;
    }
  } else if (is_byte_array(receiver)) {
    byte_array = ByteArray::cast(receiver);
  } else if (is_array(receiver)) {
    array = Array::cast(receiver);
    length = array->length();
  } else {
    return false;
  }

  if (array != null) {
    if (n >= length) return false;

    if (is_put) {
      array->at_put(n, *value);
      return true;
    } else {
      (*value) = array->at(n);
      return true;
    }
  } else if (byte_array != null &&
       (!byte_array->has_external_address() ||
        byte_array->external_tag() == RawByteTag ||
        (!is_put && byte_array->external_tag() == MappedFileTag))) {
    ByteArray::Bytes bytes(byte_array);
    if (!bytes.is_valid_index(n)) return false;

    if (is_put) {
      if (!is_smi(*value)) return false;

      uint8 byte_value = (uint8) Smi::cast(*value)->value();
      bytes.at_put(n, byte_value);
      (*value) = Smi::from(byte_value);
      return true;
    } else {
      (*value) = Smi::from(bytes.at(n));
      return true;
    }
  }
  return false;
}

int Interpreter::compare_numbers(Object* lhs, Object* rhs) {
  int64 lhs_int = 0;
  int64 rhs_int = 0;
  bool lhs_is_int;
  bool rhs_is_int;
  if (is_smi(lhs)) {
    lhs_is_int = true;
    lhs_int = Smi::cast(lhs)->value();
  } else if (is_large_integer(lhs)) {
    lhs_is_int = true;
    lhs_int = LargeInteger::cast(lhs)->value();
  } else {
    lhs_is_int = false;
  }
  if (is_smi(rhs)) {
    rhs_is_int = true;
    rhs_int = Smi::cast(rhs)->value();
  } else if (is_large_integer(rhs)) {
    rhs_is_int = true;
    rhs_int = LargeInteger::cast(rhs)->value();
  } else {
    rhs_is_int = false;
  }
  // Handle two ints.
  if (lhs_is_int && rhs_is_int) {
    if (lhs_int < rhs_int) {
      return COMPARE_RESULT_MINUS_1 | COMPARE_FLAG_STRICTLY_LESS | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_LESS_FOR_MIN;
    } else if (lhs_int == rhs_int) {
      return COMPARE_RESULT_ZERO | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_EQUAL | COMPARE_FLAG_GREATER_EQUAL;
    } else {
      return COMPARE_RESULT_PLUS_1 | COMPARE_FLAG_STRICTLY_GREATER | COMPARE_FLAG_GREATER_EQUAL;
    }
  }
  // At least one is a double, so we convert to double.
  double lhs_double;
  double rhs_double;
  if (lhs_is_int) {
    lhs_double = static_cast<double>(lhs_int);
  } else if (is_double(lhs)) {
    lhs_double = Double::cast(lhs)->value();
  } else {
    return COMPARE_FAILED;
  }
  if (rhs_is_int) {
    rhs_double = static_cast<double>(rhs_int);
  } else if (is_double(rhs)) {
    rhs_double = Double::cast(rhs)->value();
  } else {
    return COMPARE_FAILED;
  }
  // Handle any NaNs.
  if (std::isnan(lhs_double)) {
    if (std::isnan(rhs_double)) {
      return COMPARE_RESULT_ZERO | COMPARE_FLAG_LESS_FOR_MIN;
    }
    return COMPARE_RESULT_PLUS_1 | COMPARE_FLAG_LESS_FOR_MIN;
  }
  if (std::isnan(rhs_double)) {
    return COMPARE_RESULT_MINUS_1;
  }
  // Handle equal case.
  if (lhs_double == rhs_double) {
    // Special treatment for plus/minus zero.
    if (lhs_double == 0.0) {
      if (std::signbit(lhs_double) == std::signbit(rhs_double)) {
        return COMPARE_RESULT_ZERO | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_EQUAL | COMPARE_FLAG_GREATER_EQUAL | COMPARE_FLAG_LESS_FOR_MIN;
      } else if (std::signbit(lhs_double)) {
        return COMPARE_RESULT_MINUS_1 | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_EQUAL | COMPARE_FLAG_GREATER_EQUAL | COMPARE_FLAG_LESS_FOR_MIN;
      } else {
        return COMPARE_RESULT_PLUS_1 | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_EQUAL | COMPARE_FLAG_GREATER_EQUAL;
      }
    } else {
      return COMPARE_RESULT_ZERO | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_EQUAL | COMPARE_FLAG_GREATER_EQUAL | COMPARE_FLAG_LESS_FOR_MIN;
    }
  }
  if (lhs_double < rhs_double) {
    return COMPARE_RESULT_MINUS_1 | COMPARE_FLAG_STRICTLY_LESS | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_LESS_FOR_MIN;
  } else {
    return COMPARE_RESULT_PLUS_1 | COMPARE_FLAG_STRICTLY_GREATER | COMPARE_FLAG_GREATER_EQUAL;
  }
}

// Two ways to return:
// * Returns a negative Smi:
//     We should call the block.
//       The negative Smi indicates our progress in traversing the backing.
//       The entry_return indicates the element to pass to the block.
// * Returns another object:
//     We should return from the entire method with this value.
//       A positive Smi indicates our progress so far.
//       A null indicates we are done.
Object* Interpreter::hash_do(Program* program, Object* current, Object* backing, int step, Object* block_on_stack, Object** entry_return) {
  word c = 0;
  if (!is_smi(current)) {
    // First time.
    if (!is_instance(backing)) {
      return program->null_object();  // We are done.
    } else if (step < 0) {
      // Start at the end.
      c = Smi::cast(Instance::cast(backing)->at(1))->value() + step;
    }
    Smi* block = Smi::cast(*from_block(Smi::cast(block_on_stack)));
    Method target = Method(program->bytecodes, block->value());
    if ((step & 1) != 0) {
      ASSERT(step == 1 || step == -1);
      // Block for set should take 1 argument.
      if (target.arity() != 2) {
        return Smi::from(c);  // Bail out at this point.
      }
    } else {
      ASSERT(step == 2 || step == -2);
      // Block for map should take 1 or two arguments.
      if (!(2 <= target.arity() && target.arity() <= 3)) {
        return Smi::from(c);  // Bail out at this point.
      }
    }
  } else {
    // Subsequent entries to the bytecode.
    c = Smi::cast(current)->value();
    c += step;
  }

  static const word INVALID_TOMBSTONE = -1;
  Object* first_tombstone_object = null;
  word first_tombstone = INVALID_TOMBSTONE;
  word tombstones_skipped = 0;
  while (true) {
    Object* entry;
    // This can fail if the user makes big changes to the collection in the
    // do block.  We don't support this, but we also don't want to crash.
    // We also hit out-of-range at the end of the iteration.
    bool in_range = fast_at(_process, backing, Smi::from(c), false, &entry);
    if (!in_range) {
      return program->null_object();  // Done - success.
    }
    if (is_smi(entry) || HeapObject::cast(entry)->class_id() != program->tombstone_class_id()) {
      if (first_tombstone != INVALID_TOMBSTONE && tombstones_skipped > 10) {
        // Too many tombstones in a row.
        Object* distance = Instance::cast(first_tombstone_object)->at(0);
        word new_distance = c - first_tombstone;
        if (!is_smi(distance) || distance == Smi::from(0) || !Smi::is_valid(new_distance)) {
          // We can't overwrite the distance on a 0 instance of Tombstone_,
          // because it's the singleton instance, used many places.
          // Bail out to Toit code to fix this.
          return Smi::from(first_tombstone);  // Index to start from in Toit code.
        }
        ASSERT(!(-10 <= new_distance && new_distance <= 10));
        Instance::cast(first_tombstone_object)->at_put(0, Smi::from(new_distance));
      }
      *entry_return = entry;
      return Smi::from(-c - 1);  // Call block.
    } else {
      if (first_tombstone == INVALID_TOMBSTONE) {
        first_tombstone = c;
        first_tombstone_object = entry;
        tombstones_skipped = 0;
      } else {
        tombstones_skipped++;
      }
      Object* skip = Instance::cast(entry)->at(0);
      if (is_smi(skip)) {
        word distance = Smi::cast(skip)->value();
        if (distance != 0 && (distance ^ step) >= 0) { // If signs match.
          c += distance;
          continue;  // Skip the increment of c below.
        }
      }
    }
    c += step;
  }
}

} // namespace toit
