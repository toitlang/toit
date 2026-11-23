// Copyright (C) 2026 Toit contributors.
#ifndef TOIT_VF_FINALIZER_FIFO_H
#define TOIT_VF_FINALIZER_FIFO_H

// The template operates on links, which need not have the same address
// as the most-derived C++ object. ESBMC compares these operations with
// the native link constructor and the FIFO head operations.
static inline bool callback_queue_empty(void *first)
//@ requires true;
//@ ensures result == (first == 0);
{
  return first == 0;
}

static inline void callback_init_link(void **next)
//@ requires pointer_(next, _);
//@ ensures pointer(next, 0);
{
  *next = 0;
}

static inline void callback_prepend_links(void **head, void **tail, void **next, void *node)
//@ requires pointer(head, ?first) &*& pointer(tail, ?last) &*& pointer(next, 0);
//@ ensures pointer(head, node) &*& pointer(tail, first == 0 ? node : last) &*& pointer(next, first);
{
  if (*head == 0) *tail = node;
  *next = *head;
  *head = node;
}
// Detach the known nonempty head. The caller selects the link field of
// the first node and supplies the anchor to restore the empty tail.
static inline void callback_detach_first(void **head, void **tail, void **next, void *anchor)
//@ requires pointer(head, ?first) &*& pointer(tail, ?last) &*& pointer(next, ?second);
//@ ensures pointer(head, second) &*& pointer(tail, second == 0 ? anchor : last) &*& pointer(next, 0);
{
  *head = *next;
  *next = 0;
  if (*head == 0) *tail = anchor;
}
#endif
