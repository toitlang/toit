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
  virtual ~FinalizerNode() {}
  virtual bool has_key(HeapObject* value);

  virtual void roots_do(RootCallback* cb);
  // Should return false if the node needs GC processing.
  virtual bool alive(LivenessOracle* oracle);
  // Should return null if the node should be deleted.
  virtual bool handle_not_alive(RootCallback* process_slots, ObjectHeap* heap) = 0;
};

class ToitFinalizerNode : public FinalizerNode {
 public:
  ToitFinalizerNode(HeapObject* key, Object* lambda)
  : key_(key), lambda_(lambda) {}

  HeapObject* key() { return key_; }
  void set_key(HeapObject* value) { key_ = value; }
  virtual bool has_key(HeapObject* value);
  Object* lambda() { return lambda_; }

  // Garbage collection support.
  virtual void roots_do(RootCallback* cb);
  virtual bool alive(LivenessOracle* oracle);
  virtual bool handle_not_alive(RootCallback* process_slots, ObjectHeap* heap);

 private:
  HeapObject* key_;
  Object* lambda_;
};

class VmFinalizerNode : public FinalizerNode {
 public:
  VmFinalizerNode(HeapObject* key)
  : key_(key) {}

  HeapObject* key() { return key_; }
  void set_key(HeapObject* value) { key_ = value; }
  virtual bool has_key(HeapObject* value);

  // Garbage collection support.
  virtual void roots_do(RootCallback* cb);
  virtual bool alive(LivenessOracle* oracle);
  virtual bool handle_not_alive(RootCallback* process_slots, ObjectHeap* heap);

  void free_external_memory(Process* process);

 private:
  HeapObject* key_;
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
