// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "../annotated/model/finalizer_fifo.h"
#define private public
#define protected public
#include "heap_roots.h"
#undef protected
#undef private

using namespace toit;

extern Instance* arbitrary_key();
extern Object* arbitrary_callback();
extern ObjectHeap* arbitrary_heap();

int main() {
  static_assert(sizeof(uword) * 8 == CXXV_WORD_BITS, "target word width");
  using Link = FinalizerNodeFifo::Element;
  FinalizerNodeFifo queue;
  CXXV_ASSERT(queue.remove_first() == nullptr && queue.anchor_.next_ == nullptr && queue.tail_ == &queue.anchor_,
              "removing from the empty FIFO preserves the anchor");
  Instance* key = arbitrary_key();
  Object* callback = arbitrary_callback();
  ObjectHeap* heap = arbitrary_heap();
  WeakMapFinalizerNode map_node(key, callback, heap);
  ToitFinalizerNode ordinary_node(key, callback, heap);
  bool weak = nondet_bool();
  CallableFinalizerNode* node = weak ? static_cast<CallableFinalizerNode*>(&map_node) : &ordinary_node;
  Link* link = node;
  void* model_next;
  callback_init_link(&model_next);
  CXXV_ASSERT(link->next_ == model_next, "the native constructor implements the detached link contract");

  // Prepending only needs the old endpoints. Leave the interior opaque,
  // and observe one arbitrary existing link for unintended writes.
  Link witness;
  Link* next = reinterpret_cast<Link*>(nondet_ulong());
  witness.next_ = next;
  Link* first = reinterpret_cast<Link*>(nondet_ulong());
  Link* last = first == nullptr ? &queue.anchor_ : reinterpret_cast<Link*>(nondet_ulong());
  CXXV_ASSUME(last != nullptr);
  CXXV_ASSUME(first != link && last != link);
  queue.anchor_.next_ = first;
  queue.tail_ = last;
  void* model_head = first;
  void* model_tail = last;
  CXXV_ASSERT(queue.is_empty() == callback_queue_empty(model_head),
              "the runnable queue emptiness test reads exactly the head link");
  callback_prepend_links(&model_head, &model_tail, &model_next, link);
  queue.prepend(node);
  CXXV_ASSERT(queue.anchor_.next_ == model_head && queue.tail_ == model_tail && link->next_ == model_next,
              "native insertion implements the ownership proof's link updates");
  CXXV_ASSERT(queue.anchor_.next_ == link, "the queue starts at the new link");
  CXXV_ASSERT(link->next_ == first, "the new link points to the original head");
  CXXV_ASSERT(queue.tail_ == (first == nullptr ? link : last), "the tail changes only on the first insertion");
  CXXV_ASSERT(witness.next_ == next, "existing links keep their successors");
  CXXV_ASSERT(node->key() == key && node->lambda() == callback && node->heap_ == heap,
              "registration preserves the constructor arguments");
  CXXV_ASSERT(node->keep_after_callback() == weak, "the concrete callback kind supplies its lifetime");
  callback_detach_first(&model_head, &model_tail, &model_next, &queue.anchor_);
  FinalizerNode* removed = queue.remove_first();
  CXXV_ASSERT(removed == node && link->next_ == model_next && model_next == nullptr,
              "delivery detaches and returns the containing node");
  CXXV_ASSERT(queue.anchor_.next_ == model_head && queue.tail_ == model_tail && witness.next_ == next,
              "native removal implements the proof's updates for any previous suffix");
}
