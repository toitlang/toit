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

#include "flags.h"
#include "heap_report.h"
#include "objects_inline.h"
#include "printing.h"
#include "process.h"
#include "scheduler.h"
#include "vm.h"

#include <cmath> // isnan, isinf

namespace toit {

Interpreter::Interpreter()
    : _process(null)
    , _limit(null)
    , _base(null)
    , _sp(null)
    , _try_sp(null)
    , _watermark(null)
    , _in_stack_overflow(false) {
#ifdef PROFILER
  _is_profiler_active = false;
#endif
}

void Interpreter::activate(Process* process) {
  _process = process;
}

void Interpreter::deactivate() {
  _process = null;
}

void Interpreter::preempt() {
  // TODO: Use overflow marker / signal.
  _watermark = PREEMPTION_MARKER;
}

#ifdef PROFILER
void Interpreter::profile_register_method(Method method) {
  int absolute_bci = process()->program()->absolute_bci_from_bcp(method.header_bcp());
  Profiler* profiler = process()->profiler();
  if (profiler != null) profiler->register_method(absolute_bci);
}

void Interpreter::profile_increment(uint8* bcp) {
  int absolute_bci = process()->program()->absolute_bci_from_bcp(bcp);
  Profiler* profiler = process()->profiler();
  if (profiler != null) profiler->increment(absolute_bci);
}
#endif

Method Interpreter::_lookup_entry() {
  Method result = _process->entry();
  if (!result.is_valid()) FATAL("Cannot locate entry method for interpreter");
  return result;
}

Object** Interpreter::load_stack() {
  Stack* stack = _process->task()->stack();
  stack->transfer_to_interpreter(this);
#ifdef PROFILER
  set_profiler_state();
#endif
  Object** watermark = _watermark;
  Object** new_watermark = _in_stack_overflow ? _limit : _limit + Stack::OVERFLOW_HEADROOM;
  while (true) {
    // Updates watermark unless preemption marker is set (will be set after preemption).
    if (watermark == PREEMPTION_MARKER) break;
    if (_watermark.compare_exchange_strong(watermark, new_watermark)) break;
  }
  return _sp;
}

void Interpreter::store_stack(Object** sp) {
  if (sp != null) _sp = sp;
  Stack* stack = _process->task()->stack();
  stack->transfer_from_interpreter(this);
  _limit = null;
  _base = null;
  _sp = null;

  Object** watermark = _watermark;
  while (true) {
    if (watermark == PREEMPTION_MARKER) break;
    if (_watermark.compare_exchange_strong(watermark, null)) break;
  }
}

void Interpreter::reset_stack_limit() {
  _in_stack_overflow = false;
  store_stack(null);
  load_stack();
}

// Perform a fast at. Return whether the fast at was performed. The return
// value is in the value parameter.
bool Interpreter::fast_at(Process* process, Object* receiver, Object* arg, bool is_put, Object** value) {
  if (!arg->is_smi()) return false;

  word n = Smi::cast(arg)->value();
  if (n < 0) return false;

  ByteArray* byte_array = null;
  Array* array = null;
  word length = 0;

  if (receiver->is_instance()) {
    Instance* instance = Instance::cast(receiver);
    Smi* class_id = instance->class_id();
    Program* program = process->program();
    Object* array_object;
    // Note: Assignment in condition.
    if (class_id == program->list_class_id() && (array_object = instance->at(0))->is_array()) {
      // The backing storage in a list can be either an array -- or a
      // large array. Only optimize here if it isn't large.
      array = Array::cast(array_object);
      length = Smi::cast(instance->at(1))->value();
    } else if (class_id == program->byte_array_slice_class_id()) {
      if (!(instance->at(1)->is_smi() && instance->at(2)->is_smi())) return false;

      word from = Smi::cast(instance->at(1))->value();
      word to = Smi::cast(instance->at(2))->value();
      n = from + n;
      if (n >= to) return false;

      Object* data = instance->at(0);
      if (data->is_byte_array()) {
        byte_array = ByteArray::cast(instance->at(0));
      } else if (data->is_instance()) {
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
      if (size_object->is_smi()) {
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
  } else if (receiver->is_byte_array()) {
    byte_array = ByteArray::cast(receiver);
  } else if (receiver->is_array()) {
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
      if (!(*value)->is_smi()) return false;

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
  if (!current->is_smi()) {
    // First time.
    if (!backing->is_instance()) {
      return program->null_object();  // We are done.
    } else if (step < 0) {
      // Start at the end.
      c = Smi::cast(Instance::cast(backing)->at(1))->value() + step;
    }
    Smi* block = Smi::cast(*_from_block(Smi::cast(block_on_stack)));
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
    if (entry->is_smi() || HeapObject::cast(entry)->class_id() != program->tombstone_class_id()) {
      if (first_tombstone != INVALID_TOMBSTONE && tombstones_skipped > 10) {
        // Too many tombstones in a row.
        Object* distance = Instance::cast(first_tombstone_object)->at(0);
        word new_distance = c - first_tombstone;
        if (!distance->is_smi() || distance == Smi::from(0) || !Smi::is_valid(new_distance)) {
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
      if (skip->is_smi()) {
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

#ifdef PROFILER
void Interpreter::set_profiler_state() {
  Profiler* profiler = process()->profiler();
  _is_profiler_active = profiler != null && profiler->should_profile_task(process()->task()->id());
}
#endif

void Interpreter::prepare_task(Method entry, Instance* code) {
  _push(code);
  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  _push(reinterpret_cast<Object*>(entry.entry()));
  _push(_process->program()->frame_marker());

  _push(Smi::from(0));  // Argument: stack
  _push(Smi::from(0));  // Argument: value

  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  _push(reinterpret_cast<Object*>(entry.bcp_from_bci(LOAD_NULL_LENGTH)));
  _push(_process->program()->frame_marker());
}

Object** Interpreter::scavenge(Object** sp, bool malloc_failed, int attempts) {
  ASSERT(attempts >= 1 && attempts <= 3);  // Allocation attempts.
  if (attempts == 3) {
    if (VM::current()->scheduler()->is_boot_process(_process)) {
      OS::out_of_memory("Out of memory in system process");
    }
    return sp;
  }
  store_stack(sp);
  VM::current()->scheduler()->scavenge(_process, malloc_failed, attempts > 1);
  return load_stack();
}

void Interpreter::prepare_process() {
  load_stack();

  Method entry = _lookup_entry();
  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  _push(reinterpret_cast<Object*>(entry.entry()));
  _push(_process->program()->frame_marker());

  static_assert(FRAME_SIZE == 2, "Unexpected frame size");
  _push(reinterpret_cast<Object*>(entry.entry()));
  _push(_process->program()->frame_marker());

  store_stack();
}

Interpreter::Result Interpreter::run() {
  return _run();
}

Object** Interpreter::check_stack_overflow(Object** sp, OverflowState* state, Method method) {
  ASSERT(*state == OVERFLOW_EXCEPTION);
  if (_watermark == PREEMPTION_MARKER) {
    if (_process->signals() & Process::WATCHDOG) {
      *state = OVERFLOW_WATCHDOG;
      return sp;
    }

    _watermark = null;
    *state = OVERFLOW_PREEMPT;
    return sp;
  }

  int length = _process->task()->stack()->length();
  if (length == Stack::max_length()) return sp;

  // The max_height doesn't include space for the frame of the next call (if there is one).
  // For simplicity just always assume that there will be a call at max-height and add `FRAME_SIZE`.
  int needed_space = method.max_height() + Interpreter::FRAME_SIZE + Stack::OVERFLOW_HEADROOM;
  int headroom = sp - _limit;
  ASSERT(headroom < needed_space);  // We shouldn't try to grow the stack otherwise.

  int new_length = Utils::max(length + (length >> 1), (length - headroom) + needed_space);
  new_length = Utils::min(Stack::max_length(), new_length);
  int new_headroom = headroom + (new_length - length);
  if (new_headroom < needed_space) return sp;  // Growing the stack will not bring us out of the red zone.
  Stack* new_stack = _process->object_heap()->allocate_stack(new_length);

  // Garbage collect up to three times.
  for (int attempts = 1; new_stack == null && attempts < 4; attempts++) {
#ifdef TOIT_FREERTOS
    if (attempts == 3) {
      printf("[gc @ %p%s | 3rd time stack allocate failure %d->%d]\n",
          _process, VM::current()->scheduler()->is_boot_process(_process) ? "*" : "",
          length, new_length);
    }
#endif
    sp = scavenge(sp, false, attempts);
    new_stack = _process->object_heap()->allocate_stack(new_length);
  }

  // Then check for out of memory.
  if (new_stack == null) {
    *state = OVERFLOW_OOM;
    return sp;
  }

  store_stack(sp);
  _process->task()->stack()->copy_to(new_stack, new_length);
  _process->task()->set_stack(new_stack);
  sp = load_stack();
  *state = OVERFLOW_RESUME;
  return sp;
}

Method Interpreter::handle_stack_overflow(OverflowState state) {
  ASSERT(!_in_stack_overflow && _watermark != _limit);  // Stack overflow shouldn't occur while handling stack overflow.
  ASSERT(state == OVERFLOW_EXCEPTION || state == OVERFLOW_OOM);
  _watermark = _limit;
  _in_stack_overflow = true;
  if (state == OVERFLOW_EXCEPTION) {
    return _process->program()->stack_overflow();
  } else {
    return _process->program()->out_of_memory();
  }
}

Method Interpreter::handle_watchdog() {
  ASSERT(!_in_stack_overflow && _watermark != _limit);  // Watchdog shouldn't occur while handling stack overflow.
  reset_stack_limit();
  _process->clear_signal(Process::WATCHDOG);
  return _process->program()->watchdog();
}

void Interpreter::_trace(uint8* bcp) {
#ifdef DEBUG
  auto program = _process->program();
  ConsolePrinter printer(program);
  printf("[%6d] ", program->absolute_bci_from_bcp(bcp));
  print_bytecode(&printer, bcp, 0);
  printf("\n");
  fflush(stdout);
#else
  UNIMPLEMENTED();
#endif
}

int Interpreter::compare_numbers(Object* lhs, Object* rhs) {
  int64 lhs_int = 0;
  int64 rhs_int = 0;
  bool lhs_is_int;
  bool rhs_is_int;
  if (lhs->is_smi()) {
    lhs_is_int = true;
    lhs_int = Smi::cast(lhs)->value();
  } else if (lhs->is_large_integer()) {
    lhs_is_int = true;
    lhs_int = LargeInteger::cast(lhs)->value();
  } else {
    lhs_is_int = false;
  }
  if (rhs->is_smi()) {
    rhs_is_int = true;
    rhs_int = Smi::cast(rhs)->value();
  } else if (rhs->is_large_integer()) {
    rhs_is_int = true;
    rhs_int = LargeInteger::cast(rhs)->value();
  } else {
    rhs_is_int = false;
  }
  // Handle two ints.
  if (lhs_is_int && rhs_is_int) {
    if (lhs_int < rhs_int) {
      return STRICTLY_LESS | COMPARE_TO_MINUS_1 | LESS_EQUAL | COMPARE_TO_LESS_FOR_MIN;
    } else if (lhs_int == rhs_int) {
      return LESS_EQUAL | EQUAL | COMPARE_TO_ZERO | GREATER_EQUAL;
    } else {
      return STRICTLY_GREATER | COMPARE_TO_PLUS_1 | GREATER_EQUAL;
    }
  }
  // At least one is a double, so we convert to double.
  double lhs_double;
  double rhs_double;
  if (lhs_is_int) {
    lhs_double = static_cast<double>(lhs_int);
  } else if (lhs->is_double()) {
    lhs_double = Double::cast(lhs)->value();
  } else {
    return COMPARISON_FAILED;
  }
  if (rhs_is_int) {
    rhs_double = static_cast<double>(rhs_int);
  } else if (rhs->is_double()) {
    rhs_double = Double::cast(rhs)->value();
  } else {
    return COMPARISON_FAILED;
  }
  // Handle any NaNs.
  if (std::isnan(lhs_double)) {
    if (std::isnan(rhs_double)) {
      return COMPARE_TO_ZERO | COMPARE_TO_LESS_FOR_MIN;
    }
    return COMPARE_TO_PLUS_1 | COMPARE_TO_LESS_FOR_MIN;
  }
  if (std::isnan(rhs_double)) {
    return COMPARE_TO_MINUS_1;
  }
  // Handle equal case.
  if (lhs_double == rhs_double) {
    // Special treatment for plus/minus zero.
    if (lhs_double == 0.0) {
      if (std::signbit(lhs_double) == std::signbit(rhs_double)) {
        return LESS_EQUAL | EQUAL | COMPARE_TO_ZERO | GREATER_EQUAL | COMPARE_TO_LESS_FOR_MIN;
      } else if (std::signbit(lhs_double)) {
        return LESS_EQUAL | EQUAL | COMPARE_TO_MINUS_1 | GREATER_EQUAL | COMPARE_TO_LESS_FOR_MIN;
      } else {
        return LESS_EQUAL | EQUAL | COMPARE_TO_PLUS_1 | GREATER_EQUAL;
      }
    } else {
      return LESS_EQUAL | EQUAL | COMPARE_TO_ZERO | GREATER_EQUAL | COMPARE_TO_LESS_FOR_MIN;
    }
  }
  if (lhs_double < rhs_double) {
    return STRICTLY_LESS | COMPARE_TO_MINUS_1 | LESS_EQUAL | COMPARE_TO_LESS_FOR_MIN;
  } else {
    return STRICTLY_GREATER | COMPARE_TO_PLUS_1 | GREATER_EQUAL;
  }
}

} // namespace toit
