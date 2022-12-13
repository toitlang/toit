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

#include "list.h"
#include "token.h"
#include "sources.h"
#include "selector.h"
#include "symbol.h"
#include "../bytecodes.h"

namespace toit {
namespace compiler {

class DispatchTable;
class DispatchTableBuilder;
class Resolver;
class Scope;
class StaticsScope;

namespace ir {

class Node;

#define IR_NODES(V)             \
  V(Program)                    \
  V(Global)                     \
  V(Class)                      \
  V(Field)                      \
  V(Method)                     \
  V(MethodInstance)             \
  V(MonitorMethod)              \
  V(MethodStatic)               \
  V(Constructor)                \
  V(AdapterStub)                \
  V(IsInterfaceStub)            \
  V(FieldStub)                  \
  V(Code)                       \
  V(Block)                      \
  V(Sequence)                   \
  V(TryFinally)                 \
  V(Builtin)                    \
  V(If)                         \
  V(Not)                        \
  V(While)                      \
  V(LoopBranch)                 \
  V(Expression)                 \
  V(Error)                      \
  V(Nop)                        \
  V(FieldLoad)                  \
  V(FieldStore)                 \
  V(Super)                      \
  V(Call)                       \
  V(CallConstructor)            \
  V(CallStatic)                 \
  V(Lambda)                     \
  V(CallVirtual)                \
  V(CallBlock)                  \
  V(CallBuiltin)                \
  V(Typecheck)                  \
  V(Return)                     \
  V(Reference)                  \
  V(ReferenceClass)             \
  V(ReferenceMethod)            \
  V(ReferenceLocal)             \
  V(ReferenceBlock)             \
  V(ReferenceGlobal)            \
  V(LogicalBinary)              \
  V(Assignment)                 \
  V(AssignmentLocal)            \
  V(AssignmentGlobal)           \
  V(AssignmentDefine)           \
  V(Local)                      \
  V(Parameter)                  \
  V(CapturedLocal)              \
  V(Literal)                    \
  V(LiteralNull)                \
  V(LiteralUndefined)           \
  V(LiteralInteger)             \
  V(LiteralFloat)               \
  V(LiteralString)              \
  V(LiteralByteArray)           \
  V(LiteralBoolean)             \
  V(PrimitiveInvocation)        \
  V(Dot)                        \
  V(LspSelectionDot)            \

#define DECLARE(name) class name;
IR_NODES(DECLARE)
#undef DECLARE

class Visitor {
 public:
  virtual void visit(Node* node);

#define DECLARE(name) virtual void visit_##name(name* node) = 0;
IR_NODES(DECLARE)
#undef DECLARE
};

class TraversingVisitor : public Visitor {
 public:
#define DECLARE(name) virtual void visit_##name(name* node);
IR_NODES(DECLARE)
#undef DECLARE
};

template<typename T> class ReturningVisitor {
 public:
#define DECLARE(name) virtual T visit_##name(name* node) = 0;
IR_NODES(DECLARE)
#undef DECLARE
};

class ReplacingVisitor : public ReturningVisitor<Node*> {
 public:
  virtual Node* visit(Node* node);

#define DECLARE(name) virtual Node* visit_##name(name* node);
IR_NODES(DECLARE)
#undef DECLARE

 private:
  Expression* _replace_expression(Expression* expression);
};

class Type {
 public:
  explicit Type(Class* klass) : kind_(kClass), class_(klass), is_nullable_(false) {
    ASSERT(klass != null);
  }

  static Type none() { return Type(kNone, false); }
  static Type any()  { return Type(kAny, true); }
  static Type invalid() { return Type(kInvalid, false); }

  bool is_nullable() const { return is_nullable_; }

  bool is_class() const { return kind_ == kClass; }
  bool is_none() const { return kind_ == kNone; }
  bool is_any() const { return kind_ == kAny; }
  bool is_valid() const { return kind_ != kInvalid; }
  bool is_special() const { return is_none() || is_any() || !is_valid(); }

  Class* klass() const { return class_; }

  Type to_nullable() const {
    if (is_special()) return *this;
    return Type(kind_, class_, true);
  }

  Type to_non_nullable() const {
    if (is_none() || !is_valid()) return *this;
    return Type(kind_, class_, false);
  }

  bool operator ==(const Type& other) const {
    return kind_ == other.kind_ && class_ == other.class_;
  }
  bool operator !=(const Type& other) const {
    return !(*this == other);
  }

 private:
  static const int kClass = 0;
  static const int kNone = 1;
  static const int kAny = 2;
  static const int kInvalid = 3;

  Type(int kind, bool is_nullable)
      : kind_(kind), class_(null), is_nullable_(is_nullable) {}

  Type(int kind, Class* klass, bool is_nullable)
      : kind_(kind), class_(klass), is_nullable_(is_nullable) {}

  friend class ListBuilder<Type>;
  Type() {}

  int kind_;
  Class* class_;
  bool is_nullable_;
};

class Node {
 public:
#define DECLARE(name)                              \
  virtual bool is_##name() const { return false; } \
  virtual name* as_##name() { return null; }
IR_NODES(DECLARE)
#undef DECLARE

  virtual void accept(Visitor* visitor) = 0;
  virtual Node* accept(ReturningVisitor<Node*>* visitor) = 0;
  virtual Type accept(ReturningVisitor<Type>* visitor) = 0;
  virtual const char* node_type() const { return "Node"; }

  void print(bool use_resolution_shape);
};

#define IMPLEMENTS(name)                                                 \
  virtual void accept(Visitor* visitor) { visitor->visit_##name(this); } \
  virtual Node* accept(ReturningVisitor<Node*>* visitor) { return visitor->visit_##name(this); } \
  virtual Type accept(ReturningVisitor<Type>* visitor) { return visitor->visit_##name(this); } \
  virtual bool is_##name() const { return true; }                        \
  virtual name* as_##name() { return this; }                             \
  virtual const char* node_type() const { return #name; }

class Program : public Node {
 public:
  Program(List<Class*> classes,
          List<Method*> methods,
          List<Global*> globals,
          List<Class*> tree_roots,
          List<Method*> entry_points,
          List<Type> literal_types,
          Method* lookup_failure,
          Method* as_check_failure,
          Class* lambda_box)
      : classes_(classes)
      , methods_(methods)
      , globals_(globals)
      , tree_roots_(tree_roots)
      , entry_points_(entry_points)
      , literal_types_(literal_types)
      , lookup_failure_(lookup_failure)
      , as_check_failure_(as_check_failure)
      , lambda_box_(lambda_box) {}
  IMPLEMENTS(Program)

  List<Class*> classes() const { return classes_; }
  List<Method*> methods() const { return methods_; }
  List<Global*> globals() const { return globals_; }

  void replace_classes(List<Class*> new_classes) { classes_ = new_classes; }
  void replace_methods(List<Method*> new_methods) { methods_ = new_methods; }
  void replace_globals(List<Global*> new_globals) { globals_ = new_globals; }

  void set_methods(List<Method*> methods) {
    methods_ = methods;
  }

  Method* lookup_failure() const { return lookup_failure_; }
  Method* as_check_failure() const { return as_check_failure_; }

  Class* lambda_box() const { return lambda_box_; }

  List<Class*> tree_roots() const { return tree_roots_; }

  List<Method*> entry_points() const { return entry_points_; }

  List<Type> literal_types() const { return literal_types_; }

 private:
  List<Class*> classes_;
  List<Method*> methods_;
  List<Global*> globals_;
  List<Class*> tree_roots_;
  List<Method*> entry_points_;
  List<Type> literal_types_;
  Method* lookup_failure_;
  Method* as_check_failure_;
  Class* lambda_box_;
};

class Class : public Node {
 public:
  Class(Symbol name, bool is_interface, bool is_abstract, Source::Range range)
      : name_(name)
      , range_(range)
      , is_runtime_class_(false)
      , super_(null)
      , is_abstract_(is_abstract)
      , is_interface_(is_interface)
      , typecheck_selector_(Selector<CallShape>(Symbol::invalid(), CallShape::invalid()))
      , id_(-1)
      , start_id_(-1)
      , end_id_(-1)
      , first_subclass_(null)
      , subclass_sibling_link_(null)
      , total_field_count_(-1) {}
  IMPLEMENTS(Class)

  Symbol name() const { return name_; }
  bool has_super() const { return super_ != null; }
  /// The id of this class.
  /// This value is only set in the dispatch-table builder and must not be
  ///   used earlier.
  int id() const {
    ASSERT(id_ != -1);
    return id_;
  }

  bool is_task_class() const { return is_runtime_class_ && name_ == Symbols::Task_; }
  bool is_runtime_class() const { return is_runtime_class_; }
  void mark_runtime_class() { is_runtime_class_ = true; }

  Class* super() const { return super_; }
  void set_super(Class* klass) {
    ASSERT(super_ == null);
    super_ = klass;
  }
  void replace_super(Class* klass) {
    super_ = klass;
  }

  List<Class*> interfaces() const { return interfaces_; }
  void set_interfaces(List<Class*> interfaces) {
    ASSERT(interfaces_.is_empty());
    interfaces_ = interfaces;
  }
  void replace_interfaces(List<Class*> interfaces) {
    interfaces_ = interfaces;
  }

  /// The unnamed constructors.
  ///
  /// The named constructors are stored in the [statics] scope.
  List<Method*> constructors() const { return constructors_; }
  void set_constructors(List<Method*> constructors) {
    ASSERT(constructors_.is_empty());
    constructors_ = constructors;
  }
  void replace_constructors(List<Method*> new_constructors) { constructors_ = new_constructors; }

  /// The unnamed factories.
  ///
  /// The named factories are stored in the [statics] scope.
  List<Method*> factories() const { return factories_; }
  void set_factories(List<Method*> factories) {
    ASSERT(factories_.is_empty());
    factories_ = factories;
  }
  void replace_factories(List<Method*> new_factories) { factories_ = new_factories; }

  StaticsScope* statics() const { return statics_; }
  void set_statics(StaticsScope* statics) {
    ASSERT(statics_ == null);
    statics_ = statics;
  }

  /// The elements visible for toitdoc scopes.
  /// This includes constructors, static/instance methods, static/instance fields all
  ///   mixed together.
  Scope* toitdoc_scope() const { return toitdoc_scope_; }
  void set_toitdoc_scope(Scope* scope) { toitdoc_scope_ = scope; }

  List<MethodInstance*> methods() const { return methods_; }
  void set_methods(List<MethodInstance*> methods) {
    ASSERT(methods_.is_empty());
    methods_ = methods;
  }
  void replace_methods(List<MethodInstance*> new_methods) { methods_ = new_methods; }

  List<Field*> fields() const { return fields_; }
  void set_fields(List<Field*> fields) { fields_ = fields; }

  bool is_abstract() const { return is_abstract_; }

  bool is_interface() const { return is_interface_; }

  Source::Range range() const { return range_; }

  /// These functions are set by the tree-shaker.
  bool is_instantiated() const { return is_instantiated_; }
  void set_is_instantiated(bool value) { is_instantiated_ = value; }

  Selector<CallShape> typecheck_selector() const { return typecheck_selector_; }
  void set_typecheck_selector(Selector<CallShape> selector) {
    ASSERT(is_interface());
    typecheck_selector_ = selector;
  }

  // A token that is dependent on the class' location.
  // Returns -1 if there is no location attached to this class.
  int location_id() const {
    auto range = this->range();
    if (!range.is_valid()) return -1;
    return range.from().token();
  }

 private:
  const Symbol name_;
  Source::Range range_;
  bool is_runtime_class_;
  Class* super_;
  List<Class*> interfaces_;
  bool is_abstract_;
  bool is_interface_;
  // Only set for interfaces.
  Selector<CallShape> typecheck_selector_;

  List<Method*> constructors_;
  List<Method*> factories_;
  List<MethodInstance*> methods_;
  List<Field*> fields_;

  StaticsScope* statics_ = null;
  Scope* toitdoc_scope_ = null;

  bool is_instantiated_ = true;

  int id_;
  int start_id_;
  int end_id_;

 private:
  // This is redundant information.
  // For now we restrict its use to the resolver, so that modifications to the
  // program structure don't need to update these fields.
  friend class ::toit::compiler::Resolver;

  Class* first_subclass_;
  Class* subclass_sibling_link_;

  Class* first_subclass() { return first_subclass_; }
  Class* subclass_sibling() { return subclass_sibling_link_; }

  void link_subclass(Class* next_subclass) {
    next_subclass->subclass_sibling_link_ = first_subclass_;
    first_subclass_ = next_subclass;
  }

 public:
  // Reserved for DispatchTable and the backend:

  /// Every class in the range `start_id` .. `end_id`(exclusive) is a subclass
  /// of this class. The `start_id` might me the class itself (equal to `id()`).
  /// When this class is not instantiated, then the start_id does not include this
  /// class.
  int start_id() const { return start_id_; }
  int end_id() const { return end_id_; }

  void set_id(int id) {
    ASSERT(id_ == -1);
    id_ = id;
  }

  void set_start_id(int id) {
    ASSERT(start_id_ == -1);
    start_id_ = id;
  }

  void set_end_id(int end_id) {
    ASSERT(end_id_ == -1);
    end_id_ = end_id;
  }

 public:
  // Reserved for Compiler and ByteGen.
  int total_field_count() const { return total_field_count_; }
  void set_total_field_count(int count) {
    ASSERT(total_field_count_ == -1);
    total_field_count_ = count;
  }

  int total_field_count_;
};

class Method : public Node {
 public:

  enum MethodKind {
    INSTANCE,
    GLOBAL_FUN,
    GLOBAL_INITIALIZER,
    CONSTRUCTOR,
    FACTORY,
    FIELD_INITIALIZER,  // Only used temporary during resolution.
  };

 protected:
  explicit Method(Symbol name,
                  Class* holder,  // `null` if not inside a class.
                  const ResolutionShape& shape,
                  bool is_abstract,
                  MethodKind kind,
                  Source::Range range)
      : name_(name)
      , holder_(holder)
      , return_type_(Type::invalid())
      , use_resolution_shape_(true)
      , resolution_shape_(shape)
      , plain_shape_(PlainShape::invalid())
      , is_abstract_(is_abstract)
      , does_not_return_(false)
      , is_runtime_method_(false)
      , kind_(kind)
      , range_(range)
      , body_(null)
      , index_(-1) {}

  explicit Method(Symbol name,
                  Class* holder,  // `null` if not inside a class.
                  const PlainShape& shape,
                  bool is_abstract,
                  MethodKind kind,
                  Source::Range range)
      : name_(name)
      , holder_(holder)
      , return_type_(Type::invalid())
      , use_resolution_shape_(false)
      , resolution_shape_(ResolutionShape::invalid())
      , plain_shape_(shape)
      , is_abstract_(is_abstract)
      , does_not_return_(false)
      , is_runtime_method_(false)
      , kind_(kind)
      , range_(range)
      , body_(null)
      , index_(-1) {}

 public:
  IMPLEMENTS(Method)

  Symbol name() const { return name_; }

  /// The shape of this method, as used during resolution.
  ///
  /// A resolution-shape may represent multiple method signatures. It can have
  /// optional arguments, and all arguments may be used with their respective
  /// names (if they are available).
  ResolutionShape resolution_shape() const {
    ASSERT(use_resolution_shape_ && resolution_shape_.is_valid());
    return resolution_shape_;
  }

  /// The resolution shape of this method without any implicit this.
  ResolutionShape resolution_shape_no_this() const {
    ASSERT(use_resolution_shape_ && resolution_shape_.is_valid());
    if (is_instance() || is_constructor()) {
      return resolution_shape_.without_implicit_this();
    }
    return resolution_shape_;
  }

  /// The unique shape of this method.
  ///
  /// This shape does not contain any optional parameters anymore.
  /// If it has named arguments, these are required.
  PlainShape plain_shape() const {
    ASSERT(!use_resolution_shape_ && plain_shape_.is_valid());
    return plain_shape_;
  }
  void set_plain_shape(const PlainShape& shape) {
    plain_shape_ = shape;
    resolution_shape_ = ResolutionShape::invalid();
    use_resolution_shape_ = false;
  }

  MethodKind kind() const { return kind_; }

  bool is_static() const { return !is_instance(); }
  bool is_global_fun() const { return kind() == GLOBAL_FUN; }
  bool is_instance() const { return kind() == INSTANCE || kind() == FIELD_INITIALIZER; }
  bool is_constructor() const { return kind() == CONSTRUCTOR; }
  bool is_factory() const { return kind() == FACTORY; }
  bool is_initializer() const { return kind() == GLOBAL_INITIALIZER; }
  bool is_field_initializer() const { return kind() == FIELD_INITIALIZER; }
  bool is_setter() const {
    if (use_resolution_shape_) return resolution_shape().is_setter();
    return plain_shape().is_setter();
  }

  bool has_implicit_this() const {
    return is_instance() || is_constructor();
  }

  bool is_abstract() const { return is_abstract_; }
  bool has_body() const { return body_ != null; }

  bool does_not_return() const { return does_not_return_; }
  void mark_does_not_return() { does_not_return_ = true; }

  bool is_runtime_method() const { return is_runtime_method_; }
  void mark_runtime_method() { is_runtime_method_ = true; }

  Type return_type() const { return return_type_; }
  void set_return_type(Type type) {
    ASSERT(!return_type_.is_valid());
    return_type_ = type;
  }
  Expression* body() const { return body_; }
  void set_body(Expression* body) {
    ASSERT(body_ == null);
    body_ = body;
  }

  void replace_body(Expression* new_body) { body_ = new_body; }

  bool is_dead() const { return is_dead_; }
  void kill() { is_dead_ = true; }

  List<Parameter*> parameters() const { return parameters_; }
  void set_parameters(List<Parameter*> parameters) {
    ASSERT(_parameters_have_correct_index(parameters));
    parameters_ = parameters;
  }

  /// Returns the syntactic holder of this method.
  /// Static functions that are declared inside a class have a holder.
  Class* holder() const { return holder_; }

  Source::Range range() const { return range_; }

  virtual bool is_synthetic() const {
    return kind_ == FIELD_INITIALIZER;
  }

 private:
  const Symbol name_;
  Class* holder_;

  Type return_type_;

  bool use_resolution_shape_;

  // The `MethodShape` is used for resolution. It represents all possible
  // shapes a method can take. For example, it can have default-values, ...
  ResolutionShape resolution_shape_;

  // The `InstanceMethodShape` is used after resolution and only valid
  // for instance methods. Static methods don't need any shape after resolution
  // anymore.
  // It represents one (and only one) shape of the possible calling-conventions
  // of the method-shape.
  PlainShape plain_shape_;

  const bool is_abstract_;
  bool does_not_return_;
  bool is_runtime_method_;
  const MethodKind kind_;
  const Source::Range range_;

  List<Parameter*> parameters_;
  Expression* body_;
  bool is_dead_ = false;

  static bool _parameters_have_correct_index(List<Parameter*> parameters);

 private:
  friend class ::toit::compiler::DispatchTable;
  friend class ::toit::compiler::DispatchTableBuilder;

  // The global index during emission.
  int index_;

  int index() const {
    ASSERT(index_ != -1);
    return index_;
  }
  bool index_is_set() const {
    return index_ != -1;
  }
  void set_index(int index) {
    ASSERT(index_ == -1);
    index_ = index;
  }
};

class MethodInstance : public Method {
 public:
  MethodInstance(Symbol name, Class* holder, const ResolutionShape& shape, bool is_abstract, Source::Range range)
      : Method(name, holder, shape, is_abstract, INSTANCE, range) {}
  MethodInstance(Symbol name, Class* holder, const PlainShape& shape, bool is_abstract, Source::Range range)
      : Method(name, holder, shape, is_abstract, INSTANCE, range) {}
  MethodInstance(Method::MethodKind kind, Symbol name, Class* holder, const ResolutionShape& shape, bool is_abstract, Source::Range range)
      : Method(name, holder, shape, is_abstract, kind, range) {}
  IMPLEMENTS(MethodInstance)
};

class MonitorMethod : public MethodInstance {
 public:
  MonitorMethod(Symbol name, Class* holder, const ResolutionShape& shape, Source::Range range)
      : MethodInstance(name, holder, shape, false, range) {}
  IMPLEMENTS(MonitorMethod)
};

class AdapterStub : public MethodInstance {
 public:
  AdapterStub(Symbol name, Class* holder, const PlainShape& shape, Source::Range range)
      : MethodInstance(name, holder, shape, false, range) {}
  IMPLEMENTS(AdapterStub)
};

class IsInterfaceStub : public MethodInstance {
 public:
  IsInterfaceStub(Symbol name, Class* holder, const PlainShape& shape, Source::Range range)
      : MethodInstance(name, holder, shape, false, range) {}
  IMPLEMENTS(IsInterfaceStub);
};

// TODO(florian): the kind is called "GLOBAL_FUN", but the class is called
// "MethodStatic". Not completely consistent.
class MethodStatic : public Method {
 public:
  MethodStatic(Symbol name, Class* holder, const ResolutionShape& shape, MethodKind kind, Source::Range range)
      : Method(name, holder, shape, false, kind, range) {}
  IMPLEMENTS(MethodStatic)
};

class Constructor : public Method {
 public:
  Constructor(Symbol name, Class* klass, const ResolutionShape& shape, Source::Range range)
      : Method(name, klass, shape, false, CONSTRUCTOR, range) {}

  // Synthetic default constructor.
  Constructor(Symbol name, Class* klass, Source::Range range)
      : Method(name, klass, ResolutionShape(0).with_implicit_this(), false, CONSTRUCTOR, range)
      , is_synthetic_(true) {}
  IMPLEMENTS(Constructor)

  Class* klass() const { return holder(); }
  bool is_synthetic() const { return is_synthetic_; }

 private:
  bool is_synthetic_ = false;
};

class Global : public Method {
 public:
  Global(Symbol name, bool is_final, Source::Range range)
      : Method(name, null, ResolutionShape(0), false, GLOBAL_INITIALIZER, range)
      , is_final_(is_final)
      , is_lazy_(true)
      , global_id_(-1) {}
  Global(Symbol name, Class* holder, bool is_final, Source::Range range)
      : Method(name, holder, ResolutionShape(0), false, GLOBAL_INITIALIZER, range)
      , is_final_(is_final)
      , is_lazy_(true)
      , global_id_(-1) {}
  IMPLEMENTS(Global)

  // Whether this global is marked to be final.
  // Implies is_effectively_final.
  bool is_final() const { return is_final_; }

  // Whether the global is effectively final. This property is conservative and
  // might not return true for every effectively final global.
  // This property is only valid after the first resolution pass, as mutations
  // are only recorded during that pass.
  bool is_effectively_final() const { return mutation_count_ == 0; }
  void register_mutation() { mutation_count_++; }

  void set_explicit_return_type(Type type) {
    Method::set_return_type(type);
    has_explicit_type_ = true;
  }

  bool has_explicit_type() const {
    return has_explicit_type_;
  }

 public:
  // Reserved for ByteGen and Compiler.
  // The ids of globals must be continuous, and should therefore only be set
  // at the end of the compilation process (in case we can remove some).
  int global_id() const { return global_id_; }
  void set_global_id(int id) {
    ASSERT(global_id_ == -1 && id >= 0);
    global_id_ = id;
  }

  void mark_eager() {
    is_lazy_ = false;
  }

 public:
  // Reserved for the ByteGen.
  // This field might be changed at a later point (after optimizations).
  bool is_lazy() { return is_lazy_; }

 private:
  int mutation_count_ = 0;
  bool is_final_;
  bool is_lazy_;
  int global_id_;
  bool has_explicit_type_ = false;
};

class Field : public Node {
 public:
  Field(Symbol name, Class* holder, bool is_final, Source::Range range)
      : name_(name)
      , holder_(holder)
      , type_(Type::invalid())
      , is_final_(is_final)
      , resolved_index_(-1)
      , range_(range) {}
  IMPLEMENTS(Field)

  Symbol name() const { return name_; }

  Class* holder() const { return holder_; }

  // Whether the field is marked as final.
  bool is_final() const { return is_final_; }

  Type type() const { return type_; }
  void set_type(Type type) {
    ASSERT(!type_.is_valid());
    type_ = type;
  }

  Source::Range range() const { return range_; }

 public:
  // Reserved for compiler/bytegen.
  int resolved_index() const { return resolved_index_; }
  void set_resolved_index(int index) {
    ASSERT(resolved_index_ == -1);
    resolved_index_ = index;
  }

 private:
  Symbol name_;
  Class* holder_;
  Type type_;
  bool is_final_;
  int resolved_index_;
  Source::Range range_;
};

class FieldStub : public MethodInstance {
 public:
  FieldStub(Field* field, Class* holder, bool is_getter, Source::Range range)
      : MethodInstance(field->name(),
                       holder,
                       ResolutionShape::for_instance_field_accessor(is_getter),
                       false,
                       range)
      , field_(field)
      , checked_type_(Type::invalid()) {}
  IMPLEMENTS(FieldStub)

  Field* field() const { return field_; }
  bool is_getter() const { return !is_setter(); }

  bool is_synthetic() const { return true; }

  bool is_throwing() const { return is_throwing_; }
  void mark_throwing() { is_throwing_ = true; }

  bool is_checking_setter() const {
    ASSERT(!checked_type_.is_valid() || !is_getter());
    return checked_type_.is_valid();
  }
  Type checked_type() const { return checked_type_; }
  void set_checked_type(Type checked_type) {
    ASSERT(!is_getter());
    checked_type_ = checked_type;
  }

 private:
   Field* field_;
   bool is_throwing_ = false;
   Type checked_type_;
};

// TODO(kasper): Not really an expression. Maybe just a node? or a body part?
class Expression : public Node {
 public:
  explicit Expression(Source::Range range) : range_(range) {}
  IMPLEMENTS(Expression)

  virtual bool is_block() const { return false; }
  Source::Range range() { return range_; }

 private:
  Source::Range range_;
};

class Error : public Expression {
 public:
  explicit Error(Source::Range range)
      : Expression(range), nested_(List<Expression*>()) {}
  Error(Source::Range range, List<ir::Expression*> nested)
      : Expression(range), nested_(nested) {}
  IMPLEMENTS(Error);

  List<Expression*> nested() const { return nested_; }
  void set_nested(List<Expression*> nested) { nested_ = nested; }

 private:
  List<Expression*> nested_;
};

class Nop : public Expression {
 public:
  explicit Nop(Source::Range range) : Expression(range) {}
  IMPLEMENTS(Nop)
};

class FieldStore : public Expression {
 public:
  FieldStore(Expression* receiver,
             Field* field,
             Expression* value,
             Source::Range range)
      : Expression(range)
      , receiver_(receiver)
      , field_(field)
      , value_(value) {}
  IMPLEMENTS(FieldStore)

  Expression* receiver() const { return receiver_; }
  Field* field() const { return field_; }
  Expression* value() const { return value_; }

  void replace_value(Expression* new_value) { value_ = new_value; }

  bool is_box_store() const { return is_box_store_; }
  void mark_box_store() { is_box_store_ = true; }

 private:
  Expression* receiver_;
  Field* field_;
  Expression* value_;
  bool is_box_store_ = false;
};

class FieldLoad : public Expression {
 public:
  FieldLoad(Expression* receiver, Field* field, Source::Range range)
      : Expression(range), receiver_(receiver), field_(field) {}
  IMPLEMENTS(FieldLoad)

  Expression* receiver() const { return receiver_; }
  Field* field() const { return field_; }

  void replace_receiver(Expression* new_receiver) { receiver_ = new_receiver; }

  bool is_box_load() const { return is_box_load_; }
  void mark_box_load() { is_box_load_ = true; }

 private:
  Expression* receiver_;
  Field* field_;
  bool is_box_load_ = false;
};

class Sequence : public Expression {
 public:
  Sequence(List<Expression*> expressions, Source::Range range)
      : Expression(range), expressions_(expressions) {}
  IMPLEMENTS(Sequence)

  List<Expression*> expressions() const { return expressions_; }
  void replace_expressions(List<Expression*> new_expressions) { expressions_ = new_expressions; }

  bool is_block() const {
    if (expressions().is_empty()) return false;
    return expressions().last()->is_block();
  }

 private:
   List<Expression*> expressions_;
};

class Builtin : public Node {
 public:
  enum BuiltinKind {
    THROW,
    HALT,
    EXIT,
    INVOKE_LAMBDA,
    YIELD,
    DEEP_SLEEP,
    STORE_GLOBAL,
    LOAD_GLOBAL,
    INVOKE_INITIALIZER,
    GLOBAL_ID,
    IDENTICAL,
  };

  explicit Builtin(BuiltinKind kind) : kind_(kind) {}
  IMPLEMENTS(Builtin)

  static Builtin* resolve(Symbol id) {
    if (id == Symbols::__throw__) {
      return _new Builtin(THROW);
    } else if (id == Symbols::__halt__) {
      return _new Builtin(HALT);
    } else if (id == Symbols::__exit__) {
      return _new Builtin(EXIT);
    } else if (id == Symbols::__invoke_lambda__) {
      return _new Builtin(INVOKE_LAMBDA);
    } else if (id == Symbols::__yield__) {
      return _new Builtin(YIELD);
    } else if (id == Symbols::__deep_sleep__) {
      return _new Builtin(DEEP_SLEEP);
    } else if (id == Symbols::__store_global_with_id__) {
      return _new Builtin(STORE_GLOBAL);
    } else if (id == Symbols::__load_global_with_id__) {
      return _new Builtin(LOAD_GLOBAL);
    } else if (id == Symbols::__invoke_initializer__) {
      return _new Builtin(INVOKE_INITIALIZER);
    }
    // The identical builtin is recognized by the static call resolver
    // and the global-id builtin isn't accessible from userspace.
    return null;
  }

  BuiltinKind kind() const { return kind_; }

  int arity() const {
    switch (kind()) {
      case STORE_GLOBAL:
      case IDENTICAL:
        return 2;

      case THROW:
      case INVOKE_LAMBDA:
      case DEEP_SLEEP:
      case EXIT:
      case INVOKE_INITIALIZER:
      case LOAD_GLOBAL:
      case GLOBAL_ID:
        return 1;

      case HALT:
      case YIELD:
        return 0;
    }
    UNREACHABLE();
  }

 private:
  BuiltinKind kind_;
};

class TryFinally : public Expression {
 public:
  TryFinally(Code* body, List<ir::Local*> handler_parameters, Expression* handler, Source::Range range)
      : Expression(range)
      , body_(body)
      , handler_parameters_(handler_parameters)
      , handler_(handler) {}
  IMPLEMENTS(TryFinally)

  Code* body() const { return body_; }
  List<ir::Local*> handler_parameters() const { return handler_parameters_; }
  Expression* handler() const { return handler_; }

  void replace_body(Code* new_body) { body_ = new_body; }
  void replace_handler(Expression* new_handler) { handler_ = new_handler; }

 private:
  Code* body_;
  List<Local*> handler_parameters_;
  Expression* handler_;
};

class If : public Expression {
 public:
  If(Expression* condition, Expression* yes, Expression* no, Source::Range range)
      : Expression(range), condition_(condition), yes_(yes), no_(no) {}
  IMPLEMENTS(If)

  Expression* condition() const { return condition_; }
  Expression* yes() const { return yes_; }
  Expression* no() const { return no_; }

  void replace_condition(Expression* new_condition) { condition_ = new_condition; }
  void replace_yes(Expression* new_yes) { yes_ = new_yes; }
  void replace_no(Expression* new_no) { no_ = new_no; }

 private:
  Expression* condition_;
  Expression* yes_;
  Expression* no_;
};

class Not : public Expression {
 public:
  explicit Not(Expression* value, Source::Range range)
      : Expression(range), value_(value) {}
  IMPLEMENTS(Not)

  Expression* value() const { return value_; }
  void replace_value(Expression* new_value) { value_ = new_value; }

 private:
  Expression* value_;
};

class While : public Expression {
 public:
  While(Expression* condition, Expression* body, Expression* update, Local* loop_variable, Source::Range range)
      : Expression(range)
      , condition_(condition)
      , body_(body)
      , update_(update)
      , loop_variable_(loop_variable) {}
  IMPLEMENTS(While)

  Expression* condition() const { return condition_; }
  Expression* body() const { return body_; }
  Expression* update() const { return update_; }

  Local* loop_variable() const { return loop_variable_; }

  void replace_condition(Expression* new_condition) { condition_ = new_condition; }
  void replace_body(Expression* new_body) { body_ = new_body; }
  void replace_update(Expression* new_update) { update_ = new_update; }

 private:
  Expression* condition_;
  Expression* body_;
  Expression* update_;
  Local* loop_variable_;
};

class LoopBranch : public Expression {
 public:
  LoopBranch(bool is_break, int loop_depth, Source::Range range)
      : Expression(range), is_break_(is_break), block_depth_(loop_depth) {}
  IMPLEMENTS(LoopBranch)

  bool is_break() const { return is_break_; }
  int block_depth() const { return block_depth_; }

 private:
  bool is_break_;
  int block_depth_;
};

class Code : public Expression {
 public:
  Code(List<Parameter*> parameters, Expression* body, bool is_block, Source::Range range)
      : Expression(range)
      , parameters_(parameters)
      , body_(body)
      , is_block_(is_block)
      , captured_count_(0) {
    ASSERT(captured_count_ == 0 || !is_block);
  }
  IMPLEMENTS(Code)

  // Contains the captured arguments, but not the block-parameter (if it is a block).
  List<Parameter*> parameters() const { return parameters_; }
  void set_parameters(List<Parameter*> new_params) { parameters_ = new_params; }

  Expression* body() const { return body_; }
  bool is_block() const { return is_block_; }
  int captured_count() const { return captured_count_; }
  void set_captured_count(int count) { captured_count_ = count; }

  void replace_body(Expression* new_body) { body_ = new_body; }

 private:
  List<Parameter*> parameters_;
  Expression* body_;
  bool is_block_;
  int captured_count_;
};

class Reference : public Expression {
 public:
  explicit Reference(Source::Range range) : Expression(range) {}
  IMPLEMENTS(Reference)

  virtual Node* target() const = 0;
};

class ReferenceClass : public Reference {
 public:
  explicit ReferenceClass(Class* target, Source::Range range)
      : Reference(range), target_(target) {}
  IMPLEMENTS(ReferenceClass)

  Class* target() const { return target_; }

 private:
  Class* target_;
};

class ReferenceMethod : public Reference {
 public:
  ReferenceMethod(Method* target, Source::Range range) : Reference(range), target_(target) {}
  IMPLEMENTS(ReferenceMethod)

  Method* target() const { return target_; }

 private:
  Method* target_;
};

class ReferenceGlobal : public Reference {
 public:
  explicit ReferenceGlobal(Global* target, bool is_lazy, Source::Range range)
      : Reference(range), target_(target), is_lazy_(is_lazy) {}
  IMPLEMENTS(ReferenceGlobal)

  Global* target() const { return target_; }

  // Whether the reference to the global might trigger the lazy evaluation.
  bool is_lazy() const { return is_lazy_; }

 private:
  Global* target_;
  bool is_lazy_;
};

class Local : public Node {
 public:
  Local(Symbol name, bool is_final, bool is_block, Type type, Source::Range range)
      : name_(name)
      , range_(range)
      , is_final_(is_final)
      , is_block_(is_block)
      , has_explicit_type_(type.is_valid())
      , type_(type)
      , index_(-1) {}
  Local(Symbol name, bool is_final, bool is_block, Source::Range range)
      : Local(name, is_final, is_block, Type::invalid(), range) {}
  IMPLEMENTS(Local)

  Symbol name() const { return name_; }

  /// Whether this local is marked as final.
  virtual bool is_final() const { return is_final_; }

  /// Whether this local is effectively final.
  /// This property is only valid after the first resolution pass, as mutations
  /// are only recorded during that pass.
  virtual bool is_effectively_final() const { return mutation_count_ == 0; }
  virtual void register_mutation() { mutation_count_++; }

  virtual bool is_captured() const { return is_captured_; }
  virtual void mark_captured() { is_captured_ = true; }
  virtual int mutation_count() const { return mutation_count_; }

  void mark_effectively_final_loop_variable() { is_effectively_final_loop_variable_ = true; }
  /// Whether this local is a loop variable that is unchanged in the loop's body.
  virtual bool is_effectively_final_loop_variable() const { return is_effectively_final_loop_variable_; }

  virtual bool is_block() const { return is_block_; }

  virtual bool has_explicit_type() const { return has_explicit_type_; }

  // The index is required for bytecode generation.
  // The index for parameters is fixed, whereas the one for locals is set
  // during bytecode emission.
  int index() const {
    ASSERT(!is_Parameter() || index_ != -1);
    return index_;
  }
  void set_index(int index) {
    ASSERT(!is_Parameter());
    index_ = index;
  }

  virtual Type type() const { return type_; }
  virtual void set_type(Type type) {
    ASSERT(type.is_valid());
    type_ = type;
  }

  Source::Range range() const { return range_; }

 private:
  Symbol name_;
  Source::Range range_;
  int mutation_count_ = 0;
  bool is_final_;
  bool is_effectively_final_loop_variable_ = false;
  bool is_block_;
  bool has_explicit_type_;
  bool is_captured_ = false;
  Type type_;

 protected:
  int index_;
};

class Parameter : public Local {
 public:
  Parameter(Symbol name,
            Type type,
            bool is_block,
            int index,
            bool has_default_value,
            Source::Range range)
      : Parameter(name, type, is_block, index, -1, has_default_value, range) {}
  Parameter(Symbol name,
            Type type,
            bool is_block,
            int index,
            int original_index,
            bool has_default_value,
            Source::Range range)
      : Local(name, false, is_block, type, range)  // By default parameters are not final.
      , has_default_value_(has_default_value)
      , original_index_(original_index) {
    index_ = index;
  }
  IMPLEMENTS(Parameter)

  bool has_default_value() const { return has_default_value_; }
  void set_has_default_value(bool new_value) { has_default_value_ = new_value; }
  // The original index of the parameter, as written by the user.
  // We shuffle parameters around to make them more convenient, but for
  // documentation we want to keep the original ordering.
  // -1 if the parameter was not explicitly written.
  int original_index() const { return original_index_; }

 private:
  bool has_default_value_;
  int original_index_;
};

class CapturedLocal : public Parameter {
 public:
  CapturedLocal(Local* captured,
                int index,
                Source::Range range)
      : Parameter(captured->name(),
                  Type::any(), // Unused, since we forward to the captured local.
                  false,       // Unused, since we forward to the captured local.
                  index,
                  false,
                  range)
      , captured_(captured) {}
  IMPLEMENTS(CapturedLocal)

  bool is_final() const { return captured_->is_final(); }
  bool is_effectively_final() const { return captured_->is_effectively_final(); }
  bool is_effectively_final_loop_variable() const {
    return captured_->is_effectively_final_loop_variable();
  }
  void register_mutation() { captured_->register_mutation(); }
  int mutation_count() const { return captured_->mutation_count(); }

  bool is_block() const { return captured_->is_block(); }
  bool has_explicit_type() const { return captured_->has_explicit_type(); }
  Type type() const { return captured_->type(); }

  Local* local() const { return captured_; }

  virtual void set_type(Type type) {
    UNREACHABLE();
  }

  void mark_captured() {
    // Can be ignored, since we already represent a captured variable.
    ASSERT(captured_->is_captured());
  }
  bool is_captured() const {
    ASSERT(captured_->is_captured());
    return true;
  }

 private:
  Local* captured_;
};

class Block : public Local {
 public:
  Block(Symbol name, Source::Range range)
      : Local(name, true, true, range) {}
  IMPLEMENTS(Block);
};

class Dot : public Node {
 public:
  Dot(Expression* receiver, Symbol selector)
      : receiver_(receiver), selector_(selector) {}
  IMPLEMENTS(Dot)

  Expression* receiver() const { return receiver_; }
  Symbol selector() const { return selector_; }

  void replace_receiver(Expression* new_receiver) { receiver_ = new_receiver; }

 private:
  Expression* receiver_;
  Symbol selector_;
};

/// The target of an LSP operation, such as completion.
///
/// The selector of the node is the target of the operation.
class LspSelectionDot : public Dot {
 public:
  LspSelectionDot(Expression* receiver, Symbol selector, Symbol name)
      : Dot(receiver, selector)
      , name_(name) {}
  IMPLEMENTS(LspSelectionDot)

  bool is_for_named() const { return name_.is_valid(); }
  Symbol name() const { return name_; }

 private:
  Symbol name_;
};

class ReferenceLocal : public Reference {
 public:
  ReferenceLocal(Local* target, int block_depth, const Source::Range& range)
    : Reference(range), target_(target), block_depth_(block_depth) {}
  IMPLEMENTS(ReferenceLocal)

  Local* target() const { return target_; }
  int block_depth() const { return block_depth_; }
  bool is_block() const { return target()->is_block(); }

 private:
  Local* target_;
  int block_depth_;
};

class ReferenceBlock : public ReferenceLocal {
 public:
  ReferenceBlock(Block* target, int block_depth, Source::Range range)
      : ReferenceLocal(target, block_depth, range) {}
  IMPLEMENTS(ReferenceBlock)

  Block* target() const { return ReferenceLocal::target()->as_Block(); }
};

// A call to the super constructor.
// This node is only for static-analysis purposes and can be replaced with
//   the contained call during optimizations.
class Super : public Expression {
 public:
  Super(bool is_at_end, Source::Range range)
      : Expression(range)
      , is_explicit_(false)
      , is_at_end_(is_at_end) {}
  Super(Expression* expression, bool is_explicit, bool is_at_end, Source::Range range)
      : Expression(range)
      , expression_(expression)
      , is_explicit_(is_explicit)
      , is_at_end_(is_at_end) {}
  IMPLEMENTS(Super)

  Expression* expression() const { return expression_; }
  void replace_expression(Expression* new_expression) { expression_ = new_expression; }

  bool is_explicit() const { return is_explicit_; }
  bool is_at_end() const { return is_at_end_; }

 private:
  Expression* expression_ = null;
  bool is_explicit_;
  bool is_at_end_;
};

class Call : public Expression {
 public:
  Call(List<Expression*> arguments, const CallShape& shape, Source::Range range)
      : Expression(range), arguments_(arguments), shape_(shape) {}
  IMPLEMENTS(Call)

  virtual Node* target() const = 0;
  List<Expression*> arguments() const { return arguments_; }
  CallShape shape() const { return shape_; }

  void mark_tail_call() { is_tail_call_ = true; }
  bool is_tail_call() const { return is_tail_call_; }

 private:
  List<Expression*> arguments_;
  CallShape shape_;
  bool is_tail_call_ = false;
};

class CallStatic : public Call {
 public:
  CallStatic(ReferenceMethod* method,
             const CallShape& shape,
             List<Expression*> arguments,
             Source::Range range)
      : Call(arguments, shape, range)
      , method_(method) {}
  CallStatic(ReferenceMethod* method,
             List<Expression*> arguments,
             const CallShape& shape,
             Source::Range range)
      : Call(arguments, shape, range)
      , method_(method) {}

  IMPLEMENTS(CallStatic)

  ReferenceMethod* target() const { return method_; }

  void replace_method(ReferenceMethod* new_target) { method_ = new_target; }

 private:
  ReferenceMethod* method_;
};

class Lambda : public CallStatic {
 public:
  Lambda(ReferenceMethod* method,
         const CallShape& shape,
         List<Expression*> arguments,
         Map<Local*, int> captured_depths,
         Source::Range range)
      : CallStatic(method, shape, arguments, range)
      , captured_depths_(captured_depths) {}
  IMPLEMENTS(Lambda)

  Code* code() const { return arguments()[0]->as_Code(); }

  ir::Expression* captured_args() const { return arguments()[1]; }
  void set_captured_args(ir::Expression* new_captured) { arguments()[1] = new_captured; }

  Map<Local*, int> captured_depths() const { return captured_depths_; }

 private:
  Map<Local*, int> captured_depths_;
};

class CallConstructor : public CallStatic {
 public:
  CallConstructor(ReferenceMethod* target,
                  const CallShape& shape,
                  List<Expression*> arguments,
                  Source::Range range)
      : CallStatic(target, shape, arguments, range) {
    ASSERT(target->target()->is_constructor());
  }
  IMPLEMENTS(CallConstructor)

  Class* klass() const { return constructor()->klass(); }
  Constructor* constructor() const { return target()->target()->as_Constructor(); }

  bool is_box_construction() const { return is_box_construction_; }
  void mark_box_construction() { is_box_construction_ = true; }

 private:
  bool is_box_construction_ = false;
};

class CallVirtual : public Call {
 public:
  CallVirtual(Dot* target,
              const CallShape& shape,
              List<Expression*> arguments,
              Source::Range range)
      : Call(arguments, shape, range)
      , target_(target)
      , opcode_(INVOKE_VIRTUAL) {
    ASSERT(shape.arity() > 0);
  }

  /// Creates a virtual call with the given opcode.
  ///
  /// This constructor is designed for interface is-checks, and therefore
  /// doesn't take any arguments.
  CallVirtual(Dot* target,
              Opcode opcode)
      : Call(List<Expression*>(),
             CallShape(0).with_implicit_this(),
             Source::Range::invalid())
      , target_(target)
      , opcode_(opcode) {}
  IMPLEMENTS(CallVirtual)

  Dot* target() const { return target_; }
  Expression* receiver() const { return target_->receiver(); }
  Symbol selector() const { return target_->selector(); }

  void replace_target(Dot* new_target) { target_ = new_target; }

  Opcode opcode() const { return opcode_; }
  void set_opcode(Opcode new_opcode) { opcode_ = new_opcode; }

 private:
  Dot* target_;
  Opcode opcode_;
};

class CallBlock : public Call {
 public:
  CallBlock(Expression* target,
            const CallShape& shape,
            List<Expression*> arguments,
            Source::Range range)
      : Call(arguments, shape, range)
      , target_(target) {
    ASSERT(target->is_ReferenceBlock() ||
           (target->is_ReferenceLocal() && target->is_block()));
  }
  IMPLEMENTS(CallBlock)

  Expression* target() const { return target_; }

  void replace_target(Expression* new_target) { target_ = new_target; }

 private:
  Expression* target_;
};

class CallBuiltin : public Call {
 public:
  CallBuiltin(Builtin* builtin,
              const CallShape& shape,
              List<Expression*> arguments,
              Source::Range range)
      : Call(arguments, shape, range)
      , target_(builtin) {}
  IMPLEMENTS(CallBuiltin)

  Builtin* target() const { return target_; }

 private:
  Builtin* target_;
};

class Typecheck : public Expression {
 public:
  enum Kind {
    IS_CHECK,
    AS_CHECK,
    PARAMETER_AS_CHECK,
    LOCAL_AS_CHECK,
    RETURN_AS_CHECK,
    FIELD_INITIALIZER_AS_CHECK,
    FIELD_AS_CHECK,
  };

  Typecheck(Kind kind, Expression* expression, Type type, Symbol type_name, Source::Range range)
      : Expression(range)
      , kind_(kind)
      , expression_(expression)
      , type_(type)
      , type_name_(type_name) {}
  IMPLEMENTS(Typecheck);

  Type type() const { return type_; }

  Kind kind() const { return kind_; }

  /// Whether this is an 'is' or 'as' check.
  bool is_as_check() const {
    switch (kind_) {
      case IS_CHECK:
        return false;
      case AS_CHECK:
      case PARAMETER_AS_CHECK:
      case LOCAL_AS_CHECK:
      case RETURN_AS_CHECK:
      case FIELD_INITIALIZER_AS_CHECK:
      case FIELD_AS_CHECK:
        return true;
    }
    UNREACHABLE();
    return false;
  }

  Expression* expression() const { return expression_; }
  void replace_expression(Expression* expression) { expression_ = expression; }

  bool is_interface_check() const {
    return type_.is_class() && type_.klass()->is_interface();
  }

  /// Returns the type name of this check.
  /// Since we might change the [type] of the check (for optimization purposes, or
  ///   because of tree-shaking), we should use the returned name for error messages.
  Symbol type_name() const { return type_name_; }

 private:
  Kind kind_;
  Expression* expression_;
  Type type_;
  Symbol type_name_;
};

class Return : public Expression {
 public:
  Return(Expression* value, bool is_end_of_method_return, Source::Range range)
      : Expression(range), value_(value), depth_(-1), is_end_of_method_return_(is_end_of_method_return) {
    if (is_end_of_method_return) ASSERT(value->is_LiteralNull());
  }
  Return(Expression* value, int depth, Source::Range range)
      : Expression(range), value_(value), depth_(depth), is_end_of_method_return_(false) {}
  IMPLEMENTS(Return)

  Expression* value() const { return value_; }

  // How many frames the return should leave.
  // -1: to the next outermost function.
  // 0: the immediately enclosing block/lambda.
  // ...
  int depth() const { return depth_; }

  void replace_value(Expression* new_value) { value_ = new_value; }

  bool is_end_of_method_return() const { return is_end_of_method_return_; }

 private:
  Expression* value_;
  int depth_;
  bool is_end_of_method_return_;
};

class LogicalBinary : public Expression {
 public:
  enum Operator {
    AND,
    OR
  };

  LogicalBinary(Expression* left, Expression* right, Operator op, Source::Range range)
      : Expression(range), left_(left), right_(right), operator_(op) {}
  IMPLEMENTS(LogicalBinary)

  Expression* left() const { return left_; }
  Expression* right() const { return right_; }
  Operator op() const { return operator_; }

  void replace_left(Expression* new_left) { left_ = new_left; }
  void replace_right(Expression* new_right) { right_ = new_right; }

 private:
  Expression* left_;
  Expression* right_;
  Operator operator_;
};

class Assignment : public Expression {
 public:
  Assignment(Node* left, Expression* right, Source::Range range)
      : Expression(range), left_(left), right_(right) {}
  IMPLEMENTS(Assignment)

  Node* left() const { return left_; }
  Expression* right() const { return right_; }

  void replace_right(Expression* new_right) { right_ = new_right; }

  bool is_block() const { return right_->is_block(); }

 private:
  Node* left_;
  Expression* right_;
};

class AssignmentLocal : public Assignment {
 public:
  AssignmentLocal(Local* left, int block_depth, Expression* right, Source::Range range)
      : Assignment(left, right, range), block_depth_(block_depth) {}
  IMPLEMENTS(AssignmentLocal)

  Local* local() const { return left()->as_Local(); }
  int block_depth() const { return block_depth_; }

 private:
  int block_depth_;
};

class AssignmentGlobal : public Assignment {
 public:
  AssignmentGlobal(Global* left, Expression* right, Source::Range range)
      : Assignment(left, right, range) {}
  IMPLEMENTS(AssignmentGlobal)

  Global* global() const { return left()->as_Global(); }
};

class AssignmentDefine : public Assignment {
 public:
  AssignmentDefine(Local* left, Expression* right, Source::Range range)
      : Assignment(left, right, range) {}
  IMPLEMENTS(AssignmentDefine)

  Local* local() const { return left()->as_Local(); }
};

class Literal : public Expression {
 public:
  explicit Literal(Source::Range range) : Expression(range) {}
  IMPLEMENTS(Literal)
};

class LiteralNull : public Literal {
 public:
  explicit LiteralNull(Source::Range range) : Literal(range) {}
  IMPLEMENTS(LiteralNull)
};


// Used to indicate that a field/variable hasn't been initialized yet.
// It is equivalent to `null`, but we check statically that it is never
//   read.
class LiteralUndefined : public Literal {
 public:
  LiteralUndefined(Source::Range range) : Literal(range) {}
  IMPLEMENTS(LiteralUndefined)
};

class LiteralInteger : public Literal {
 public:
  explicit LiteralInteger(int64 value, Source::Range range) : Literal(range), value_(value) {}
  IMPLEMENTS(LiteralInteger)

  int64 value() const { return value_; }

 private:
  int64 value_;
};

class LiteralFloat : public Literal {
 public:
  explicit LiteralFloat(double value, Source::Range range) : Literal(range), value_(value) {}
  IMPLEMENTS(LiteralFloat)

  double value() const { return value_; }

 private:
  double value_;
};

class LiteralString : public Literal {
 public:
  LiteralString(const char* value, int length, Source::Range range)
      : Literal(range), value_(value), length_(length) {}
  IMPLEMENTS(LiteralString)

  const char* value() const { return value_; }
  int length() const { return length_; }

 private:
  const char* value_;
  int length_;
};

class LiteralByteArray : public Literal {
 public:
  LiteralByteArray(List<uint8> data, Source::Range range) : Literal(range), data_(data) {}
  IMPLEMENTS(LiteralByteArray)

  List<uint8> data() { return data_; }

 private:
  List<uint8> data_;
};

class LiteralBoolean : public Literal {
 public:
  explicit LiteralBoolean(bool value, Source::Range range) : Literal(range), value_(value) {}
  IMPLEMENTS(LiteralBoolean)

  bool value() const { return value_; }

 private:
  bool value_;
};

class PrimitiveInvocation : public Expression {
 public:
  PrimitiveInvocation(Symbol module,
                      Symbol primitive,
                      int module_index,
                      int primitive_index,
                      Source::Range range)
      : Expression(range)
      , module_(module)
      , primitive_(primitive)
      , module_index_(module_index)
      , primitive_index_(primitive_index) {}
  IMPLEMENTS(PrimitiveInvocation)

  Symbol module() const { return module_; }
  Symbol primitive() const { return primitive_; }
  int module_index() const { return module_index_; }
  int primitive_index() const { return primitive_index_; }

 private:
  Symbol module_;
  Symbol primitive_;
  int module_index_;
  int primitive_index_;
};

#undef IMPLEMENTS

} // namespace toit::compiler::ir
} // namespace toit::compiler
} // namespace toit
