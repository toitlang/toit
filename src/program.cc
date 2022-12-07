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

#include "program.h"
#include "objects_inline.h"
#include "snapshot.h"

#ifdef TOIT_CHECK_PROPAGATED_TYPES
#include "compiler/propagation/type_database.h"
#endif

namespace toit {

int Program::absolute_bci_from_bcp(uint8* bcp) const {
  return bcp - bytecodes.data();
}

#ifndef TOIT_FREERTOS

void Program::write(SnapshotWriter* st) {
  st->write_external_list_uint16(class_bits);
  // From now on, it's safe to just refer to classes by their id.
  global_variables.write(st);
  literals.write(st);

  st->write_cardinal(ROOT_COUNT);
  for (int i = 0; i < ROOT_COUNT; i++) {
    st->write_object(roots_[i]);
  }
  st->write_cardinal(BUILTIN_CLASS_IDS_COUNT);
  for (int i = 0; i < BUILTIN_CLASS_IDS_COUNT; i++) {
    st->write_object(_builtin_class_ids[i]);
  }
  st->write_cardinal(INVOKE_BYTECODE_COUNT);
  for (int i = 0; i < INVOKE_BYTECODE_COUNT; i++) {
    // The value might be one negative value -1 so we adjust it with +1 to make it a cardinal.
    st->write_cardinal(invoke_bytecode_offsets_[i] + 1);
  }
  st->write_cardinal(ENTRY_POINTS_COUNT);
  for (int i = 0; i < ENTRY_POINTS_COUNT; i++) {
    st->write_cardinal(entry_point_indexes_[i]);
  }
  st->write_external_list_uint16(class_check_ids);
  st->write_external_list_uint16(interface_check_offsets);
  st->write_external_list_int32(dispatch_table);
  st->write_external_list_uint8(bytecodes);
  // The source-mapping is not serialized into the snapshot.
}

void Program::read(SnapshotReader* st) {
  class_bits = st->read_external_list_uint16();
  st->register_class_bits(class_bits.data(), class_bits.length());
  global_variables.read(st);
  literals.read(st);

  // ROOTS table.
  int nof_roots = st->read_cardinal();
  ASSERT(nof_roots == ROOT_COUNT);
  for (int i = 0; i < ROOT_COUNT; i++) roots_[i] = st->read_object();
  // Builtin classes.
  int nof_builtin_classes = st->read_cardinal();
  ASSERT(nof_builtin_classes == BUILTIN_CLASS_IDS_COUNT);
  for (int i = 0; i < BUILTIN_CLASS_IDS_COUNT; i++) _builtin_class_ids[i] = Smi::cast(st->read_object());
  // INVOKE_BYTECODE_COUNT table.
  int nof_invoke_bytecodes = st->read_cardinal();
  ASSERT(nof_invoke_bytecodes == INVOKE_BYTECODE_COUNT);
  for (int i = 0; i < INVOKE_BYTECODE_COUNT; i++) {
    // The read value must be readjusted with -1.
    invoke_bytecode_offsets_[i] = st->read_cardinal() - 1;
  }
  // ENTRY_POINTS_COUNT table.
  int nof_entry_points = st->read_cardinal();
  ASSERT(nof_entry_points == ENTRY_POINTS_COUNT);
  for (int i = 0; i < ENTRY_POINTS_COUNT; i++) {
    entry_point_indexes_[i] = st->read_cardinal();
  }
  class_check_ids = st->read_external_list_uint16();
  interface_check_offsets = st->read_external_list_uint16();
  dispatch_table = st->read_external_list_int32();
  bytecodes = st->read_external_list_uint8();
  ASSERT(st->eos());
  // The source-mapping was not serialized into the snapshot and is therefore
  // kept as `null`.
}

#endif  // TOIT_FREERTOS

void Program::do_roots(RootCallback* callback) {
  callback->do_roots(roots_, ROOT_COUNT);
  global_variables.do_roots(callback);
  literals.do_roots(callback);
}

ProgramUsage Program::usage() {
  ProgramUsage total("program", sizeof(Program));
  total.add_external(tables_size());
  ProgramUsage h = heap_.usage("program object heap");
  total.add(&h);
  total.add_external(4 + dispatch_table.length() * 4);  // Length + dispatch entries.
  total.add_external(4 + bytecodes.length());  // Length + bytecodes.
  return total;
}

int Program::number_of_unused_dispatch_table_entries() {
  int count = 0;
  for (int i = 0; i < dispatch_table.length(); i++) {
    if (dispatch_table[i] == -1) count++;
  }
  return count;
}

Program::Program(void* program_heap_address, uword program_heap_size)
    : invoke_bytecode_offsets_()
    , roots_()
    , entry_point_indexes_()
    , source_mapping_(null)
    , program_heap_address_(reinterpret_cast<uword>(program_heap_address))
    , program_heap_size_(program_heap_size) {}

Program::~Program() {
#ifdef TOIT_CHECK_PROPAGATED_TYPES
  delete propagated_types_;
#endif
}

void Program::do_pointers(PointerCallback* callback) {
  global_variables.do_pointers(callback);
  literals.do_pointers(callback);

  callback->object_table(roots_, ROOT_COUNT);
  callback->c_address(reinterpret_cast<void**>(&roots_));
  callback->c_address(reinterpret_cast<void**>(&dispatch_table.data()));
  callback->c_address(reinterpret_cast<void**>(&bytecodes.data()));
  callback->c_address(reinterpret_cast<void**>(&class_check_ids.data()));
  callback->c_address(reinterpret_cast<void**>(&interface_check_offsets.data()));
  callback->c_address(reinterpret_cast<void**>(&class_bits.data()));
  callback->c_address(reinterpret_cast<void**>(&program_heap_address_));
  if (!program_heap_address_) *((char*)program_heap_address_) = 0;

  heap_.do_pointers(this, callback);
}

#ifdef TOIT_CHECK_PROPAGATED_TYPES
compiler::TypeDatabase* Program::propagated_types() {
  compiler::TypeDatabase* types = propagated_types_;
  if (types) return types;
  uint64 start = OS::get_monotonic_time();
  AllowThrowingNew allow;
  types = compiler::TypeDatabase::compute(this);
  propagated_types_ = types;
  uint64 elapsed = OS::get_monotonic_time() - start;
  printf("[propagating types through program %p => %lld ms]\n", this, elapsed / 1000);
  return types;
}
#endif

}  // namespace toit
