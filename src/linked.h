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

#include "top.h"

template <typename T, int N>
class LinkedList;
template <typename T, int N>
class LinkedFIFO;
template <typename T, int N>
class DoubleLinkedList;
template <typename T>
class LinkedListPatcher;

template <typename T, int N = 1>
class LinkedListElement {
 public:
  LinkedListElement() : next_(null) {}

  ~LinkedListElement() {
    ASSERT(is_not_linked());
  }

 protected:
  // For asserts, a conservative assertion that the element is not linked in a
  // list (but it might be last).
  bool is_not_linked() const {
    return next_ == null;
  }

 private:
  void clear_next() {
    next_ = null;
  }

  T* container() { return static_cast<T*>(this); }
  const T* container() const { return static_cast<const T*>(this); }

  void append(LinkedListElement* entry) {
    ASSERT(next_ == null);
    next_ = entry;
  }

  LinkedListElement* unlink_next() {
    LinkedListElement* next = next_;
    next_ = next->next_;
    next->next_ = null;
    return next;
  }

  void insert_after(LinkedListElement* entry) {
    // Assert the new entry is not already linked into a list.
    ASSERT(entry->next_ == null);
    entry->next_ = next_;
    next_ = entry;
  }

  // Name makes sense on anchors.
  bool is_empty() const {
    return next_ == null;
  }

  // Name makes sense on individual elements.
  bool is_last() const {
    return next_ == null;
  }

  LinkedListElement* next() const { return next_; }

  friend class LinkedList<T, N>;
  friend class LinkedFIFO<T, N>;
  friend class LinkedListPatcher<T>;

  LinkedListElement* next_;
};

// These two linked_list_report_last_removed templates are a way to get the
// types to work when null is passed as the reporting callable.
template<typename Element, typename Reporter>
static inline void linked_list_report_last_removed(Reporter r, Element* element) {
  r(element);
}

template<typename Element>
static inline void linked_list_report_last_removed(std::nullptr_t n, Element* element) {}

// Singly linked list container that does not take ownership or attempt to
// allocate/deallocate.
// To use with your own Foo class:
//
// class Foo;
// typedef LinkedList<Foo> FooList;
// class Foo : public FooList::Element {
//   ...
// }
//
// FooList the_foos;
//
//   for (Foo* it : the_foos) {
//   }
template <typename T, int N = 1>
class LinkedList {
 public:
  typedef LinkedListElement<T, N> Element;

  class Iterator {
   public:
    explicit Iterator(LinkedListElement<T, N>* entry)
        : entry_(entry) {}

    T* operator->() {
      return entry_->container();
    }

    T* operator*() {
      return entry_->container();
    }

    bool operator==(const Iterator&other) const {
      return entry_ == other.entry_;
    }

    bool operator!=(const Iterator&other) const {
      return entry_ != other.entry_;
    }

    Iterator& operator++() {
      entry_ = entry_->next();
      return *this;
    }

   private:
    friend class LinkedList;

    LinkedListElement<T, N>* entry_;
  };

  class ConstIterator {
   public:
    explicit ConstIterator(const LinkedListElement<T, N>* entry)
        : entry_(entry) {}

    const T* operator->() {
      return entry_->container();
    }

    const T* operator*() {
      return entry_->container();
    }

    bool operator==(const ConstIterator&other) const {
      return entry_ == other.entry_;
    }

    bool operator!=(const ConstIterator&other) const {
      return entry_ != other.entry_;
    }

    ConstIterator& operator++() {
      entry_ = entry_->next();
      return *this;
    }

   private:
    friend class LinkedList;

    const LinkedListElement<T, N>* entry_;
  };

  inline void prepend(T* a) {
    anchor_.insert_after(convert(a));
  }

  // Inserts before the element where predictate(T*) first returns true.
  // If the predicate never returns true, appends instead.  Returns whether or
  // not it was appended.
  template <typename Predicate>
  inline bool insert_before(T* element, Predicate predicate) {
    auto prev = &anchor_;
    for (auto it : *this) {
      if (predicate(it)) {
        prev->insert_after(element);
        return false;
      }
      prev = prev->next();
    }
    prev->insert_after(element);
    return true;
  }

  inline bool is_empty() const { return anchor_.is_empty(); }

  inline T* first() const {
    if (is_empty()) return null;
    return anchor_.next()->container();
  }

  inline T* remove_first() {
    if (is_empty()) return null;
    return anchor_.unlink_next()->container();
  }

  T* remove(T* entry) {
    return remove_where([&entry](T* t) {
      return t == entry;
    });
  }

  // Removes all the elements where the predicate returns true.  The predicate
  // may delete the entries or put them in a different list, but if so, it must
  // return true.
  template <typename Predicate>
  inline void remove_wherever(Predicate predicate) {
    remove_helper(predicate, null, true);
  }

  // Removes first element where the predicate returns true.  Returns that
  // element.  The predicate may not delete the element or link it into a
  // different list, but the caller can do those things via the return value.
  template <typename Predicate>
  inline T* remove_where(Predicate predicate) {
    return remove_helper(predicate, null, false);
  }

  Iterator begin() { return Iterator(anchor_.next()); }
  ConstIterator begin() const { return ConstIterator(anchor_.next()); }

  Iterator end() { return Iterator(null); }
  ConstIterator end() const { return ConstIterator(null); }

 protected:
  template <typename Predicate, typename RemovalReporter>
  inline T* remove_helper(Predicate predicate, RemovalReporter reporter, bool predicate_can_delete) {
    auto prev = &anchor_;
    for (auto current = anchor_.next(); current != null; ) {
      auto next = current->next();
      // The element is not in the list during the predicate call, since the
      // predicate may delete it or put it in a different list.
      if (predicate_can_delete) {
        current->clear_next();
      }
      if (predicate(current->container())) {
        // Predicate asked for this element to be removed.
        if (next == null) {
          linked_list_report_last_removed(reporter, prev);
        }
        prev->next_ = next;
        if (!predicate_can_delete) {
          current->clear_next();
          return current->container();
        }
      } else {
        // Predicate asked to keep the element - we must restore the next_ pointer.
        if (predicate_can_delete) {
          current->next_ = next;
        } else {
          // The predicate of the remove method should not delete its argument
          // or put it in a different list.
          ASSERT(current->next_ == next);
        }
        prev = current;
      }
      current = next;
    }
    return null;
  }

 protected:
  Element anchor_;

  Element* convert(T* entry) {
    return static_cast<Element*>(entry);
  }

  friend class LinkedListPatcher<T>;
};

// Singly linked list container that supports FIFO.  It does not take ownership
// or attempt to allocate/deallocate.
// To use with your own Foo class:
//
// class Foo;
// typedef LinkedFIFO<Foo> FooFIFO;
// class Foo : public FooFIFO::Element {
//   ...
// }
//
// FooList the_foos;
//
//   for (Foo* it : the_foos) {
//   }
template <typename T, int N = 1>
class LinkedFIFO : public LinkedList<T, N> {
 public:
  LinkedFIFO<T, N>() : tail_(&this->anchor_) {}

  typedef LinkedList<T, N> Super;
  typedef typename Super::Element Element;

  inline void prepend(T* a) {
    if (this->is_empty()) tail_ = a;
    Super::prepend(a);
  }

  // Inserts before the element where predictate(T*) first returns true.
  // If the predicate never returns true, appends instead.  Returns whether or
  // not it was appended.
  template <typename Predicate>
  inline bool insert_before(T* element, Predicate predicate) {
    bool appended = Super::insert_before(element, predicate);
    if (appended) tail_ = element;
    return appended;
  }

  inline T* remove_first() {
    T* result = Super::remove_first();
    if (this->is_empty()) tail_ = &this->anchor_;
    return result;
  }

  inline T* last() const {
    if (this->is_empty()) return null;
    return tail_->container();
  }

  T* remove(T* entry) {
    return Super::remove_helper(
        [&entry](T* e) -> bool { return e == entry; },          // Find element that matches.
        [this](Element* pred) { tail_ = pred; },  // Update tail_ if last element is removed.
        false);
  }

  // Removes all the elements where the predicate returns true.  The predicate
  // may delete the entries, but if it does it must return true.
  template <typename Predicate>
  void remove_wherever(Predicate predicate) {
    Super::remove_helper(
        predicate,
        [this](Element* pred) { tail_ = pred; },  // Update tail_ if last element is removed.
        true);
  }

  // Removes first element where the predicate returns true.  Returns that element.
  template <typename Predicate>
  inline T* remove_where(Predicate predicate) {
    return Super::remove_helper(
        predicate,
        [this](Element* pred) { tail_ = pred; },  // Update tail_ if last element is removed.
        false);
  }

  void append(T* entry) {
    if (!tail_) {
      prepend(entry);
    } else {
      tail_->insert_after(entry);
      tail_ = entry;
    }
  }

 private:
  // For use when appending, this either points to the anchor (for empty lists)
  // or to the last element in the list
  Element* tail_;

  friend class LinkedListPatcher<T>;
};

// This is a somewhat nasty class that allows you raw access to the next_ field
// of a linked list element.
template <typename T>
class LinkedListPatcher {
 public:
  explicit LinkedListPatcher(typename LinkedList<T>::Element& element)
    : next_(&element.next_)
    , tail_(null) {}

  explicit LinkedListPatcher(LinkedList<T>& list)
    : next_(&list.anchor_.next_)
    , tail_(null) {}

  explicit LinkedListPatcher(LinkedFIFO<T>& list)
    : next_(&list.anchor_.next_)
    , tail_(&list.tail_) {}

  typename LinkedList<T>::Element* next() const { return *next_; }
  typename LinkedList<T>::Element* tail() const { return *tail_; }

  void set_next(typename LinkedList<T>::Element* value) { *next_ = value; }
  void set_tail(typename LinkedList<T>::Element* value) { *tail_ = value; }

  typename LinkedList<T>::Element** next_cell() const { return next_; }
  typename LinkedList<T>::Element** tail_cell() const { return tail_; }

 private:
  typename LinkedList<T>::Element** next_;
  typename LinkedList<T>::Element** tail_;
};

template <typename T, int N = 1>
class DoubleLinkedListElement {
 public:
  DoubleLinkedListElement() : next_(this), prev_(this) {}

  ~DoubleLinkedListElement() {}

  // Copy constructor:
  DoubleLinkedListElement& operator=(DoubleLinkedListElement&& other) {
    ASSERT(next_ == this);
    ASSERT(prev_ == this);
    if (other.next_ != &other) {
      next_ = other.next_;
      next_->prev_ = this;
      prev_ = other.prev_;
      prev_->next_ = this;
    }
    other.next_ = &other;
    other.prev_ = &other;
    return *this;
  }

  // Move constructor:
  DoubleLinkedListElement(DoubleLinkedListElement&& other) : next_(this), prev_(this) {
    if (other.next_ != &other) {
      next_ = other.next_;
      next_->prev_ = this;
      prev_ = other.prev_;
      prev_->next_ = this;
    }
    other.next_ = &other;
    other.prev_ = &other;
  }

  bool is_not_linked() const {
    return next_ == this;
  }

 protected:
  DoubleLinkedListElement* unlink() {
    ASSERT(is_linked());
    DoubleLinkedListElement* next = next_;
    DoubleLinkedListElement* prev = prev_;
    next->prev_ = prev;
    prev->next_ = next;
    next_ = this;
    prev_ = this;
    return this;
  }

 private:
  T* container() { return static_cast<T*>(this); }
  const T* container() const { return static_cast<const T*>(this); }

  void insert_after(DoubleLinkedListElement* entry) {
    ASSERT(entry->next_ == entry);
    ASSERT(entry->prev_ == entry);
    DoubleLinkedListElement* old_next = next_;
    next_ = entry;
    entry->next_ = old_next;
    old_next->prev_ = entry;
    entry->prev_ = this;
  }

  void insert_before(DoubleLinkedListElement* entry) {
    prev_->insert_after(entry);
  }

  DoubleLinkedListElement* unlink_next() {
    return next_->unlink();
  }

  DoubleLinkedListElement* unlink_prev() {
    return prev_->unlink();
  }

  // Name makes sense on anchors.
  bool is_empty() const {
    return next_ == this;
  }

  // Name makes sense on non-anchor elements.
  bool is_linked() const {
    return next_ != this;
  }

  DoubleLinkedListElement* next() const { return next_; }
  DoubleLinkedListElement* prev() const { return prev_; }

  friend class DoubleLinkedList<T, N>;

  DoubleLinkedListElement* next_;
  DoubleLinkedListElement* prev_;
};

// Doubly linked list container that does not take ownership or attempt to
// allocate/deallocate.
// To use with your own Foo class:
//
// class Foo;
// typedef DoubleLinkedList<Foo> FooList;
// class Foo : public FooList::Element {
//   ...
// }
//
// FooList the_foos;
//
//   for (Foo* it : the_foos) {
//   }
template <typename T, int N = 1>
class DoubleLinkedList {
 public:
  typedef DoubleLinkedListElement<T, N> Element;

  class Iterator {
   public:
    explicit Iterator(Element* entry)
        : entry_(entry) {}

    T* operator->() {
      return entry_->container();
    }

    T* operator*() {
      return entry_->container();
    }

    bool operator==(const Iterator&other) const {
      return entry_ == other.entry_;
    }

    bool operator!=(const Iterator&other) const {
      return entry_ != other.entry_;
    }

    Iterator& operator++() {
      entry_ = entry_->next();
      return *this;
    }

    Iterator& operator--() {
      entry_ = entry_->prev();
      return *this;
    }

   private:
    friend class DoubleLinkedList;

    Element* entry_;
  };

  class ConstIterator {
   public:
    explicit ConstIterator(const Element* entry)
        : entry_(entry) {}

    const T* operator->() {
      return entry_->container();
    }

    const T* operator*() {
      return entry_->container();
    }

    bool operator==(const ConstIterator& other) const {
      return entry_ == other.entry_;
    }

    bool operator!=(const ConstIterator& other) const {
      return entry_ != other.entry_;
    }

    ConstIterator& operator++() {
      entry_ = entry_->next();
      return *this;
    }

    ConstIterator& operator--() {
      entry_ = entry_->prev();
      return *this;
    }

   private:
    friend class DoubleLinkedList;

    const Element* entry_;
  };

  // Inserts before the element where predicate(T*) first returns true.
  // If the predicate never returns true, appends instead.  Returns whether or
  // not it was appended.
  template <typename Predicate>
  inline bool insert_before(T* element, Predicate predicate) {
    for (auto it : *this) {
      if (predicate(it)) {
        convert(it)->insert_before(element);
        return false;
      }
    }
    append(element);
    return true;
  }

  inline void prepend(T* a) {
    anchor_.insert_after(convert(a));
  }

  inline void append(T* a) {
    anchor_.insert_before(convert(a));
  }

  inline bool is_empty() const { return anchor_.is_empty(); }

  inline bool is_linked(Element* a) const {
    return !a->is_not_linked();
  }

  inline void unlink(Element* a) const {
    a->unlink();
  }

  // Calls a predicate on each element of the list.  During the
  // predicate the element is unlinked from the list and can be
  // deleted or added to a different list.  If the predicate returns
  // false the element is reinserted in the position it came from.
  template <typename Predicate>
  inline void remove_wherever(Predicate predicate) {
    for (auto current = anchor_.next(); current != &anchor_; ) {
      auto next = current->next();
      // The element is not in the list during the predicate call, since the
      // predicate may delete it or put it in a different list.
      unlink(current);
      if (!predicate(current->container())) {
        // Predicate didn't ask for this element to be removed, so put it back.
        next->insert_before(current);
      }
      current = next;
    }
  }

  // Calls a predicate on each element of the list.  During the
  // predicate the element is not unlinked from the list and cannot be
  // removed from the list, deleted or added to a different list.  If the
  // predicate returns true the element is removed from the list and deleted.
  template <typename Predicate>
  inline void delete_wherever(Predicate predicate) {
    for (auto current = anchor_.next(); current != &anchor_; ) {
      if (predicate(current->container())) {
        auto next = current->next();
        unlink(current);
        delete current;
        current = next;
      } else {
        current = current->next();
      }
    }
  }

  inline T* first() const {
    if (is_empty()) return null;
    return anchor_.next()->container();
  }

  inline T* last() const {
    if (is_empty()) return null;
    return anchor_.prev()->container();
  }

  inline T* remove_first() {
    if (is_empty()) return null;
    return anchor_.next()->unlink()->container();
  }

  inline T* remove_last() {
    if (is_empty()) return null;
    return anchor_.prev()->unlink()->container();
  }

  Iterator begin() { return Iterator(anchor_.next()); }
  ConstIterator begin() const { return ConstIterator(anchor_.next()); }

  Iterator end() { return Iterator(&anchor_); }
  ConstIterator end() const { return ConstIterator(&anchor_); }

 protected:
  Element anchor_;

  Element* convert(T* entry) {
    return static_cast<Element*>(entry);
  }
};
