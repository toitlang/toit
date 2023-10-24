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
  FinalizerNode(Object* key, ObjectHeap* heap) : key_(key), heap_(heap) {}
  virtual ~FinalizerNode();

  // Called at the end of compaction and at other times where all pointers
  // should be visited with no weakness/finalization processing.
  virtual void roots_do(RootCallback* cb) = 0;
  // Cleanup when a heap is deleted.
  virtual void heap_dying() {}
  // Should return true if the node should be unlinked.
  virtual bool weak_processing(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle) = 0;

 protected:
  Object* key_;
  ObjectHeap* heap_;
};

class CallableFinalizerNode : public FinalizerNode {
 public:
  CallableFinalizerNode(Object* key, Object* lambda, ObjectHeap* heap)
    : FinalizerNode(key, heap), lambda_(lambda) {}

  Object* lambda() { return lambda_; }

 protected:
  Object* lambda_;
};

typedef LinkedFifo<CallableFinalizerNode> CallableFinalizerNodeFifo;

class WeakMapFinalizerNode: public CallableFinalizerNode {
 public:
  WeakMapFinalizerNode(Instance* map, Object* lambda, ObjectHeap* heap)
    : CallableFinalizerNode(map, lambda, heap) {}

  virtual void roots_do(RootCallback* cb);
  virtual bool weak_processing(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle);

 private:
  Instance* map() { return Instance::cast(key_); }
};

class ToitFinalizerNode : public CallableFinalizerNode {
 public:
  ToitFinalizerNode(Instance* map, Object* lambda, ObjectHeap* heap)
    : CallableFinalizerNode(map, lambda, heap) {}

  virtual void roots_do(RootCallback* cb);
  virtual bool weak_processing(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle);

 private:
  HeapObject* key() { return HeapObject::cast(key_); }
};

class VmFinalizerNode : public FinalizerNode {
 public:
  VmFinalizerNode(HeapObject* key, ObjectHeap* heap)
    : FinalizerNode(key, heap) {}

  virtual void roots_do(RootCallback* cb);
  virtual void heap_dying() { free_external_memory(); }
  virtual bool weak_processing(bool in_closure_queue, RootCallback* visitor, LivenessOracle* oracle);

 private:
  HeapObject* key() { return HeapObject::cast(key_); }
  void free_external_memory();
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
