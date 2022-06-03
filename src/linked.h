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
  LinkedListElement() : _next(null) {}

  ~LinkedListElement() {
    ASSERT(is_not_linked());
  }

 protected:
  // For asserts, a conservative assertion that the element is not linked in a
  // list (but it might be last).
  bool is_not_linked() const {
    return _next == null;
  }

 private:
  void clear_next() {
    _next = null;
  }

  T* container() { return static_cast<T*>(this); }
  const T* container() const { return static_cast<const T*>(this); }

  void append(LinkedListElement* entry) {
    ASSERT(_next == null);
    _next = entry;
  }

  LinkedListElement* unlink_next() {
    LinkedListElement* next = _next;
    _next = next->_next;
    next->_next = null;
    return next;
  }

  void insert_after(LinkedListElement* entry) {
    // Assert the new entry is not already linked into a list.
    ASSERT(entry->_next == null);
    entry->_next = _next;
    _next = entry;
  }

  // Name makes sense on anchors.
  bool is_empty() const {
    return _next == null;
  }

  // Name makes sense on individual elements.
  bool is_last() const {
    return _next == null;
  }

  LinkedListElement* next() const { return _next; }

  friend class LinkedList<T, N>;
  friend class LinkedFIFO<T, N>;
  friend class LinkedListPatcher<T>;

  LinkedListElement* _next;
};

// These two linked_list_report_last_removed templates are a way to get the
// types to work when null is passed as the reporting callable.
template<typename Element, typename Reporter>
static inline void linked_list_report_last_removed(Reporter r, Element* element) {
  r(element);
}

template<typename Element>
static inline void linked_list_report_last_removed(std::nullptr_t n, Element* element) {
}

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
        : _entry(entry) {}

    T* operator->() {
      return _entry->container();
    }

    T* operator*() {
      return _entry->container();
    }

    bool operator==(const Iterator&other) const {
      return _entry == other._entry;
    }

    bool operator!=(const Iterator&other) const {
      return _entry != other._entry;
    }

    Iterator& operator++() {
      _entry = _entry->next();
      return *this;
    }

   private:
    friend class LinkedList;

    LinkedListElement<T, N>* _entry;
  };

  class ConstIterator {
   public:
    explicit ConstIterator(const LinkedListElement<T, N>* entry)
        : _entry(entry) {}

    const T* operator->() {
      return _entry->container();
    }

    const T* operator*() {
      return _entry->container();
    }

    bool operator==(const ConstIterator&other) const {
      return _entry == other._entry;
    }

    bool operator!=(const ConstIterator&other) const {
      return _entry != other._entry;
    }

    ConstIterator& operator++() {
      _entry = _entry->next();
      return *this;
    }

   private:
    friend class LinkedList;

    const LinkedListElement<T, N>* _entry;
  };

  inline void prepend(T* a) {
    _anchor.insert_after(convert(a));
  }

  // Inserts before the element where predictate(T*) first returns true.
  // If the predicate never returns true, appends instead.  Returns whether or
  // not it was appended.
  template <typename Predicate>
  inline bool insert_before(T* element, Predicate predicate) {
    auto prev = &_anchor;
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

  inline bool is_empty() const { return _anchor.is_empty(); }

  inline T* first() const {
    if (is_empty()) return null;
    return _anchor.next()->container();
  }

  inline T* remove_first() {
    if (is_empty()) return null;
    return _anchor.unlink_next()->container();
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

  Iterator begin() { return Iterator(_anchor.next()); }
  ConstIterator begin() const { return ConstIterator(_anchor.next()); }

  Iterator end() { return Iterator(null); }
  ConstIterator end() const { return ConstIterator(null); }

 protected:
  template <typename Predicate, typename RemovalReporter>
  inline T* remove_helper(Predicate predicate, RemovalReporter reporter, bool predicate_can_delete) {
    auto prev = &_anchor;
    for (auto current = _anchor.next(); current != null; ) {
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
        prev->_next = next;
        if (!predicate_can_delete) {
          current->clear_next();
          return current->container();
        }
      } else {
        // Predicate asked to keep the element - we must restore the _next pointer.
        if (predicate_can_delete) {
          current->_next = next;
        } else {
          // The predicate of the remove method should not delete its argument
          // or put it in a different list.
          ASSERT(current->_next == next);
        }
        prev = current;
      }
      current = next;
    }
    return null;
  }

 protected:
  Element _anchor;

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
  LinkedFIFO<T, N>() : _tail(&this->_anchor) {}

  typedef LinkedList<T, N> Super;
  typedef typename Super::Element Element;

  inline void prepend(T* a) {
    if (this->is_empty()) _tail = a;
    Super::prepend(a);
  }

  // Inserts before the element where predictate(T*) first returns true.
  // If the predicate never returns true, appends instead.  Returns whether or
  // not it was appended.
  template <typename Predicate>
  inline bool insert_before(T* element, Predicate predicate) {
    bool appended = Super::insert_before(element, predicate);
    if (appended) _tail = element;
    return appended;
  }

  inline T* remove_first() {
    T* result = Super::remove_first();
    if (this->is_empty()) _tail = &this->_anchor;
    return result;
  }

  inline T* last() const {
    if (this->is_empty()) return null;
    return _tail->container();
  }

  T* remove(T* entry) {
    return Super::remove_helper(
        [&entry](T* e) -> bool { return e == entry; },          // Find element that matches.
        [this](Element* pred) { _tail = pred; },  // Update _tail if last element is removed.
        false);
  }

  // Removes all the elements where the predicate returns true.  The predicate
  // may delete the entries, but if it does it must return true.
  template <typename Predicate>
  void remove_wherever(Predicate predicate) {
    Super::remove_helper(
        predicate,
        [this](Element* pred) { _tail = pred; },  // Update _tail if last element is removed.
        true);
  }

  // Removes first element where the predicate returns true.  Returns that element.
  template <typename Predicate>
  inline T* remove_where(Predicate predicate) {
    return Super::remove_helper(
        predicate,
        [this](Element* pred) { _tail = pred; },  // Update _tail if last element is removed.
        false);
  }

  void append(T* entry) {
    if (!_tail) {
      prepend(entry);
    } else {
      _tail->insert_after(entry);
      _tail = entry;
    }
  }

 private:
  // For use when appending, this either points to the anchor (for empty lists)
  // or to the last element in the list
  Element* _tail;

  friend class LinkedListPatcher<T>;
};

// This is a somewhat nasty class that allows you raw access to the _next field
// of a linked list element.
template <typename T>
class LinkedListPatcher {
 public:
  explicit LinkedListPatcher(typename LinkedList<T>::Element& element)
    : _next(&element._next)
    , _tail(null) {}

  explicit LinkedListPatcher(LinkedList<T>& list)
    : _next(&list._anchor._next)
    , _tail(null) {}

  explicit LinkedListPatcher(LinkedFIFO<T>& list)
    : _next(&list._anchor._next)
    , _tail(&list._tail) {}

  typename LinkedList<T>::Element* next() const { return *_next; }
  typename LinkedList<T>::Element* tail() const { return *_tail; }

  void set_next(typename LinkedList<T>::Element* value) { *_next = value; }
  void set_tail(typename LinkedList<T>::Element* value) { *_tail = value; }

  typename LinkedList<T>::Element** next_cell() const { return _next; }
  typename LinkedList<T>::Element** tail_cell() const { return _tail; }

 private:
  typename LinkedList<T>::Element** _next;
  typename LinkedList<T>::Element** _tail;
};

template <typename T, int N = 1>
class DoubleLinkedListElement {
 public:
  DoubleLinkedListElement() : _next(this), _prev(this) {}

  ~DoubleLinkedListElement() {}

  // Copy constructor:
  DoubleLinkedListElement& operator=(DoubleLinkedListElement&& other) {
    ASSERT(_next == this);
    ASSERT(_prev == this);
    if (other._next != &other) {
      _next = other._next;
      _next->_prev = this;
      _prev = other._prev;
      _prev->_next = this;
    }
    other._next = &other;
    other._prev = &other;
    return *this;
  }

  // Move constructor:
  DoubleLinkedListElement(DoubleLinkedListElement&& other) : _next(this), _prev(this) {
    if (other._next != &other) {
      _next = other._next;
      _next->_prev = this;
      _prev = other._prev;
      _prev->_next = this;
    }
    other._next = &other;
    other._prev = &other;
  }

  bool is_not_linked() const {
    return _next == this;
  }

 protected:
  DoubleLinkedListElement* unlink() {
    ASSERT(is_linked());
    DoubleLinkedListElement* next = _next;
    DoubleLinkedListElement* prev = _prev;
    next->_prev = prev;
    prev->_next = next;
    _next = this;
    _prev = this;
    return this;
  }

 private:
  T* container() { return static_cast<T*>(this); }
  const T* container() const { return static_cast<const T*>(this); }

  void insert_after(DoubleLinkedListElement* entry) {
    ASSERT(entry->_next == entry);
    ASSERT(entry->_prev == entry);
    DoubleLinkedListElement* old_next = _next;
    _next = entry;
    entry->_next = old_next;
    old_next->_prev = entry;
    entry->_prev = this;
  }

  void insert_before(DoubleLinkedListElement* entry) {
    _prev->insert_after(entry);
  }

  DoubleLinkedListElement* unlink_next() {
    return _next->unlink();
  }

  DoubleLinkedListElement* unlink_prev() {
    return _prev->unlink();
  }

  // Name makes sense on anchors.
  bool is_empty() const {
    return _next == this;
  }

  // Name makes sense on non-anchor elements.
  bool is_linked() const {
    return _next != this;
  }

  DoubleLinkedListElement* next() const { return _next; }
  DoubleLinkedListElement* prev() const { return _prev; }

  friend class DoubleLinkedList<T, N>;

  DoubleLinkedListElement* _next;
  DoubleLinkedListElement* _prev;
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
        : _entry(entry) {}

    T* operator->() {
      return _entry->container();
    }

    T* operator*() {
      return _entry->container();
    }

    bool operator==(const Iterator&other) const {
      return _entry == other._entry;
    }

    bool operator!=(const Iterator&other) const {
      return _entry != other._entry;
    }

    Iterator& operator++() {
      _entry = _entry->next();
      return *this;
    }

    Iterator& operator--() {
      _entry = _entry->prev();
      return *this;
    }

   private:
    friend class DoubleLinkedList;

    Element* _entry;
  };

  class ConstIterator {
   public:
    explicit ConstIterator(const Element* entry)
        : _entry(entry) {}

    const T* operator->() {
      return _entry->container();
    }

    const T* operator*() {
      return _entry->container();
    }

    bool operator==(const ConstIterator& other) const {
      return _entry == other._entry;
    }

    bool operator!=(const ConstIterator& other) const {
      return _entry != other._entry;
    }

    ConstIterator& operator++() {
      _entry = _entry->next();
      return *this;
    }

    ConstIterator& operator--() {
      _entry = _entry->prev();
      return *this;
    }

   private:
    friend class DoubleLinkedList;

    const Element* _entry;
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
    _anchor.insert_after(convert(a));
  }

  inline void append(T* a) {
    _anchor.insert_before(convert(a));
  }

  inline bool is_empty() const { return _anchor.is_empty(); }

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
    for (auto current = _anchor.next(); current != &_anchor; ) {
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
    for (auto current = _anchor.next(); current != &_anchor; ) {
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
    return _anchor.next()->container();
  }

  inline T* last() const {
    if (is_empty()) return null;
    return _anchor.prev()->container();
  }

  inline T* remove_first() {
    if (is_empty()) return null;
    return _anchor.next()->unlink()->container();
  }

  inline T* remove_last() {
    if (is_empty()) return null;
    return _anchor.prev()->unlink()->container();
  }

  Iterator begin() { return Iterator(_anchor.next()); }
  ConstIterator begin() const { return ConstIterator(_anchor.next()); }

  Iterator end() { return Iterator(&_anchor); }
  ConstIterator end() const { return ConstIterator(&_anchor); }

 protected:
  Element _anchor;

  Element* convert(T* entry) {
    return static_cast<Element*>(entry);
  }
};
