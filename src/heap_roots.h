// Copyright (C) 2022 Toitware ApS.
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
#include "objects.h"

namespace toit {

class FinalizerNode;
class Heap;
class LivenessOracle;
class ObjectNotifier;
class ToitFinalizerNode;
class VmFinalizerNode;

typedef LinkedFifo<FinalizerNode> FinalizerNodeFifo;

class FinalizerNode : public FinalizerNodeFifo::Element {
 public:
  virtual ~FinalizerNode();

  // Called at the end of compaction and at other times where all pointers
  // should be visited with no weakness/finalization processing.
  virtual void roots_do(RootCallback* cb) = 0;
  // Cleanup when a heap is deleted.
  virtual bool heap_dying() {}
  // Should return true if the node should be unlinked.
  virtual bool process(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle) = 0;
};

class WeakMapFinalizerNode: public FinalizerNode {
 public:
  WeakMapFinalizerNode(Instance* map, HeapObject* value, ObjectHeap* heap)
    : key_(key), value_(value), heap_(heap) {}

  virtual void roots_do(RootCallback* cb) = 0;
  virtual bool process(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle) = 0;
};

class ToitFinalizerNode : public FinalizerNode {
 public:
  ToitFinalizerNode(HeapObject* key, Object* lambda, ObjectHeap* heap)
    : key_(key), lambda_(lambda), heap_(heap) {}

  HeapObject* key() { return key_; }
  Object* lambda() { return lambda_; }

  virtual void roots_do(RootCallback* cb) = 0;
  virtual bool process(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle) = 0;

 private:
  HeapObject* key_;
  Object* lambda_;
  ObjectHeap* heap_;
};

class VmFinalizerNode : public FinalizerNode {
 public:
  VmFinalizerNode(HeapObject* key, ObjectHeap* heap)
    : key_(key), heap_(heap) {}
  virtual ~VmFinalizerNode();

  virtual void roots_do(RootCallback* cb) = 0;
  virtual bool heap_dying(Process* process) { free_external_memory(process); }
  virtual bool process(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle) = 0;

 private:
  void free_external_memory(Process* process);

  HeapObject* key_;
  ObjectHeap* heap_;
};

typedef DoubleLinkedList<ObjectNotifier> ObjectNotifierList;

class ObjectNotifier : public ObjectNotifierList::Element {
 public:
  ObjectNotifier(Process* process, Object* object);
  ~ObjectNotifier();

  Process* process() const { return process_; }
  ObjectNotifyMessage* message() const { return message_; }
  Object* object() const { return object_; }

  void set_message(ObjectNotifyMessage* message) {
    message_ = message;
  }

  void update_object(Object* object) {
    object_ = object;
  }

 private:
  Process* process_;

  // Object to notify.
  Object* object_;

  ObjectNotifyMessage* message_;

  // Garbage collection support.
  void roots_do(RootCallback* cb);

  friend class ObjectHeap;
};

class HeapRoot;
typedef DoubleLinkedList<HeapRoot> HeapRootList;
class HeapRoot : public HeapRootList::Element {
 public:
  explicit HeapRoot(Object* obj) : obj_(obj) {}

  Object* operator*() const { return obj_; }
  Object* operator->() const { return obj_; }
  void operator=(Object* obj) { obj_ = obj; }

  Object** slot() { return &obj_; }
  void unlink() { HeapRootList::Element::unlink(); }

 private:
  Object* obj_;
};

}  // namespace.
