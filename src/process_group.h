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

#include "linked.h"
#include "process.h"
#include "top.h"

namespace toit {

class ProcessGroup;

// The scheduler has a linked list of groups, manipulated under the
// scheduler lock.
typedef DoubleLinkedList<ProcessGroup> ProcessGroupList;

class ProcessGroup : public ProcessGroupList::Element {
 public:
  ~ProcessGroup();

  static ProcessGroup* create(int id, Program* program, AlignedMemoryBase* memory = null);

  int id() const { return id_; }
  Program* program() const { return program_; }

  Process* lookup(int process_id);
  void add(Process* process);

  // Remove the given process from this group. Returns true
  // if there are more processes left in the group.
  bool remove(Process* process);

  ProcessListFromProcessGroup& processes() { return processes_; }

  // The id of the image the processes in the group run, if it isn't the id
  // of the program. Programs that are combined with the system program run
  // in containers with ids of their own.
  const uint8* image_id() const { return has_image_id_ ? image_id_ : null; }
  void set_image_id(const uint8* id) {
    memcpy(image_id_, id, sizeof(image_id_));
    has_image_id_ = true;
  }

  // Whether the processes in the group have assets of their own, instead of
  // the assets of the program. Programs that are combined with the system
  // program run in groups of their own with their own assets, which may be
  // empty.
  bool has_own_assets() const { return has_own_assets_; }
  const uint8* assets() const { return assets_; }
  word assets_size() const { return assets_size_; }
  // Takes over the malloc'ed assets, which may be null if they are empty.
  void set_assets(uint8* assets, word size) {
    free(assets_);
    assets_ = assets;
    assets_size_ = size;
    has_own_assets_ = true;
  }

 private:
  const int id_;
  Program* const program_;

  // If the process groups owns memory, it is automatically deleted
  // when the process group goes away.
  AlignedMemoryBase* const memory_;

  ProcessListFromProcessGroup processes_;

  bool has_image_id_ = false;
  uint8 image_id_[16];
  bool has_own_assets_ = false;
  uint8* assets_ = null;
  word assets_size_ = 0;

  ProcessGroup(int id, Program* program, AlignedMemoryBase* memory);

  friend class Scheduler;
};

} // namespace toit
