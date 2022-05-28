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

class ObjectNotifier;
class FinalizerNode;
class VMFinalizerNode;

typedef LinkedFIFO<FinalizerNode> FinalizerNodeFIFO;

class FinalizerNode : public FinalizerNodeFIFO::Element {
 public:
  FinalizerNode(HeapObject* key, Object* lambda)
  : _key(key), _lambda(lambda) {}
  virtual ~FinalizerNode() {}

  HeapObject* key() { return _key; }
  void set_key(HeapObject* value) { _key = value; }
  Object* lambda() { return _lambda; }

  // Garbage collection support.
  void roots_do(RootCallback* cb);

 private:
  HeapObject* _key;
  Object* _lambda;
};

typedef LinkedFIFO<VMFinalizerNode> VMFinalizerNodeFIFO;

class VMFinalizerNode : public VMFinalizerNodeFIFO::Element {
 public:
  VMFinalizerNode(HeapObject* key)
  : _key(key) {}
  virtual ~VMFinalizerNode() {}

  HeapObject* key() { return _key; }
  void set_key(HeapObject* value) { _key = value; }

  // Garbage collection support.
  void roots_do(RootCallback* cb);

  void free_external_memory(Process* process);

 private:
  HeapObject* _key;
};

typedef DoubleLinkedList<ObjectNotifier> ObjectNotifierList;

class ObjectNotifier : public ObjectNotifierList::Element {
 public:
  ObjectNotifier(Process* process, Object* object);
  ~ObjectNotifier();

  Process* process() const { return _process; }
  ObjectNotifyMessage* message() const { return _message; }
  Object* object() const { return _object; }

  void set_message(ObjectNotifyMessage* message) {
    _message = message;
  }

  void update_object(Object* object) {
    _object = object;
  }

 private:
  Process* _process;

  // Object to notify.
  Object* _object;

  ObjectNotifyMessage* _message;

  // Garbage collection support.
  void roots_do(RootCallback* cb);

  friend class ObjectHeap;
};

class HeapRoot;
typedef DoubleLinkedList<HeapRoot> HeapRootList;
class HeapRoot : public HeapRootList::Element {
 public:
  explicit HeapRoot(Object* obj) : _obj(obj) {}

  Object* operator*() const { return _obj; }
  Object* operator->() const { return _obj; }
  void operator=(Object* obj) { _obj = obj; }

  Object** slot() { return &_obj; }
  void unlink() { HeapRootList::Element::unlink(); }

 private:
  Object* _obj;
};

}  // namespace.
