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

#include <vector>

#include "map.h"
#include "queryable_class.h"
#include "resolver_scope.h"
#include "set.h"
#include "token.h"
#include "tree.h"
#include "../flags.h"
#include "optimizations/utils.h"

namespace toit {
namespace compiler {

using namespace ir;

typedef Selector<CallShape> CallSelector;

/// A typed selector set is a set of selectors, where
/// each selector only applies to specific types.
/// In the current implementation the type is represented by the
/// single target that the selector can reach.
/// For example, a selector 'foo' that applies only to type `A` (or maybe
/// its subclasses) would be represented by the method `A.foo`.
/// This representation is not optimal, but historical. Eventually,
/// this set should keep track of the types that are available, making
/// it more flexible, intuitive and powerful.
class TypedSelectorSet {
 public:
  void insert(const CallSelector& selector, Method* target) {
    selectors_[selector].insert(target);
  }

  /// Adds all typed selectors of other to this set.
  /// Ignores all methods that are in the 'ignored_methods' set.
  /// Ignores all selectors that are in the 'ignored_selectors' set.
  void insert_all(TypedSelectorSet& other,
                  const Set<Method*> ignored_methods,
                  const Set<CallSelector> ignored_selectors) {
    other.selectors_.for_each([&](const CallSelector& selector, const UnorderedSet<Method*> methods) {
      if (ignored_selectors.contains(selector)) return;
      for (auto method : methods.underlying_set()) {
        if (ignored_methods.contains(method)) continue;
        selectors_[selector].insert(method);
      }
    });
  }

  void match_and_filter(const QueryableClass& queryable,
                        const std::function<bool (const CallSelector&, Method*)>& on_match) {
    // A typed selector hit, if there is a class that has a method for it, and
    // that method is in the set.
    selectors_.for_each([&](CallSelector selector, UnorderedSet<Method*>& methods) {
      if (methods.empty()) return;
      auto probe = queryable.lookup(selector);
      if (probe != null && methods.contains(probe)) {
        bool should_erase = on_match(selector, probe);
        if (should_erase) methods.erase(probe);
        // We would like to completely erase entries for call selectors that don't have any
        // target, but since we are using an ordered `Map`, that functionality is
        // currently not available.
      }
    });
  }

  bool empty() const {
    // Only looks at whether there are entries in the map. Does not
    // run through them to see if all of the sets are empty.
    return selectors_.empty();
  }

 private:
  Map<CallSelector, UnorderedSet<Method*>> selectors_;
};

class GrowerVisitor : protected TraversingVisitor {
 public:
  explicit GrowerVisitor(Method* as_check_failure)
      : as_check_failure_(as_check_failure) {}

  const Set<Class*>& found_classes() const { return found_classes_; }
  const Set<Method*>& found_methods() const { return found_methods_; }
  TypedSelectorSet& found_typed_selectors() { return found_typed_selectors_; }
  const Set<CallSelector>& found_selectors() const { return found_selectors_; }

  void grow(Method* method) {
    current_method_ = method;
    visit(method);
  }

 protected:
  void visit_CallConstructor(CallConstructor* node) {
    found_classes_.insert(node->klass());
    found_methods_.insert(node->target()->target());
    TraversingVisitor::visit_CallConstructor(node);
  }

  bool is_super_call(CallStatic* node) const {
    auto current_holder = current_method_->holder();
    auto target = node->target()->target();
    if (!is_This(node->arguments()[0], current_holder, target)) return false;
    auto target_holder = target->holder();
    // Make sure this is actually a super call (and not a sub call).
    return target_holder->is_transitive_super_of(current_holder);
  }

  void visit_CallStatic(CallStatic* node) {
    auto target = node->target()->target();
    if (target->is_instance()) {
      if (is_super_call(node) || target->holder()->is_mixin()) {
        // For super calls or mixins we don't need to ensure that the
        // holder class is actually instantiated and its method isn't shadowed.
        found_methods_.insert(target);
      } else {
        CallSelector selector(target->name(), node->shape());
        found_typed_selectors_.insert(selector, target);
      }
    } else {
      found_methods_.insert(target);
    }
    TraversingVisitor::visit_CallStatic(node);
  }

  void visit_CallVirtual(CallVirtual* node) {
    CallSelector selector(node->target()->selector(), node->shape());
    found_selectors_.insert(selector);
    TraversingVisitor::visit_CallVirtual(node);
  }

  void visit_ReferenceGlobal(ReferenceGlobal* node) {
    found_methods_.insert(node->target());
    TraversingVisitor::visit_ReferenceGlobal(node);
  }

  void visit_AssignmentGlobal(AssignmentGlobal* node) {
    // TODO(florian): if we always assign to a global before reading from it
    // the initializer isn't executed and we could shake it away. However, that's
    // probably a rare case and not worth the effort here.
    found_methods_.insert(node->global());
    TraversingVisitor::visit_AssignmentGlobal(node);
  }

  void visit_Typecheck(Typecheck* node) {
    if (node->is_as_check()) found_methods_.insert(as_check_failure_);
    if (node->is_interface_check()) {
      found_selectors_.insert(node->type().klass()->typecheck_selector());
    }
    TraversingVisitor::visit_Typecheck(node);
  }

 private:
  Method* current_method_;
  Method* as_check_failure_;
  Set<Class*> found_classes_;
  Set<Method*> found_methods_;
  TypedSelectorSet found_typed_selectors_;
  Set<CallSelector> found_selectors_;
};

class TreeLogger {
 public:
  virtual void root(Method* method) {}
  virtual void root(Class* klass) {}
  virtual void add(Method* method,
                   Set<Class*> classes,
                   Set<Method*> methods,
                   Set<CallSelector> selectors) {}
  virtual void add_method_with_selector(CallSelector selector, Method* method) {}

  virtual void print() {}
};

class GraphvizTreeLogger : public TreeLogger {
 public:
  GraphvizTreeLogger() {}

  void root(Method* method) { root_methods_.push_back(method); }
  void root(Class* klass) { root_classes_.push_back(klass); }
  void add(Method* method,
           Set<Class*> classes,
           Set<Method*> methods,
           Set<CallSelector> selectors) {
    auto& class_vector = method_to_classes_[method];
    class_vector.insert(class_vector.end(), classes.begin(), classes.end());
    auto& method_vector = method_to_methods_[method];
    method_vector.insert(method_vector.end(), methods.begin(), methods.end());
    auto& selector_vector = method_to_selectors_[method];
    for (auto selector : selectors) {
      selector_vector.push_back(selector);
    }
  }

  void add_method_with_selector(CallSelector selector, Method* method) {
    selector_to_methods_[selector].insert(method);
  }

  void print() {
    UnorderedSet<CallSelector> excluded_selectors;
    excluded_selectors.insert(CallSelector(Token::symbol(Token::ADD), CallShape(2)));
    excluded_selectors.insert(CallSelector(Token::symbol(Token::SUB), CallShape(2)));
    excluded_selectors.insert(CallSelector(Token::symbol(Token::LT), CallShape(2)));
    excluded_selectors.insert(CallSelector(Token::symbol(Token::LTE), CallShape(2)));
    excluded_selectors.insert(CallSelector(Token::symbol(Token::GT), CallShape(2)));
    excluded_selectors.insert(CallSelector(Token::symbol(Token::GTE), CallShape(2)));
    excluded_selectors.insert(CallSelector(Token::symbol(Token::EQ), CallShape(2)));
    excluded_selectors.insert(CallSelector(Symbols::index, CallShape(2)));
    excluded_selectors.insert(CallSelector(Symbols::index_put, CallShape(3)));

    printf("digraph tree {\n");

    // Label all classes.
    UnorderedMap<Class*, int> class_ids;
    int class_counter = 0;
    auto register_class = [&](Class* klass) mutable {
      if (class_ids.find(klass) != class_ids.end()) return;
      int id = class_counter++;
      class_ids[klass] = id;
      printf("  c%d [label=\"%s\", shape=doublecircle];\n", id, klass->name().c_str());
    };

    for (auto klass : root_classes_) {
      register_class(klass);
    }
    for (auto method : method_to_classes_.keys()) {
      auto class_vector = method_to_classes_.at(method);
      for (auto klass : class_vector) {
        register_class(klass);
      }
    }

    // Label all methods.
    UnorderedMap<Method*, int> method_ids;
    int method_counter = 0;
    auto register_method = [&](Method* method) mutable {
      if (method_ids.find(method) != method_ids.end()) return;
      int id = method_counter++;
      method_ids[method] = id;
      auto holder = method->holder();
      if (holder == null) {
        // A toplevel function.
        printf("  m%d [label=\"%s\"];\n", id, method->name().c_str());
      } else {
        // An instance/static method.
        printf("  m%d [label=\"%s.%s\"];\n", id, holder->name().c_str(), method->name().c_str());
      }
    };

    for (auto method : root_methods_) {
      register_method(method);
    }
    for (auto method : method_to_classes_.keys()) {
      register_method(method);
    }
    for (auto method : method_to_methods_.keys()) {
      register_method(method);
    }
    for (auto method : method_to_selectors_.keys()) {
      register_method(method);
    }

    // Label all selectors.
    UnorderedMap<CallSelector, int> selector_ids;
    int selector_counter = 0;
    for (auto& selector : selector_to_methods_.keys()) {
      int selector_id = selector_counter++;
      selector_ids[selector] = selector_id;
      printf("  s%d [label=\"%s\", shape=polygon];\n", selector_id, selector.name().c_str());
    }

    // Print the links.
    for (auto method : method_to_classes_.keys()) {
      int method_id = method_ids.at(method);
      for (auto klass : method_to_classes_.at(method)) {
        int class_id = class_ids.at(klass);
        printf("  m%d -> c%d;\n", method_id, class_id);
      }
    }
    for (auto method : method_to_methods_.keys()) {
      int method_id = method_ids.at(method);
      for (auto method2 : method_to_methods_.at(method)) {
        int method2_id = method_ids.at(method2);
        printf("  m%d -> m%d;\n", method_id, method2_id);
      }
    }
    for (auto method : method_to_selectors_.keys()) {
      int method_id = method_ids.at(method);
      for (auto selector : method_to_selectors_.at(method)) {
        if (excluded_selectors.contains(selector)) continue;
        auto probe = selector_to_methods_.find(selector);
        if (probe == selector_to_methods_.end()) continue;  // No class was instantiated.
        int selector_id = selector_ids.at(selector);
        printf("  m%d -> s%d;\n", method_id, selector_id);
      }
    }
    for (auto& selector : selector_to_methods_.keys()) {
      int selector_id = selector_ids.at(selector);
      for (auto method : selector_to_methods_.at(selector)) {
        int method_id = method_ids.at(method);
        printf("  s%d -> m%d;\n", selector_id, method_id);
        if (!excluded_selectors.contains(selector)) {
          auto holder = method->holder();
          int holder_id = class_ids.at(holder);
          printf("  c%d -> s%d [style=dashed];\n", holder_id, selector_id);
        }
      }
    }
    printf("}\n");
    exit(0);
  }

 private:
  std::vector<Method*> root_methods_;
  std::vector<Class*> root_classes_;
  Map<Method*, std::vector<Class*>> method_to_classes_;
  Map<Method*, std::vector<Method*>> method_to_methods_;
  Map<Method*, std::vector<CallSelector>> method_to_selectors_;
  Map<CallSelector, Set<Method*>> selector_to_methods_;
};


class TreeGrower {
 public:
  void grow(Program* program);

  Set<Class*> grown_classes() const { return grown_classes_; }
  // Includes globals, static functions and instance functions.
  Set<Method*> grown_methods() const { return grown_methods_; }

 private:
  Set<Class*> grown_classes_;
  Set<Method*> grown_methods_;
};

void TreeGrower::grow(Program* program) {
  bool include_abstracts;
  auto queryables = build_queryables_from_plain_shapes(program->classes(), include_abstracts=false);

  Set<CallSelector> handled_selectors;
  TypedSelectorSet handled_typed_selectors;

  std::vector<Method*> method_queue;

  TreeLogger* logger;
  TreeLogger null_logger;
  GraphvizTreeLogger printing_logger;
  if (Flags::print_dependency_tree) {
    logger = &printing_logger;
  } else {
    logger = &null_logger;
  }

  for (auto klass : program->tree_roots()) {
    logger->root(klass);
    grown_classes_.insert(klass);
  }

  for (auto entry_point : program->entry_points()) {
    logger->root(entry_point);
    method_queue.push_back(entry_point);
  }

  while (!method_queue.empty()) {
    Set<Class*> found_classes;
    Set<Method*> found_methods;
    TypedSelectorSet found_typed_selectors;
    Set<CallSelector> found_selectors;

    for (auto method : method_queue) {
      if (method->is_abstract() || method->is_dead()) continue;

      // Skip already visited methods.
      if (grown_methods_.contains(method)) continue;
      grown_methods_.insert(method);
      GrowerVisitor visitor(program->as_check_failure());
      visitor.grow(method);
      logger->add(method, visitor.found_classes(), visitor.found_methods(), visitor.found_selectors());
      found_classes.insert_all(visitor.found_classes());
      found_methods.insert_all(visitor.found_methods());
      // Ignore already grown methods, and selectors that cover every type.
      found_typed_selectors.insert_all(visitor.found_typed_selectors(),
                                       grown_methods_,
                                       handled_selectors);
      found_selectors.insert_all(visitor.found_selectors());
    }

    method_queue.clear();

    method_queue.insert(method_queue.end(), found_methods.begin(), found_methods.end());

    for (auto klass : found_classes) {
      if (grown_classes_.contains(klass)) continue;
      grown_classes_.insert(klass);
      auto queryable = queryables[klass];
      for (auto selector : handled_selectors) {
        auto probe = queryable.lookup(selector);
        if (probe != null) {
          logger->add_method_with_selector(selector, probe);
          method_queue.push_back(probe);
        }
      }
      handled_typed_selectors.match_and_filter(queryable,
                                               [&](const CallSelector& selector, Method* matched) {
        logger->add_method_with_selector(selector, matched);
        method_queue.push_back(matched);
        // Allow the removal of the now handled method.
        return true;
      });
    }

    // No need to look for selectors we already know about.
    found_selectors.erase_all(handled_selectors);

    if (!found_selectors.empty() || !found_typed_selectors.empty()) {
      for (auto klass : grown_classes_) {
        auto queryable = queryables[klass];
        for (auto selector : found_selectors) {
          auto probe = queryable.lookup(selector);
          if (probe != null) {
            logger->add_method_with_selector(selector, probe);
            method_queue.push_back(probe);
          }
        }
        found_typed_selectors.match_and_filter(queryable,
                                               [&](const CallSelector& selector, Method* matched) {
          logger->add_method_with_selector(selector, matched);
          method_queue.push_back(matched);
          // Allow the removal of the now handled method.
          return true;
        });
      }
    }

    handled_selectors.insert_all(found_selectors);
    // Add the newly found typed selectors, but ignore them for
    // known methods and for selectors that are already matching everything.
    handled_typed_selectors.insert_all(found_typed_selectors,
                                       grown_methods_,
                                       handled_selectors);
  }

  logger->print();

  for (auto klass : grown_classes_) {
    klass->set_is_instantiated(true);
  }

  // Add superclasses as grown classes.
  // We didn't add them earlier, since their methods aren't needed if they have
  // been overridden.
  std::vector<Class*> super_classes;
  for (auto klass : grown_classes_) {
    auto current = klass->super();
    while (current != null) {
      if (grown_classes_.contains(current)) break;
      super_classes.push_back(current);
      current->set_is_instantiated(false);
      current = current->super();
    }
  }
  grown_classes_.insert(super_classes.begin(), super_classes.end());
}

class Fixup : public ReplacingVisitor {
 public:
  explicit Fixup(Set<Class*>& grown_classes,
                 Set<Method*>& grown_methods,
                 Type null_type,
                 Method* as_check_failure)
      : null_type_(null_type)
      , grown_methods_(grown_methods)
      , as_check_failure_(as_check_failure) {
    valid_check_targets_.insert_all(grown_classes);

    for (auto klass : grown_classes) {
      for (auto interface : klass->interfaces()) {
        valid_check_targets_.insert(interface);
      }
      for (auto current = klass; current != null; current = current->super()) {
        if (current != klass && valid_check_targets_.contains(current)) {
          // No need to duplicate work. The current class will be (or was already)
          // traversed independently.
          break;
        }
        for (auto method : current->methods()) {
          // This looks like the simplest way to figure out whether a class
          // "implements" a mixin.
          if (method->is_IsInterfaceOrMixinStub()) {
            valid_check_targets_.insert(method->as_IsInterfaceOrMixinStub()->interface_or_mixin());
          }
        }
      }
    }
  }

  Node* visit_Typecheck(Typecheck* node) {
    auto result = ReplacingVisitor::visit_Typecheck(node)->as_Typecheck();
    ASSERT(result == node);
    if (node->type().is_any()) return node;
    if (valid_check_targets_.contains(node->type().klass())) return result;

    // At this point, neither the class nor any of its subclasses were instantiated.

    if (node->type().is_nullable()) {
      // Simply replace the original type with `Null_`.
      return _new Typecheck(node->kind(),
                            node->expression(),
                            null_type_.to_nullable(),  // So the error message is more correct.
                            node->type_name(),
                            node->range());
    }

    // At this point we know that the expression can't satisfy the type.

    if (!node->is_as_check()) {
      // We just need to evaluate (for effect) the expression
      //   and then materialize `false`.
      auto expressions =  ListBuilder<Expression*>::build(
        node->expression(),
        _new LiteralBoolean(false, node->range()));
      return _new Sequence(expressions, node->range());
    }

    // For as-checks we create a call to `as_check_failure` with the expression as argument.
    const char* name = node->type().klass()->name().c_str();
    ListBuilder<Expression*> arguments_builder;
    arguments_builder.add(node->expression());
    arguments_builder.add(_new LiteralString(name, strlen(name), node->range()));
    auto arguments = arguments_builder.build();
    auto shape = CallShape::for_static_call_no_named(arguments);
    auto fail_call = _new CallStatic(_new ReferenceMethod(as_check_failure_, node->range()),
                                     shape,
                                     arguments,
                                     node->range());
    return fail_call;
  }

  Expression* visit_CallStatic(CallStatic* node) {
    auto result = ReplacingVisitor::visit_CallStatic(node)->as_CallStatic();
    ASSERT(result == node);
    Method* method = node->target()->target();
    if (!grown_methods_.contains(method)) {
      // The static method or constructor is unreachable. This might be
      // because our type propagation phase has told us that the method
      // is dead, but this can also happen when we have changed a dynamic
      // call to a static call, and then tree shake the target. Either way,
      // we just ignore the call, but still evaluate all parameters.
      auto arguments = node->arguments();
      if (arguments.length() == 1) return arguments[0];
      return _new Sequence(arguments, node->range());
    }
    return node;
  }

  Node* visit_FieldLoad(FieldLoad* node) {
    auto result = ReplacingVisitor::visit_FieldLoad(node);
    auto holder = node->field()->holder();
    if (valid_check_targets_.contains(holder)) {
      return result;
    }
    // The load is dead code, as a type-check earlier would have thrown earlier.
    // Drop the load.
    return node->receiver();
  }

  Node* visit_FieldStore(FieldStore* node) {
    auto result = ReplacingVisitor::visit_FieldStore(node);
    auto holder = node->field()->holder();
    if (valid_check_targets_.contains(holder)) {
      return result;
    }
    // The store is dead code, as a type-check earlier would have thrown earlier.
    // Drop the store.
    return _new Sequence(ListBuilder<Expression*>::build(node->receiver(), node->value()),
                         node->range());
  }

 private:
  Type null_type_;
  Set<Class*> valid_check_targets_;
  Set<Method*> grown_methods_;
  Method* as_check_failure_;
};

template<class T>
static List<T*> shake_methods(List<T*> methods,
                              const Set<Method*>& grown_methods) {
  ListBuilder<T*> remaining_methods;
  for (auto method : methods) {
    if (grown_methods.contains(method)) {
      remaining_methods.add(method);
    }
  }
  return remaining_methods.build();
}

static std::vector<Method*> shake_methods(std::vector<Method*> methods,
                                          const Set<Method*>& grown_methods) {
  std::vector<Method*> remaining_methods;
  for (auto method : methods) {
    if (grown_methods.contains(method)) {
      remaining_methods.push_back(method);
    }
  }
  return remaining_methods;
}

static void shake(Program* program,
                  Set<Class*> grown_classes,
                  Set<Method*> grown_methods) {
  auto null_type = Type::invalid();
  for (auto type : program->literal_types()) {
    if (type.klass()->name() == Symbols::Null_) {
      null_type = type;
      break;
    }
  }
  ASSERT(null_type.is_valid());

  ListBuilder<Class*> remaining_classes;
  // Keep the order of the classes.
  for (auto klass : program->classes()) {
    if (klass->is_mixin() || grown_classes.contains(klass)) {
      remaining_classes.add(klass);
    }
  }
  if (Flags::report_tree_shaking) {
    int remaining_classes_length = remaining_classes.length();
    int program_classes_length = program->classes().length();
    printf("Kept %d out of %d classes\n",
           remaining_classes_length,
           program_classes_length);
  }
  program->replace_classes(remaining_classes.build());

  auto remaining_methods = shake_methods(program->methods(), grown_methods);
  if (Flags::report_tree_shaking) {
    int remaining_methods_length = remaining_methods.length();
    int program_methods_length = program->methods().length();
    printf("Kept %d out of %d global functions\n",
           remaining_methods_length,
           program_methods_length);
  }
  program->replace_methods(remaining_methods);

  ListBuilder<Global*> remaining_globals;
  for (auto global : program->globals()) {
    if (grown_methods.contains(global)) {
      remaining_globals.add(global);
    }
  }
  if (Flags::report_tree_shaking) {
    int remaining_globals_length = remaining_globals.length();
    int program_globals_length = program->globals().length();
    printf("Kept %d out of %d globals\n",
           remaining_globals_length,
           program_globals_length);
  }
  program->replace_globals(remaining_globals.build());

  // Shake constructors, factories, and instance methods.
  int total_methods_count = 0;
  int remaining_methods_count = 0;
  for (auto klass : program->classes()) {
    // Note that we already shook the copies of constructors/factories/statics that had
    //   been copied into program->methods.
    auto remaining_constructors = shake_methods(klass->unnamed_constructors(), grown_methods);
    klass->replace_unnamed_constructors(remaining_constructors);
    auto remaining_factories = shake_methods(klass->factories(), grown_methods);
    klass->replace_factories(remaining_factories);
    klass->statics()->invalidate_resolution_map();
    auto remaining_statics = shake_methods(klass->statics()->nodes(), grown_methods);
    klass->statics()->replace_nodes(remaining_statics);
    auto remaining_methods = shake_methods(klass->methods(), grown_methods);
    total_methods_count += klass->methods().length();
    remaining_methods_count += remaining_methods.length();
    klass->replace_methods(remaining_methods);
  }
  if (Flags::report_tree_shaking) {
    printf("Kept %d out of %d instance methods\n",
           remaining_methods_count,
           total_methods_count);
  }

  // Fixup references to types and methods that don't exist anymore.
  Fixup visitor(grown_classes,
                grown_methods,
                null_type,
                program->as_check_failure());
  for (auto method : grown_methods) {
    auto result = visitor.visit(method);
    ASSERT(result == method);
  }
}

void tree_shake(Program* program) {
  if (Flags::disable_tree_shaking) {
    // Just remove the abstract methods, so that later phases don't need to deal with non-existing bodies.
    for (auto klass : program->classes()) {
      if (!klass->is_abstract()) continue;
      ListBuilder<MethodInstance*> non_abstract_methods;
      for (auto method : klass->methods()) {
        if (!method->is_abstract()) non_abstract_methods.add(method);
      }
      klass->replace_methods(non_abstract_methods.build());
    }
    return;
  }

  TreeGrower grower;
  grower.grow(program);

  shake(program,
        grower.grown_classes(),
        grower.grown_methods());
}

} // namespace toit::compiler
} // namespace toit
