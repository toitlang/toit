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

#include <algorithm>

#include "dispatch_table.h"
#include "ir.h"
#include "set.h"
#include "../flags.h"

namespace toit {
namespace compiler {

using namespace ir;

namespace {

class Holes {
 public:
  struct Hole {
    int size;
    int at;
  };

  Hole pop_hole_of_size(int size) {
    if (!holes_.empty() && holes_[0].size >= size) {
      auto result = holes_[0];
      std::pop_heap(holes_.begin(), holes_.end(), [](Hole a, Hole b) { return a.size < b.size; });
      holes_.pop_back();
      return result;
    }
    return {
      .size = 0,
      .at = -1
    };
  }

  void insert(Hole hole) {
    holes_.push_back(hole);
    std::push_heap(holes_.begin(), holes_.end(), [](Hole a, Hole b) { return a.size < b.size; });
  }

  bool is_empty() const {
    return holes_.empty();
  }

 private:
  std::vector<Hole> holes_;
};

class SelectorRow {
 public:
  explicit SelectorRow(const DispatchSelector& selector)
      : selector_(selector)
      , begin_(-1)
      , end_(-1) {}

  DispatchSelector selector() const { return selector_; }

  int begin() const { return begin_; }
  int end() const { return end_; }
  int size() const { return end_ - begin_; }

  void define(Class* holder, Method* member) {
    ASSERT(holder == member->holder());
    holders_.push_back(holder);
    members_.push_back(member);
  }

  void finalize() {
    ASSERT(begin_ == -1 && end_ == -1);
    Class* first = holders_[0];
    begin_ = first->start_id();
    end_ = first->end_id();

    for (unsigned i = 1; i < holders_.size(); i++) {
      Class* holder = holders_[i];
      int begin = holder->start_id();
      int end = holder->end_id();
      if (begin < begin_) begin_ = begin;
      if (end > end_) end_ = end;
    }
  }

  static bool _sorted_specialized_first(const std::vector<Class*> holders) {
    for (size_t i = 1; i < holders.size(); i++) {
      if (holders[i - 1]->start_id() < holders[i]->start_id()) return false;
      if (holders[i - 1]->start_id() == holders[i]->start_id() &&
          holders[i - 1]->end_id() > holders[i]->end_id()) {
        return false;
      }
    }
    return true;
  }

  void fill(std::vector<Method*>* table, int offset) {
    // Check that the holders are sorted such that the more specialized entries are first.
    ASSERT(_sorted_specialized_first(holders_));
    // The amount we can skip once we found an entry
    std::vector<int> skip_stack;
    for (unsigned i = 0; i < holders_.size(); i++) {
      Class* holder = holders_[i];
      Method* member = members_[i];
      int start = offset + holder->start_id();
      int end = offset + holder->end_id();
      int id = start;
      while (id < end) {
        if ((*table)[id] == null) {
          (*table)[id] = member;
          id++;
        } else {
          // We know that the classes are ordered such that the more specialized classes
          //   come first.
          // The range that inserted these methods pushed its end-id onto the skip_stack.
          // We can just pop it, as we are going to replace the whole id-limit range with
          //   a new push_back at the end of the loop.
          // Say we had already inserted a method at slot 5-7, and another method at slot 4.
          // If we are now inserting a method in range 3 to 8, we first encounter the last
          //   pushed range (4) and skip over it. Then we reach the entry "7" and skip over
          //   5-7. Then, at the end of the loop, we push 8 on the stack, since methods 3 to 8
          //   are filled.
          ASSERT(!skip_stack.empty());
          id = skip_stack.back();
          skip_stack.pop_back();
        }
      }
      skip_stack.push_back(end);
    }
  }

  static bool compare(SelectorRow* a, SelectorRow* b) {
    auto a_selector = a->selector();
    auto b_selector = b->selector();
    // We move `operator==` to the end. This ensures that the dispatch-table doesn't need
    // `null` padding at the end (since every class has an `operator==` entry).
    // TODO(florian): tree-shaking could remove the method, leading to `null` padding.
    bool a_is_equals_operator = (strcmp(a_selector.name().c_str(), "==") == 0 &&
                                 a_selector.shape() == CallShape(1).with_implicit_this().to_plain_shape());
    bool b_is_equals_operator = (strcmp(b_selector.name().c_str(), "==") == 0 &&
                                 b_selector.shape() == CallShape(1).with_implicit_this().to_plain_shape());
    if (a_is_equals_operator && !b_is_equals_operator) return false;
    if (b_is_equals_operator && !a_is_equals_operator) return true;
    // Sort by decreasing sizes (first) and decreasing begin index.
    // According to the literature, this leads to fewer holes and
    // faster row offset computation.
    int a_size = a->size();
    int b_size = b->size();
    return (a_size == b_size) ? a->begin() > b->begin() : a_size > b_size;
  }

 private:
  DispatchSelector selector_;

  // All used entries in this row are in the [begin, end) interval.
  int begin_;
  int end_;

  // Unique member definitions ordered with the most specific ones first.
  std::vector<Class*> holders_;
  std::vector<Method*> members_;
};

class RowFitter {
 public:
  // Start fitting at the given offset.
  RowFitter() : limit_(0) {}

  int limit() const { return limit_; }

  void define(DispatchSelector& selector, Class* holder, Method* member) {
    SelectorRow* row = selectors_.lookup(selector);
    if (row == null) {
      row = selectors_[selector] = _new SelectorRow(selector);
    }
    row->define(holder, member);
  }

  std::vector<SelectorRow*> sorted_rows() {
    // Finalize and sort all the rows.
    std::vector<SelectorRow*> rows;
    for (auto key : selectors_.keys()) {
      SelectorRow* row = selectors_[key];
      row->finalize();
      rows.push_back(row);
    }
    std::sort(rows.begin(), rows.end(), SelectorRow::compare);
    return rows;
  }

  int fit_and_fill(std::vector<Method*>* table, SelectorRow* row, List<Class*> classes) {
    int row_size = row->size();
    int offset;
    int start;
    std::vector<Holes::Hole> unused_holes;
    while (true) {
      auto hole = holes_.pop_hole_of_size(row_size);
      bool in_hole;
      if (hole.size >= row_size) {
        start = hole.at;
        in_hole = true;
      } else {
        // Append at the end of the table.
        start = table->size();
        in_hole = false;
      }
      offset = start - row->begin();

      if (in_hole &&
          (offset < 0 || used_offsets_.contains(offset))) {
        // We could try to see if the hole is bigger than needed and whether we
        // can fit into the hole by shifting to the right. It's rare enough that
        // we don't bother. Just give up with this hole and try the next one.
        unused_holes.push_back(hole);
        continue;
      }

      // We are now certain to keep the hole.
      // If the hole wasn't the correct size push back the remaining size.
      if (hole.size > row_size) {
        holes_.insert({ .size = hole.size - row_size, .at = hole.at + row_size });
      }

      // Pad to avoid negative offsets. This can only happen when we are not in
      // a hole.
      if (offset < 0) {
        ASSERT(!in_hole);
        start += -offset;
        offset = 0;
      }

      // Pad to guarantee unique offsets. This can only happen when we are not
      // in a hole.
      int original_offset = offset;
      while (used_offsets_.contains(offset)) {
        ASSERT(!in_hole);
        start++;
        offset++;
      }
      if (offset != original_offset) {
        int hole_size = offset - original_offset;
        int at = start - hole_size;
        holes_.insert({ .size = hole_size, .at = at });
      }
      break;
    }
    // Return all the unused holes.
    for (auto hole : unused_holes) holes_.insert(hole);
    used_offsets_.insert(offset);

    // Keep track of the highest used offset.
    if (offset > limit_) limit_ = offset;

    // Allocate the necessary space.
    if (static_cast<int>(table->size()) < offset + row->end()) {
      // Can only happen when we are not in a hole.
      table->resize(offset + row->end());
    }

    row->fill(table, offset);
    ASSERT((*table)[offset + row->end() - 1] != null);
    for (int i = offset + row->begin(); i < offset + row->end(); i++) {
      if ((*table)[i] == null) {
        int hole_begin = i;
        while ((*table)[i] == null) i++;
        holes_.insert({ .size = i - hole_begin, .at = hole_begin });
      }
    }
    return offset;
  }

  /// Returns the total size of the unused holes.
  int pop_all_holes() {
    int result = 0;
    while (!holes_.is_empty()) {
      result += holes_.pop_hole_of_size(1).size;
    }
    return result;
  }

 private:
  Map<DispatchSelector, SelectorRow*> selectors_;
  UnorderedSet<int> used_offsets_;
  int limit_;
  Holes holes_;
};
} // namespace toit::compiler::<anynomous>

class DispatchTableBuilder : public TraversingVisitor {
 public:
  DispatchTableBuilder() {}

  void cook(Program* program, List<Class*> classes, List<Method*> methods);
  void print_table();

  void visit_CallVirtual(CallVirtual* node) {
    TraversingVisitor::visit_CallVirtual(node);
    PlainShape shape(node->shape());
    DispatchSelector selector(node->selector(), shape);
    selectors_.insert(selector);
  }

  Map<DispatchSelector, int>& selector_offsets() { return selector_offsets_; }
  List<Method*> dispatch_table() { return dispatch_table_; }

 private:
  Set<DispatchSelector> selectors_;
  Map<DispatchSelector, int> selector_offsets_;
  List<Method*> dispatch_table_;

  void handle_methods(List<Method*> methods);
  // Returns the amount of instantiated classes.
  int assign_class_ids(List<Class*> classes);

  void handle_classes(List<Class*> classes, int static_method_count);

  bool indexes_are_correct();
};

void DispatchTableBuilder::handle_methods(List<Method*> methods) {
  auto table = dispatch_table();
  int method_index = 0;
  for (int i = 0; i < table.length(); i++) {
    if (table[i] == null) {
      auto method = methods[method_index++];
      ASSERT(!method->is_dead());
      table[i] = method;
      ASSERT(!method->index_is_set());
      method->set_index(i);
      if (method_index == methods.length()) break;
    }
  }
  ASSERT(method_index == methods.length());
}

int DispatchTableBuilder::assign_class_ids(List<Class*> classes) {
  int instantiated_count = 0;
  for (auto klass : classes) {
    if (klass->is_instantiated()) instantiated_count++;
  }

  int id = instantiated_count - 1;
  int uninstantiated_id = classes.length() - 1;
  for (int i = classes.length() - 1; i >= 0; i--) {
    auto klass = classes[i];
    if (klass->end_id() == -1) {
      // No subclass.
      ASSERT(klass->is_instantiated());  // Otherwise we would have shaken the class.
      ASSERT(i == classes.length() - 1 || classes[i + 1]->super() != klass);
      klass->set_id(id);
      klass->set_start_id(id);
      klass->set_end_id(id + 1);
      id--;
    } else if (klass->is_instantiated()) {
      klass->set_id(id);
      klass->set_start_id(id);
      id--;
    } else {
      // Set the start-id to the first class that is actually instantiated.
      klass->set_id(uninstantiated_id);
      uninstantiated_id--;
      int j = i;
      while (!classes[j]->is_instantiated()) j++;
      klass->set_start_id(classes[j]->start_id());
    }
    auto super = klass->super();
    if (super != null && super->end_id() == -1) {
      // end-ids are exclusive.
      super->set_end_id(klass->end_id());
    }
  }
  return instantiated_count;
}

void DispatchTableBuilder::handle_classes(List<Class*> classes, int static_method_count) {
  int instantiated_count = assign_class_ids(classes);

  // Collect all selectors and create selector rows for them. As a side-effect, we
  // also compute the resolved index for all fields.
  RowFitter fitter;
  // We run through the sorted classes in reverse order, so that we handle
  // subclasses before superclasses.
  for (int i = classes.length() - 1; i >= 0; i--) {
    auto holder = classes[i];

    for (auto method : holder->methods()) {
      ASSERT(!method->is_dead());
      DispatchSelector selector(method->name(), method->plain_shape());
      if (!method->is_IsInterfaceStub() && !selectors_.contains(selector)) continue;
      fitter.define(selector, holder, method);
    }
  }

  // Assign offsets to all selectors.
  std::vector<Method*> result;

  // Compute the table.
  std::vector<SelectorRow*> rows = fitter.sorted_rows();
  for (auto row : rows) {
    selector_offsets_[row->selector()] = fitter.fit_and_fill(&result, row, classes);
  }

  int unused_slots = fitter.pop_all_holes();

  // Make sure that all methods are in the table.
  // Classes that aren't instantiated might have methods that are completely
  //   overridden by all instantiated subclasses. These methods might still
  //   need to be in the table, for super-class calls.

  // Start by assigning indexes to the methods that are already in the table.
  // This makes it easier to know whether a method is already handled.
  int table_size = result.size();
  for (int i = 0; i < table_size; i++) {
    auto method = result[i];
    if (method == null) continue;
    if (method->index_is_set()) continue;
    method->set_index(i);
  }

  // Now go through all methods again, and see if some of them aren't yet in
  // the table. For uninstantiated holder classes, the methods we are looking
  // for are the ones reachable through super-class calls. For instantiated
  // holder classes, the methods that aren't in the table yet are those always
  // called through static calls because of our optimizations that turn
  // virtual calls into static ones.
  int table_index = 0;
  int extra_method_count = 0;
  for (auto klass : classes) {
    for (auto method : klass->methods()) {
      if (method->index_is_set()) continue;
      extra_method_count++;
      // Find the next free slot in the table.
      while (table_index < table_size && result[table_index] != null) {
        table_index++;
      }
      if (table_index < table_size) {
        ASSERT(result[table_index] == null);
        result[table_index] = method;
        method->set_index(table_index);
      } else {
        method->set_index(result.size());
        result.push_back(method);
      }
    }
  }

  if (unused_slots >= extra_method_count) {
    unused_slots -= extra_method_count;
    extra_method_count = 0;
  } else {
    extra_method_count -= unused_slots;
    unused_slots = 0;
  }
  int final_size = fitter.limit() + instantiated_count + extra_method_count;
  if (static_method_count > unused_slots) {
    final_size += static_method_count - unused_slots;
  }
  result.resize(final_size);

  dispatch_table_ = ListBuilder<Method*>::build_from_vector(result);;
}

bool DispatchTableBuilder::indexes_are_correct() {
  for (int i = 0; i < dispatch_table_.length(); i++) {
    auto method = dispatch_table_[i];
    if (method == null) continue;
    if (dispatch_table_[method->index()] != method) return false;
  }
  return true;
}

void DispatchTableBuilder::cook(Program* program,
                                List<Class*> classes,
                                List<Method*> methods) {
  // Traverse the entire program and find all virtual calls.
  program->accept(this);

  int method_count = methods.length();
  handle_classes(classes, method_count);
  // Methods need to be added after the classes, since we are filling up
  // the empty slots.
  handle_methods(methods);

  if (Flags::print_dispatch_table) {
    print_table();
  }
  ASSERT(indexes_are_correct());
}

void DispatchTableBuilder::print_table() {
  auto table = dispatch_table();
  for (int i = 0; i < table.length(); i++) {
    printf("%d: ", i);
    auto node = table[i];
    if (node == null) {
      printf("null\n");
    } else if (node->is_Method()) {
      auto method = node->as_Method();
      bool is_static = method->is_static();
      printf("%s (%s, %p)\n",
             method->name().c_str(), is_static ? "static" : "virtual", static_cast<void*>(method));
    } else if (node->is_Class()) {
      printf("%s (default initializer)\n", node->as_Class()->name().c_str());
    } else if (node->is_Field()) {
      printf("%s (field)\n", node->as_Field()->name().c_str());
    } else {
      printf("??\n");
    }
  }
  printf("Offsets:\n");
  for (auto selector : selector_offsets().keys()) {
    printf("%s,%d,%d,%d",
           selector.name().c_str(),
           selector.shape().arity(),
           selector.shape().total_block_count(),
           selector.shape().named_block_count());
    for (auto name : selector.shape().names()) {
      printf(", %s", name.c_str());
    }
    auto id = selector_offsets().at(selector);
    printf(": %d\n", id);
  }
}

int DispatchTable::slot_index_for(const Method* method) const {
  if (method->is_dead()) return -1;
  int index = method->index();
  ASSERT(table_[index] == method);
  return index;
}

void DispatchTable::for_each_slot_index(const Method* member,
                                        int dispatch_offset,
                                        std::function<void (int)>& callback) const {
  ASSERT(member->holder() != null);

  auto holder = member->holder();
  int start = dispatch_offset + holder->start_id();
  int limit = dispatch_offset + holder->end_id();

  int member_slot_index = slot_index_for(member);
  if (start <= member_slot_index && member_slot_index < limit) {
    for (int i = start; i < limit; i++) {
      if (table_[i] == member) {
        callback(i);
      }
    }
  } else {
    // If the member's slot index is not in the selector's range, then the
    // member was treated like a static. We use this for super calls and
    // for optimized virtual calls, so this can happen with both instantiated
    // and uninstantiated holder classes.
    callback(member_slot_index);
  }
}

DispatchTable DispatchTable::build(Program* program) {
  DispatchTableBuilder builder;
  builder.cook(program, program->classes(), program->methods());
  return DispatchTable(builder.dispatch_table(), builder.selector_offsets());
}

} // namespace toit::compiler
} // namespace toit
