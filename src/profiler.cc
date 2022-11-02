// Copyright (C) 2019 Toitware ApS.
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

#include "objects.h"
#include "process.h"
#include "profiler.h"
#include "encoder.h"

namespace toit {

Profiler::Profiler(int task_id) : task_id_(task_id) {
  ASSERT(!is_active());
  table_size = 1;
  offset_table = unvoid_cast<int*>(malloc(sizeof(int) * table_size));
  counter_table = unvoid_cast<int64*>(malloc(sizeof(int64) * table_size));
  if (offset_table == null || counter_table == null) {
    free(offset_table);
    free(counter_table);
    allocated_bytes_ = -1;
  } else {
    allocated_bytes_ = table_size * sizeof(int) + table_size * sizeof(int64);
    offset_table[0] = 0;
    counter_table[0] = 0;
  }
}

Profiler::~Profiler() {
  ASSERT(!is_active());
  delete[] offset_table;
  delete[] counter_table;
}

void Profiler::start() {
  is_active_ = true;
}

void Profiler::stop() {
  is_active_ = false;
}

void Profiler::print() {
  printf("Profile:\n");
  for (int index = 1; index < table_size; index++) {
    int method_id = offset_table[index];
    int64 count = counter_table[index];
    if (count > 0) printf("  %5d:%8lld\n", method_id, static_cast<long long>(count));
  }
}

void Profiler::encode_on(ProgramOrientedEncoder* encoder, String* title, int cutoff) {
  // Compute total number of counts.
  int64 total_count = 0;
  for (int index = 1; index < table_size; index++) {
    total_count += counter_table[index];
  }
  // Compute number of reported lines based on cutoff.
  const int64 cutoff_count = (int64) (((double) total_count * cutoff) / 1000.0);
  int real_entries = 0;
  for (int index = 1; index < table_size; index++) {
    if (counter_table[index] > cutoff_count) real_entries++;
  }
  // Encode the report.
  encoder->write_header(real_entries * 2 + 3, 'P');
  encoder->encode(title);
  encoder->write_int(cutoff);
  encoder->write_int(total_count);
  for (int index = 1; index < table_size; index++) {
    if (counter_table[index] > cutoff_count) {
      int method_id = offset_table[index];
      encoder->write_int(method_id);
      encoder->write_int(counter_table[index]);
    }
  }
}

void Profiler::register_method(int absolute_bci) {
  int index = compute_index_for_absolute_bci(absolute_bci);
  if (index == -1) {
    // Couldn't allocate the tables.
    ASSERT(allocated_bytes_ == -1);
    return;
  }
  if (offset_table[index] == absolute_bci) {
    // The method was already registered.
    return;
  }
  // We need to grow the tables and put the new method into it.
  int new_table_size = table_size + 1;
  word new_offset_size = sizeof(int) * new_table_size;
  word new_counter_size = sizeof(int64) * new_table_size;
  int* new_offset_table = unvoid_cast<int*>(realloc(offset_table, new_offset_size));
  int64* new_counter_table = unvoid_cast<int64*>(realloc(counter_table, new_counter_size));
  if (new_offset_table == null || new_counter_table == null) {
    // When realloc fails, it leaves the old pointer untouched.
    free(new_offset_table == null ? offset_table : new_offset_table);
    free(new_counter_table == null ? counter_table : new_counter_table);
    table_size = -1;
    offset_table = null;
    counter_table = null;
    allocated_bytes_ = -1;
  } else {
    table_size = new_table_size;
    offset_table = new_offset_table;
    counter_table = new_counter_table;
    allocated_bytes_ = new_offset_size + new_counter_size;
    // The entry at index is lower than the new method's bci.
    // Therefore, index + 1 will be the slot where we insert the new method.
    // We need to move all entries [index + 1, old-table_size[ to [index + 2, new-table_size[
    if (index != table_size - 1) {
      memmove(&offset_table[index + 2],
              &offset_table[index + 1],
              sizeof(int) * (table_size - (index + 2)));
      memmove(&new_counter_table[index + 2],
              &new_counter_table[index + 1],
              sizeof(int64) * (table_size - (index + 2)));
    }
    offset_table[index + 1] = absolute_bci;
    counter_table[index + 1] = 0;
  }
}

void Profiler::increment(int absolute_bci) {
  ASSERT(is_active());
  int index = compute_index_for_absolute_bci(absolute_bci);
  if (index == -1) {
    // Couldn't allocate the tables.
    ASSERT(allocated_bytes_ == -1);
    return;
  }
  counter_table[index]++;
}

int Profiler::compute_index_for_absolute_bci(int absolute_bci) {
  if (offset_table == null) return -1;
  if (absolute_bci >= offset_table[table_size - 1]) {
    return table_size - 1;
  }
  // Use the one-element cache.
  ASSERT(0 <= last_index && last_index < table_size - 1);
  if (offset_table[last_index] <= absolute_bci && absolute_bci < offset_table[last_index + 1]) {
    return last_index;
  }
  // Binary search to find the correct method.
  int left = 0;
  int right = table_size - 1;
  while (left < right) {
    int mid = left + (right - left) / 2;
    if (offset_table[mid] > absolute_bci) {
      right = mid;
    } else {
      left = mid;
      if (absolute_bci < offset_table[mid + 1]) break;
    }
  }
  ASSERT(offset_table[left] <= absolute_bci && absolute_bci < offset_table[left + 1]);
  last_index = left;
  return left;
}

} // namespace toit
