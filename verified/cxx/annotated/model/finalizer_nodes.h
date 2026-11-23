// Copyright (C) 2026 Toit contributors.
#ifndef TOIT_VF_FINALIZER_NODES_H
#define TOIT_VF_FINALIZER_NODES_H

#include "objects.gen.h"
#include "finalizer_fifo.h"

// Logical fields shared by the registration and receive proofs. Native links
// are base subobjects, with layout checked separately in the C++ harness.
typedef struct FinalizerNode {
  struct FinalizerNode *next_;
  HeapObject *key_;
  ObjectHeap *heap_;
  Object *lambda_;
} FinalizerNode;
typedef FinalizerNode CallableFinalizerNode;
typedef CallableFinalizerNode WeakMapFinalizerNode;
typedef CallableFinalizerNode ToitFinalizerNode;
typedef struct FinalizerNodeFifo { FinalizerNode anchor_; FinalizerNode *tail_; } FinalizerNodeFifo;
struct ObjectHeap {
  FinalizerNodeFifo runnable_finalizers_;
  FinalizerNodeFifo registered_callback_finalizers_;
  Program *program_;
};

/*@
inductive registration = registration(void *key, void *callback, bool weak);

predicate fresh_link(FinalizerNode *n) = pointer_(&n->next_, _);
predicate unlinked(FinalizerNode *n;) = n->next_ |-> 0;
predicate callback_kind(FinalizerNode *n; bool weak);
predicate callback_fields(FinalizerNode *n; void *key, void *callback, ObjectHeap *owner) =
  n->key_ |-> key &*& n->heap_ |-> owner &*& n->lambda_ |-> callback &*& unlinked(n);

// The chain owns each node's link, payload and dynamic type. An empty
// chain uses null as its logical tail; the native FIFO uses its anchor.
predicate callback_chain(FinalizerNode *first, ObjectHeap *owner; FinalizerNode *last, list<registration> entries) =
  first == 0 ? last == 0 &*& entries == nil :
    first->next_ |-> ?next &*& first->key_ |-> ?key &*& first->heap_ |-> owner &*&
    first->lambda_ |-> ?callback &*& callback_kind(first, ?weak) &*&
    callback_chain(next, owner, ?rest_last, ?rest) &*&
    last == (next == 0 ? first : rest_last) &*& entries == cons(registration(key, callback, weak), rest);

lemma void empty_callback_chain(ObjectHeap *owner)
  requires callback_chain(0, owner, ?last, ?entries);
  ensures callback_chain(0, owner, last, entries) &*& entries == nil &*& last == 0;
{
  open callback_chain(0, owner, last, entries);
  close callback_chain(0, owner, last, entries);
}

predicate registered_callbacks(ObjectHeap *owner; list<registration> entries) =
  owner->registered_callback_finalizers_.anchor_.next_ |-> ?head &*&
  owner->registered_callback_finalizers_.tail_ |-> ?tail &*& callback_chain(head, owner, ?last, entries) &*&
  tail == (head == 0 ? &owner->registered_callback_finalizers_.anchor_ : last);
@*/

// Native delete dispatches to the destructor and releases the detached node.
void FinalizerNode_delete(FinalizerNode *node);
//@ requires callback_fields(node, ?key, ?closure, ?owner) &*& callback_kind(node, ?weak);
//@ ensures true;

static inline void FinalizerNodeFifo_prepend(FinalizerNodeFifo *q, FinalizerNode *n)
/*@ requires callback_fields(n, ?key, ?callback, ?owner) &*& callback_kind(n, ?weak) &*&
             n != 0 &*& q == &owner->registered_callback_finalizers_ &*& registered_callbacks(owner, ?entries); @*/
//@ ensures registered_callbacks(owner, cons(registration(key, callback, weak), entries));
{
  //@ open callback_fields(n, key, callback, owner);
  //@ open unlinked(n);
  //@ open registered_callbacks(owner, entries);
  callback_prepend_links((void **)&q->anchor_.next_, (void **)&q->tail_, (void **)&n->next_, n);
  //@ close callback_chain(n, owner, _, cons(registration(key, callback, weak), entries));
  //@ close registered_callbacks(owner, cons(registration(key, callback, weak), entries));
}

#endif
