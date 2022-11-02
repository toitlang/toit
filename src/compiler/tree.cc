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

namespace toit {
namespace compiler {

using namespace ir;

typedef Selector<CallShape> CallSelector;

class GrowerVisitor : public TraversingVisitor {
 public:
  explicit GrowerVisitor(Method* identical, Method* as_check_failure)
      : identical_(identical), as_check_failure_(as_check_failure) {}

  Set<Class*> found_classes() const { return found_classes_; }
  Set<Method*> found_methods() const { return found_methods_; }
  Set<CallSelector> found_selectors() const { return found_selectors_; }

  void visit_CallConstructor(CallConstructor* node) {
    found_classes_.insert(node->klass());
    found_methods_.insert(node->target()->target());
    TraversingVisitor::visit_CallConstructor(node);
  }

  void visit_CallStatic(CallStatic* node) {
    found_methods_.insert(node->target()->target());
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
    if (node->type().is_nullable()) found_methods_.insert(identical_);
    if (node->is_as_check()) found_methods_.insert(as_check_failure_);
    if (node->is_interface_check()) {
      found_selectors_.insert(node->type().klass()->typecheck_selector());
    }
    TraversingVisitor::visit_Typecheck(node);
  }

 private:
  ir::Method* identical_;
  ir::Method* as_check_failure_;
  Set<Class*> found_classes_;
  Set<Method*> found_methods_;
  Set<CallSelector> found_selectors_;
};

class TreeLogger {
 public:
  virtual void root(Method* method) { }
  virtual void root(Class* klass) { }
  virtual void add(Method* method,
                   Set<Class*> classes,
                   Set<Method*> methods,
                   Set<CallSelector> selectors) { }
  virtual void add_method_with_selector(CallSelector selector, Method* method) { }

  virtual void print() { }
};

class GraphvizTreeLogger : public TreeLogger {
 public:
  GraphvizTreeLogger() { }

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
  void grow(ir::Program* program);

  Set<Class*> grown_classes() const { return grown_classes_; }
  // Includes globals, static functions and instance functions.
  Set<Method*> grown_methods() const { return grown_methods_; }

 private:
  Set<Class*> grown_classes_;
  Set<Method*> grown_methods_;
};

void TreeGrower::grow(Program* program) {
  auto queryables = build_queryables_from_plain_shapes(program->classes());

  Set<CallSelector> handled_selectors;

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
    Set<CallSelector> found_selectors;

    for (auto method : method_queue) {
      if (method->is_abstract()) continue;

      GrowerVisitor visitor(program->identical(), program->as_check_failure());
      // Skip already visited methods.
      if (grown_methods_.contains(method)) continue;
      grown_methods_.insert(method);
      visitor.visit(method);
      logger->add(method, visitor.found_classes(), visitor.found_methods(), visitor.found_selectors());
      found_classes.insert_all(visitor.found_classes());
      found_methods.insert_all(visitor.found_methods());
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
    }

    found_selectors.erase_all(handled_selectors);
    handled_selectors.insert(found_selectors.begin(), found_selectors.end());
    if (!found_selectors.empty()) {
      for (auto klass : grown_classes_) {
        auto queryable = queryables[klass];
        for (auto selector : found_selectors) {
          auto probe = queryable.lookup(selector);
          if (probe != null) {
            logger->add_method_with_selector(selector, probe);
            method_queue.push_back(probe);
          }
        }
      }
    }
  }

  logger->print();

  for (auto klass : grown_classes_) {
    klass->set_is_instantiated(true);
  }

  // Add superclasses as grown classes.
  // We didn't add them earlier, since their methods aren't needed if they have
  // been overridden.
  std::vector<ir::Class*> super_classes;
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
                 UnorderedSet<Method*>& unreachable_methods,
                 Type null_type,
                 Method* as_check_failure)
      : null_type_(null_type)
      , unreachable_methods_(unreachable_methods)
      , as_check_failure_(as_check_failure) {
    grown_classes_and_interfaces_.insert_all(grown_classes);

    std::function<void (Class*)> add_interface;
    add_interface = [&](Class* interface) {
      if (grown_classes_and_interfaces_.contains(interface)) return;
      grown_classes_and_interfaces_.insert(interface);
      for (auto sub_interface : interface->interfaces()) {
        add_interface(sub_interface);
      }
      if (interface->super() != null) {
        add_interface(interface->super());
      }
    };

    for (auto klass : grown_classes) {
      for (auto interface : klass->interfaces()) {
        add_interface(interface);
      }
    }
  }

  Node* visit_Typecheck(Typecheck* node) {
    auto result = ReplacingVisitor::visit_Typecheck(node)->as_Typecheck();
    ASSERT(result == node);
    if (node->type().is_any()) return node;
    if (grown_classes_and_interfaces_.contains(node->type().klass())) return result;

    // At this point, neither the class nor any of its subclasses were instantiated.

    if (node->type().is_nullable()) {
      // Simply replace the original type with `Null_`.
      return _new ir::Typecheck(node->kind(),
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
    ListBuilder<ir::Expression*> arguments_builder;
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
    if (unreachable_methods_.contains(method)) {
      ASSERT(method->is_MethodInstance());
      // We changed a dynamic call to a static call, but the target doesn't exist anymore.
      // Just ignore the call, but still evaluate all parameters.
      auto arguments = node->arguments();
      if (arguments.length() == 1) return arguments[0];
      return _new Sequence(arguments, node->range());
    }
    return node;
  }

  Node* visit_FieldLoad(FieldLoad* node) {
    auto result = ReplacingVisitor::visit_FieldLoad(node);
    auto holder = node->field()->holder();
    if (grown_classes_and_interfaces_.contains(holder)) {
      return result;
    }
    // The load is dead code, as a type-check earlier would have thrown earlier.
    // Drop the load.
    return node->receiver();
  }

  Node* visit_FieldStore(FieldStore* node) {
    auto result = ReplacingVisitor::visit_FieldStore(node);
    auto holder = node->field()->holder();
    if (grown_classes_and_interfaces_.contains(holder)) {
      return result;
    }
    // The store is dead code, as a type-check earlier would have thrown earlier.
    // Drop the store.
    return _new Sequence(ListBuilder<ir::Expression*>::build(node->receiver(), node->value()),
                         node->range());
  }

 private:
  Type null_type_;
  Set<Class*> grown_classes_and_interfaces_;
  UnorderedSet<Method*> unreachable_methods_;
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

static void shake(ir::Program* program,
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

  ListBuilder<ir::Class*> remaining_classes;
  // Keep the order of the classes.
  for (auto klass : program->classes()) {
    if (grown_classes.contains(klass)) {
      remaining_classes.add(klass);
    }
  }
  if (Flags::report_tree_shaking) {
    printf("Kept %d out of %d classes\n",
           remaining_classes.length(),
           program->classes().length());
  }
  program->replace_classes(remaining_classes.build());

  // The set of grown methods might contain methods that aren't actually reachable.
  // This can happen when the optimizer changed a dynamic call into a static call, but
  //   the receiver-type was never instantiated.
  // The following set contains all methods that were grown, but not added to the program.
  UnorderedSet<ir::Method*> unreachable_methods;
  unreachable_methods.insert_all(grown_methods);  // Starts out with all grown methods.

  auto remaining_methods = shake_methods(program->methods(), grown_methods);
  unreachable_methods.erase_all(remaining_methods);
  if (Flags::report_tree_shaking) {
    printf("Kept %d out of %d global functions\n",
           remaining_methods.length(),
           program->methods().length());
  }
  program->replace_methods(remaining_methods);

  ListBuilder<ir::Global*> remaining_globals;
  for (auto global : program->globals()) {
    if (grown_methods.contains(global)) {
      remaining_globals.add(global);
      unreachable_methods.erase(global);
    }
  }
  if (Flags::report_tree_shaking) {
    printf("Kept %d out of %d globals\n",
           remaining_globals.length(),
           program->globals().length());
  }
  program->replace_globals(remaining_globals.build());

  // Shake constructors, factories, and instance methods.
  int total_methods_count = 0;
  int remaining_methods_count = 0;
  for (auto klass : program->classes()) {
    // Note that we already shook the copies of constructors/factories/statics that had
    //   been copied into program->methods.
    auto remaining_constructors = shake_methods(klass->constructors(), grown_methods);
    unreachable_methods.erase_all(remaining_constructors);
    klass->replace_constructors(remaining_constructors);
    auto remaining_factories = shake_methods(klass->factories(), grown_methods);
    klass->replace_factories(remaining_factories);
    unreachable_methods.erase_all(remaining_factories);
    klass->statics()->invalidate_resolution_map();
    auto remaining_statics = shake_methods(klass->statics()->nodes(), grown_methods);
    klass->statics()->replace_nodes(remaining_statics);
    unreachable_methods.erase_all(remaining_factories);
    auto remaining_methods = shake_methods(klass->methods(), grown_methods);
    total_methods_count += klass->methods().length();
    remaining_methods_count += remaining_methods.length();
    klass->replace_methods(remaining_methods);
    unreachable_methods.erase_all(remaining_methods);
  }
  if (Flags::report_tree_shaking) {
    printf("Kept %d out of %d instance methods\n",
           remaining_methods_count,
           total_methods_count);
  }

  // Fixup references to types and methods that don't exist anymore.
  Fixup visitor(grown_classes,
                unreachable_methods,
                null_type,
                program->as_check_failure());
  for (auto method : grown_methods) {
    auto result = visitor.visit(method);
    ASSERT(result == method);
  }
}

void tree_shake(ir::Program* program) {
  if (Flags::disable_tree_shaking) {
    // Just remove the abstract methods, so that later phases don't need to deal with non-existing bodies.
    for (auto klass : program->classes()) {
      if (!klass->is_abstract()) continue;
      ListBuilder<ir::MethodInstance*> non_abstract_methods;
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
