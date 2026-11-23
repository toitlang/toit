// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include <type_traits>
#define private public
#define protected public
#include "heap_roots.h"
#undef protected
#undef private

using namespace toit;

extern HeapRoot first_root, next_root, previous_root;
extern ObjectNotifier first_notifier, next_notifier, previous_notifier;

template <typename Node>
static void check_cursor(Node* current, Node* following) {
  using List = DoubleLinkedList<Node>;
  using Iterator = typename List::Iterator;
  static_assert(std::is_trivially_copy_constructible<Iterator>::value, "cursor copy");
  static_assert(std::is_trivially_destructible<Iterator>::value, "cursor destruction");
  List list;
  auto* anchor = &list.anchor_;
  bool empty = nondet_bool();
  bool last = nondet_bool();
  anchor->next_ = empty ? anchor : current;
  current->next_ = last ? anchor : following;
  auto cursor = list.begin();
  auto end = list.end();
  static_assert(std::is_same<decltype(cursor), Iterator>::value, "mutable begin");
  static_assert(std::is_same<decltype(end), Iterator>::value, "mutable end");
  CXXV_ASSERT(end.entry_ == anchor && (cursor != end) == !empty, "stop at this list's anchor");
  if (empty) return;
  CXXV_ASSERT(*cursor == current, "dereference yields the containing root");
  auto copy = cursor;
  ++cursor;
  CXXV_ASSERT(*copy == current && (cursor != end) == !last, "advance one link and preserve copies");
  if (!last) CXXV_ASSERT(*cursor == following, "advance yields the successor's containing root");
}

// Only the anchor and its old head are touched when a root is registered.
template <typename Node>
static void check_registration(Node* added, Node* old_head) {
  using List = DoubleLinkedList<Node>;
  using Element = typename List::Element;
  List list;
  auto* anchor = &list.anchor_;
  Element* head = nondet_bool() ? anchor : static_cast<Element*>(old_head);
  anchor->next_ = head;
  head->prev_ = anchor;
  added->next_ = added->prev_ = added;
  list.prepend(added);
  CXXV_ASSERT(anchor->next_ == added && added->prev_ == anchor &&
              added->next_ == head && head->prev_ == added, "registration inserts at the head");
  list.unlink(added);
  CXXV_ASSERT(anchor->next_ == head && head->prev_ == anchor &&
              added->is_not_linked() && added->prev_ == added, "unregistration restores both neighbors");
}

// A registered root can be removed from any position. Its neighbors coincide
// only when both are the anchor of a singleton list.
template <typename Node>
static void check_removal(Node* removed, Node* previous, Node* following) {
  DoubleLinkedList<Node> list;
  auto* anchor = &list.anchor_;
  auto* left = nondet_bool() ? anchor : previous;
  auto* right = nondet_bool() ? anchor : following;
  removed->prev_ = left;
  removed->next_ = right;
  left->next_ = right->prev_ = removed;
  auto* outer_left = left->prev_;
  auto* outer_right = right->next_;

  list.unlink(removed);
  CXXV_ASSERT(left->next_ == right && right->prev_ == left, "unlink joins the adjacent nodes");
  CXXV_ASSERT(removed->next_ == removed && removed->prev_ == removed, "both removed links are detached");
  if (left != right) {
    CXXV_ASSERT(left->prev_ == outer_left && right->next_ == outer_right, "retain the outward links");
  }
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  check_registration(&first_root, &next_root);
  check_registration(&first_notifier, &next_notifier);
  check_removal(&first_root, &previous_root, &next_root);
  check_removal(&first_notifier, &previous_notifier, &next_notifier);
  check_cursor(&first_root, &next_root);
  check_cursor(&first_notifier, &next_notifier);
}
