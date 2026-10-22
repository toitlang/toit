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

#include "zone.h"
#include "ast_resolution.h"

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

// Transitional frontend representation. Initially mirrors the backend IR so
// resolution and diagnostics can migrate independently of code generation.
namespace resolution {

class Node;

#define RESOLUTION_NODES(V)             \
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
  V(MixinStub)                  \
  V(IsInterfaceOrMixinStub)     \
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
RESOLUTION_NODES(DECLARE)
#undef DECLARE

class Visitor {
 public:
  virtual void visit(View<Node> node);
  virtual void visit(AstNode* node);

#define DECLARE(name) virtual void visit_##name(View<name> node) = 0;
RESOLUTION_NODES(DECLARE)
#undef DECLARE
};

class TraversingVisitor : public Visitor {
 public:
#define DECLARE(name) virtual void visit_##name(View<name> node);
RESOLUTION_NODES(DECLARE)
#undef DECLARE
};

template<typename T> class ReturningVisitor {
 public:
#define DECLARE(name) virtual T visit_##name(View<name> node) = 0;
RESOLUTION_NODES(DECLARE)
#undef DECLARE
};

class Type {
 public:
  explicit Type(View<Class> klass) : kind_(kClass), class_(klass), is_nullable_(false) {
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

  View<Class> klass() const { return class_; }

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

  Type(int kind, View<Class> klass, bool is_nullable)
      : kind_(kind), class_(klass), is_nullable_(is_nullable) {}

  friend class ListBuilder<Type>;
  Type() {}

  int kind_;
  View<Class> class_;
  bool is_nullable_;
};

class Node {
 public:
  Node() : ast_node_(zone_new<AstNode>(Origin::current(), this)) {}
  Node(const Node&) = delete;
  Node& operator=(const Node&) = delete;

  AstNode* ast_node() const { return ast_node_; }
  static Node* cast(Node* node) { return node; }

  void accept(Visitor* visitor) { ast_node_->accept(visitor); }
  Type accept(ReturningVisitor<Type>* visitor) { return ast_node_->accept(visitor); }

#define DECLARE(name)                              \
  virtual bool is_##name() const { return false; } \
  virtual View<name> as_##name() { return null; }
RESOLUTION_NODES(DECLARE)
#undef DECLARE

  virtual void dispatch(Visitor* visitor) = 0;
  virtual Type dispatch(ReturningVisitor<Type>* visitor) = 0;
  virtual const char* node_type() const { return "Node"; }

  void print(bool use_resolution_shape);

 private:
  AstNode* ast_node_;
};

#define IMPLEMENTS(name)                                                 \
  static name* cast(Node* node) { ASSERT(node->is_##name()); return static_cast<name*>(node); } \
  virtual void dispatch(Visitor* visitor) { visitor->visit_##name(View<name>(ast_node())); } \
  virtual Type dispatch(ReturningVisitor<Type>* visitor) { return visitor->visit_##name(View<name>(ast_node())); } \
  virtual bool is_##name() const { return true; }                        \
  virtual View<name> as_##name() { return View<name>(ast_node()); }                             \
  virtual const char* node_type() const { return #name; }

class Program : public Node {
 public:
  Program(List<View<Class>> classes,
          List<View<Method>> methods,
          List<View<Global>> globals,
          List<View<Class>> tree_roots,
          List<View<Method>> entry_points,
          List<Type> literal_types,
          View<Method> lookup_failure,
          View<Method> as_check_failure,
          View<Class> lambda_box)
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

  List<View<Class>> classes() const { return classes_; }
  List<View<Method>> methods() const { return methods_; }
  List<View<Global>> globals() const { return globals_; }

  void replace_classes(List<View<Class>> new_classes) { classes_ = new_classes; }
  void replace_methods(List<View<Method>> new_methods) { methods_ = new_methods; }
  void replace_globals(List<View<Global>> new_globals) { globals_ = new_globals; }

  void set_methods(List<View<Method>> methods) {
    methods_ = methods;
  }

  View<Method> lookup_failure() const { return lookup_failure_; }
  View<Method> as_check_failure() const { return as_check_failure_; }

  View<Class> lambda_box() const { return lambda_box_; }

  List<View<Class>> tree_roots() const { return tree_roots_; }

  List<View<Method>> entry_points() const { return entry_points_; }

  List<Type> literal_types() const { return literal_types_; }

 private:
  List<View<Class>> classes_;
  List<View<Method>> methods_;
  List<View<Global>> globals_;
  List<View<Class>> tree_roots_;
  List<View<Method>> entry_points_;
  List<Type> literal_types_;
  View<Method> lookup_failure_;
  View<Method> as_check_failure_;
  View<Class> lambda_box_;
};

class Class : public Node {
 public:
  enum Kind {
    CLASS,
    INTERFACE,
    MONITOR,
    MIXIN,
  };

  Class(Symbol name, Kind kind, bool is_abstract, Source::Range range, Source::Range outline_range)
      : name_(name)
      , range_(range)
      , outline_range_(outline_range)
      , is_runtime_class_(false)
      , deprecation_message_(Symbol::invalid())
      , super_(null)
      , kind_(kind)
      , is_abstract_(is_abstract)
      , typecheck_selector_(Selector<CallShape>(Symbol::invalid(), CallShape::invalid()))
      , is_instantiated_(kind != MIXIN)
      , id_(-1)
      , start_id_(-1)
      , end_id_(-1)
      , total_field_count_(-1) {
    ASSERT(outline_range.contains(range));
  }
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

  bool is_deprecated() const { return deprecation_message_.is_valid(); }
  void set_deprecation(Symbol message) { deprecation_message_ = message; }
  Symbol get_deprecation_message() const { return deprecation_message_; }

  View<Class> super() const { return super_; }
  void set_super(View<Class> klass) {
    ASSERT(super_ == null);
    super_ = klass;
  }
  void replace_super(View<Class> klass) {
    super_ = klass;
  }

  /// Returns whether the given klass is a super of this class.
  bool is_transitive_super_of(View<Class> klass) {
    auto current = klass->super();
    while (current != null) {
      if (current.node() == ast_node()) {
        return true;
      }
      current = current->super();
    }
    return false;
  }

  List<View<Class>> interfaces() const { return interfaces_; }
  void set_interfaces(List<View<Class>> interfaces) {
    ASSERT(interfaces_.is_empty());
    interfaces_ = interfaces;
  }
  void replace_interfaces(List<View<Class>> interfaces) {
    interfaces_ = interfaces;
  }

  List<View<Class>> mixins() const { return mixins_; }
  void set_mixins(List<View<Class>> mixins) {
    ASSERT(mixins_.is_empty());
    mixins_ = mixins;
  }
  void replace_mixins(List<View<Class>> mixins) {
    mixins_ = mixins;
  }

  /// The unnamed constructors.
  ///
  /// The named constructors are stored in the [statics] scope.
  List<View<Method>> unnamed_constructors() const { return constructors_; }
  void set_unnamed_constructors(List<View<Method>> constructors) {
    ASSERT(constructors_.is_empty());
    constructors_ = constructors;
  }
  void replace_unnamed_constructors(List<View<Method>> new_constructors) { constructors_ = new_constructors; }

  /// The unnamed factories.
  ///
  /// The named factories are stored in the [statics] scope.
  List<View<Method>> factories() const { return factories_; }
  void set_factories(List<View<Method>> factories) {
    ASSERT(factories_.is_empty());
    factories_ = factories;
  }
  void replace_factories(List<View<Method>> new_factories) { factories_ = new_factories; }

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

  List<View<MethodInstance>> methods() const { return methods_; }
  void set_methods(List<View<MethodInstance>> methods) {
    ASSERT(methods_.is_empty());
    methods_ = methods;
  }
  void replace_methods(List<View<MethodInstance>> new_methods) { methods_ = new_methods; }

  List<View<Field>> fields() const { return fields_; }
  void set_fields(List<View<Field>> fields) {
    ASSERT(fields_.is_empty());
    fields_ = fields;
  }
  void replace_fields(List<View<Field>> fields) { fields_ = fields; }

  Kind kind() const { return kind_; }

  /// Whether the class is abstract.
  /// A class is abstract if it cannot be instantiated.
  bool is_abstract() const { return is_abstract_; }

  bool is_interface() const { return kind_ == INTERFACE; }
  bool is_mixin() const { return kind_ == MIXIN; }

  Source::Range range() const { return range_; }
  Source::Range outline_range() const { return outline_range_; }

  /// These functions are set by the tree-shaker.
  bool is_instantiated() const { return is_instantiated_; }
  void set_is_instantiated(bool value) { is_instantiated_ = value; }

  Selector<CallShape> typecheck_selector() const { return typecheck_selector_; }
  void set_typecheck_selector(Selector<CallShape> selector) {
    ASSERT(is_interface() || is_mixin());
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
  Source::Range outline_range_;
  bool is_runtime_class_;
  Symbol deprecation_message_;
  View<Class> super_;
  List<View<Class>> interfaces_;
  List<View<Class>> mixins_;
  Kind kind_;
  bool is_abstract_;
  // Only set for interfaces.
  Selector<CallShape> typecheck_selector_;

  List<View<Method>> constructors_;
  List<View<Method>> factories_;
  List<View<MethodInstance>> methods_;
  List<View<Field>> fields_;

  StaticsScope* statics_ = null;
  Scope* toitdoc_scope_ = null;

  bool is_instantiated_;

  int id_;
  int start_id_;
  int end_id_;

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
                  View<Class> holder,  // `null` if not inside a class.
                  const ResolutionShape& shape,
                  bool is_abstract,
                  MethodKind kind,
                  Source::Range range,
                  Source::Range outline_range)
      : name_(name)
      , holder_(holder)
      , return_type_(Type::invalid())
      , use_resolution_shape_(true)
      , resolution_shape_(shape)
      , plain_shape_(PlainShape::invalid())
      , is_abstract_(is_abstract)
      , does_not_return_(false)
      , is_runtime_method_(false)
      , deprecation_message_(Symbol::invalid())
      , kind_(kind)
      , range_(range)
      , outline_range_(outline_range)
      , body_(null)
      , index_(-1) {}

  explicit Method(Symbol name,
                  View<Class> holder,  // `null` if not inside a class.
                  const PlainShape& shape,
                  bool is_abstract,
                  MethodKind kind,
                  Source::Range range,
                  Source::Range outline_range)
      : name_(name)
      , holder_(holder)
      , return_type_(Type::invalid())
      , use_resolution_shape_(false)
      , resolution_shape_(ResolutionShape::invalid())
      , plain_shape_(shape)
      , is_abstract_(is_abstract)
      , does_not_return_(false)
      , is_runtime_method_(false)
      , deprecation_message_(Symbol::invalid())
      , kind_(kind)
      , range_(range)
      , outline_range_(outline_range)
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

  bool is_deprecated() const { return deprecation_message_.is_valid(); }
  void set_deprecation(Symbol message) { deprecation_message_ = message; }
  Symbol get_deprecation_message() const { return deprecation_message_; }

  Type return_type() const { return return_type_; }
  void set_return_type(Type type) {
    ASSERT(!return_type_.is_valid());
    return_type_ = type;
  }
  void replace_return_type(Type type) {
    return_type_ = type;
  }

  View<Expression> body() const { return body_; }
  void set_body(View<Expression> body) {
    ASSERT(body_ == null);
    body_ = body;
  }

  void replace_body(View<Expression> new_body) { body_ = new_body; }

  bool is_dead() const { return is_dead_; }
  void kill() { is_dead_ = true; }

  List<View<Parameter>> parameters() const { return parameters_; }
  // Use 'set' for the initial setting, and 'replace' for later replacements.
  void set_parameters(List<View<Parameter>> parameters) {
    ASSERT(parameters_.is_empty());
    ASSERT(_parameters_have_correct_index(parameters));
    parameters_ = parameters;
  }
  void replace_parameters(List<View<Parameter>> parameters) {
    ASSERT(_parameters_have_correct_index(parameters));
    parameters_ = parameters;
  }

  /// Returns the syntactic holder of this method.
  /// Static functions that are declared inside a class have a holder.
  View<Class> holder() const { return holder_; }

  Source::Range range() const { return range_; }
  Source::Range outline_range() const { return outline_range_; }

  virtual bool is_synthetic() const {
    return kind_ == FIELD_INITIALIZER;
  }

 private:
  const Symbol name_;
  View<Class> holder_;

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
  Symbol deprecation_message_;
  const MethodKind kind_;
  const Source::Range range_;
  const Source::Range outline_range_;

  List<View<Parameter>> parameters_;
  View<Expression> body_;
  bool is_dead_ = false;

  static bool _parameters_have_correct_index(List<View<Parameter>> parameters);

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
  MethodInstance(Symbol name,
                 View<Class> holder,
                 const ResolutionShape& shape,
                 bool is_abstract,
                 Source::Range range,
                 Source::Range outline_range)
      : Method(name, holder, shape, is_abstract, INSTANCE, range, outline_range) {}
  MethodInstance(Symbol name,
                 View<Class> holder,
                 const PlainShape& shape,
                 bool is_abstract,
                 Source::Range range,
                 Source::Range outline_range)
      : Method(name, holder, shape, is_abstract, INSTANCE, range, outline_range) {}
  MethodInstance(Method::MethodKind kind,
                 Symbol name,
                 View<Class> holder,
                 const ResolutionShape& shape,
                 bool is_abstract,
                 Source::Range range,
                 Source::Range outline_range)
      : Method(name, holder, shape, is_abstract, kind, range, outline_range) {}
  IMPLEMENTS(MethodInstance)
};

class MonitorMethod : public MethodInstance {
 public:
  MonitorMethod(Symbol name,
                View<Class> holder,
                const ResolutionShape& shape,
                Source::Range range,
                Source::Range outline_range)
      : MethodInstance(name, holder, shape, false, range, outline_range) {}
  IMPLEMENTS(MonitorMethod)
};

class AdapterStub : public MethodInstance {
 public:
  AdapterStub(Symbol name, View<Class> holder, const PlainShape& shape, Source::Range range, Source::Range outline_range)
      : MethodInstance(name, holder, shape, false, range, outline_range) {}
  IMPLEMENTS(AdapterStub)
};

class MixinStub : public MethodInstance {
 public:
  MixinStub(Symbol name, View<Class> holder, const PlainShape& shape, Source::Range range, Source::Range outline_range)
      : MethodInstance(name, holder, shape, false, range, outline_range) {}
  IMPLEMENTS(MixinStub)
};

class IsInterfaceOrMixinStub : public MethodInstance {
 public:
  IsInterfaceOrMixinStub(Symbol name,
                         View<Class> holder,
                         const PlainShape& shape,
                         View<Class> interface_or_mixin,
                         Source::Range range,
                         Source::Range outline_range)
      : MethodInstance(name, holder, shape, false, range, outline_range)
      , interface_or_mixin_(interface_or_mixin) {}

  IMPLEMENTS(IsInterfaceOrMixinStub);

  resolution::View<resolution::Class> interface_or_mixin() const { return interface_or_mixin_; }

 private:
  resolution::View<resolution::Class> interface_or_mixin_;
};

// TODO(florian): the kind is called "GLOBAL_FUN", but the class is called
// "MethodStatic". Not completely consistent.
class MethodStatic : public Method {
 public:
  MethodStatic(Symbol name,
               View<Class> holder,
               const ResolutionShape& shape,
               MethodKind kind,
               Source::Range range,
               Source::Range outline_range)
      : Method(name, holder, shape, false, kind, range, outline_range) {}
  IMPLEMENTS(MethodStatic)
};

class Constructor : public Method {
 public:
  Constructor(Symbol name,
              View<Class> klass,
              const ResolutionShape& shape,
              Source::Range range,
              Source::Range outline_range)
      : Method(name, klass, shape, false, CONSTRUCTOR, range, outline_range) {}

  // Synthetic default constructor.
  Constructor(Symbol name, View<Class> klass, Source::Range range, Source::Range outline_range)
      : Method(name, klass, ResolutionShape(0).with_implicit_this(), false, CONSTRUCTOR, range, outline_range)
      , is_synthetic_(true) {}
  IMPLEMENTS(Constructor)

  View<Class> klass() const { return holder(); }
  bool is_synthetic() const { return is_synthetic_; }

 private:
  bool is_synthetic_ = false;
};

class Global : public Method {
 public:
  Global(Symbol name, bool is_final, Source::Range range, Source::Range outline_range)
      : Method(name, null, ResolutionShape(0), false, GLOBAL_INITIALIZER, range, outline_range)
      , is_final_(is_final)
      , is_lazy_(true)
      , global_id_(-1) {}
  Global(Symbol name, View<Class> holder, bool is_final, Source::Range range, Source::Range outline_range)
      : Method(name, holder, ResolutionShape(0), false, GLOBAL_INITIALIZER, range, outline_range)
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
  Field(Symbol name, View<Class> holder, bool is_final, Source::Range range, Source::Range outline_range)
      : name_(name)
      , holder_(holder)
      , type_(Type::invalid())
      , is_final_(is_final)
      , deprecation_message_(Symbol::invalid())
      , resolved_index_(-1)
      , range_(range)
      , outline_range_(outline_range) {}
  IMPLEMENTS(Field)

  Symbol name() const { return name_; }

  View<Class> holder() const { return holder_; }

  // Whether the field is marked as final.
  bool is_final() const { return is_final_; }

  bool is_deprecated() const { return deprecation_message_.is_valid(); }
  void set_deprecation(Symbol message) { deprecation_message_ = message; }
  Symbol get_deprecation_message() const { return deprecation_message_; }

  Type type() const { return type_; }
  void set_type(Type type) {
    ASSERT(!type_.is_valid());
    type_ = type;
  }

  Source::Range range() const { return range_; }
  Source::Range outline_range() const { return outline_range_; }

 public:
  // Reserved for compiler/bytegen.
  int resolved_index() const { return resolved_index_; }
  void set_resolved_index(int index) {
    ASSERT(resolved_index_ == -1);
    resolved_index_ = index;
  }

 private:
  Symbol name_;
  View<Class> holder_;
  Type type_;
  bool is_final_;
  Symbol deprecation_message_;
  int resolved_index_;
  Source::Range range_;
  Source::Range outline_range_;
};

class FieldStub : public MethodInstance {
 public:
  FieldStub(View<Field> field, View<Class> holder, bool is_getter, Source::Range range, Source::Range outline_range)
      : MethodInstance(field->name(),
                       holder,
                       ResolutionShape::for_instance_field_accessor(is_getter),
                       false,
                       range,
                       outline_range)
      , field_(field)
      , checked_type_(Type::invalid()) {}
  IMPLEMENTS(FieldStub)

  View<Field> field() const { return field_; }
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
   View<Field> field_;
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
      : Expression(range), nested_(List<View<Expression>>()) {}
  Error(Source::Range range, List<resolution::View<resolution::Expression>> nested)
      : Expression(range), nested_(nested) {}
  IMPLEMENTS(Error);

  List<View<Expression>> nested() const { return nested_; }
  void set_nested(List<View<Expression>> nested) { nested_ = nested; }

 private:
  List<View<Expression>> nested_;
};

class Nop : public Expression {
 public:
  explicit Nop(Source::Range range) : Expression(range) {}
  IMPLEMENTS(Nop)
};

class FieldStore : public Expression {
 public:
  FieldStore(View<Expression> receiver,
             View<Field> field,
             View<Expression> value,
             Source::Range range)
      : Expression(range)
      , receiver_(receiver)
      , field_(field)
      , value_(value) {}
  IMPLEMENTS(FieldStore)

  View<Expression> receiver() const { return receiver_; }
  View<Field> field() const { return field_; }
  View<Expression> value() const { return value_; }

  void replace_receiver(View<Expression> new_receiver) { receiver_ = new_receiver; }
  void replace_value(View<Expression> new_value) { value_ = new_value; }

  bool is_box_store() const { return is_box_store_; }
  void mark_box_store() { is_box_store_ = true; }

 private:
  View<Expression> receiver_;
  View<Field> field_;
  View<Expression> value_;
  bool is_box_store_ = false;
};

class FieldLoad : public Expression {
 public:
  FieldLoad(View<Expression> receiver, View<Field> field, Source::Range range)
      : Expression(range), receiver_(receiver), field_(field) {}
  IMPLEMENTS(FieldLoad)

  View<Expression> receiver() const { return receiver_; }
  View<Field> field() const { return field_; }

  void replace_receiver(View<Expression> new_receiver) { receiver_ = new_receiver; }

  bool is_box_load() const { return is_box_load_; }
  void mark_box_load() { is_box_load_ = true; }

 private:
  View<Expression> receiver_;
  View<Field> field_;
  bool is_box_load_ = false;
};

class Sequence : public Expression {
 public:
  Sequence(List<View<Expression>> expressions, Source::Range range)
      : Expression(range), expressions_(expressions) {}
  IMPLEMENTS(Sequence)

  List<View<Expression>> expressions() const { return expressions_; }
  void replace_expressions(List<View<Expression>> new_expressions) { expressions_ = new_expressions; }

  bool is_block() const {
    if (expressions().is_empty()) return false;
    return expressions().last()->is_block();
  }

 private:
   List<View<Expression>> expressions_;
};

class Builtin : public Node {
 public:
  enum BuiltinKind {
    THROW,
    EXIT,
    INVOKE_LAMBDA,
    YIELD,
    RESET,
    DEEP_SLEEP,
    STORE_GLOBAL,
    LOAD_GLOBAL,
    INVOKE_INITIALIZER,
    GLOBAL_ID,
    IDENTICAL,
  };

  explicit Builtin(BuiltinKind kind) : kind_(kind) {}
  IMPLEMENTS(Builtin)

  static View<Builtin> resolve(Symbol id) {
    if (id == Symbols::__throw__) {
      return make<Builtin>(THROW);
    } else if (id == Symbols::__exit__) {
      return make<Builtin>(EXIT);
    } else if (id == Symbols::__invoke_lambda__) {
      return make<Builtin>(INVOKE_LAMBDA);
    } else if (id == Symbols::__yield__) {
      return make<Builtin>(YIELD);
    } else if (id == Symbols::__reset__) {
      return make<Builtin>(RESET);
    } else if (id == Symbols::__deep_sleep__) {
      return make<Builtin>(DEEP_SLEEP);
    } else if (id == Symbols::__store_global_with_id__) {
      return make<Builtin>(STORE_GLOBAL);
    } else if (id == Symbols::__load_global_with_id__) {
      return make<Builtin>(LOAD_GLOBAL);
    } else if (id == Symbols::__invoke_initializer__) {
      return make<Builtin>(INVOKE_INITIALIZER);
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

      case YIELD:
      case RESET:
        return 0;
    }
    UNREACHABLE();
  }

 private:
  BuiltinKind kind_;
};

class TryFinally : public Expression {
 public:
  TryFinally(View<Code> body, List<resolution::View<resolution::Local>> handler_parameters, View<Expression> handler, Source::Range range)
      : Expression(range)
      , body_(body)
      , handler_parameters_(handler_parameters)
      , handler_(handler) {}
  IMPLEMENTS(TryFinally)

  View<Code> body() const { return body_; }
  List<resolution::View<resolution::Local>> handler_parameters() const { return handler_parameters_; }
  View<Expression> handler() const { return handler_; }

  void replace_body(View<Code> new_body) { body_ = new_body; }
  void replace_handler(View<Expression> new_handler) { handler_ = new_handler; }

 private:
  View<Code> body_;
  List<View<Local>> handler_parameters_;
  View<Expression> handler_;
};

class If : public Expression {
 public:
  If(View<Expression> condition, View<Expression> yes, View<Expression> no, Source::Range range)
      : Expression(range), condition_(condition), yes_(yes), no_(no) {}
  IMPLEMENTS(If)

  View<Expression> condition() const { return condition_; }
  View<Expression> yes() const { return yes_; }
  View<Expression> no() const { return no_; }

  void replace_condition(View<Expression> new_condition) { condition_ = new_condition; }
  void replace_yes(View<Expression> new_yes) { yes_ = new_yes; }
  void replace_no(View<Expression> new_no) { no_ = new_no; }

 private:
  View<Expression> condition_;
  View<Expression> yes_;
  View<Expression> no_;
};

class Not : public Expression {
 public:
  explicit Not(View<Expression> value, Source::Range range)
      : Expression(range), value_(value) {}
  IMPLEMENTS(Not)

  View<Expression> value() const { return value_; }
  void replace_value(View<Expression> new_value) { value_ = new_value; }

 private:
  View<Expression> value_;
};

class While : public Expression {
 public:
  While(View<Expression> condition, View<Expression> body, View<Expression> update, View<Local> loop_variable, Source::Range range)
      : Expression(range)
      , condition_(condition)
      , body_(body)
      , update_(update)
      , loop_variable_(loop_variable) {}
  IMPLEMENTS(While)

  View<Expression> condition() const { return condition_; }
  View<Expression> body() const { return body_; }
  View<Expression> update() const { return update_; }

  View<Local> loop_variable() const { return loop_variable_; }

  void replace_condition(View<Expression> new_condition) { condition_ = new_condition; }
  void replace_body(View<Expression> new_body) { body_ = new_body; }
  void replace_update(View<Expression> new_update) { update_ = new_update; }

 private:
  View<Expression> condition_;
  View<Expression> body_;
  View<Expression> update_;
  View<Local> loop_variable_;
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
  Code(Symbol name, List<View<Parameter>> parameters, View<Expression> body, bool is_block, Source::Range range)
      : Expression(range)
      , name_(name)
      , parameters_(parameters)
      , body_(body)
      , is_block_(is_block)
      , captured_count_(0) {
    ASSERT(captured_count_ == 0 || !is_block);
  }
  IMPLEMENTS(Code)

  Symbol name() const { return name_; }

  // Contains the captured arguments, but not the block-parameter (if it is a block).
  List<View<Parameter>> parameters() const { return parameters_; }
  void set_parameters(List<View<Parameter>> new_params) { parameters_ = new_params; }

  View<Expression> body() const { return body_; }
  bool is_block() const { return is_block_; }
  int captured_count() const { return captured_count_; }
  void set_captured_count(int count) { captured_count_ = count; }

  void replace_body(View<Expression> new_body) { body_ = new_body; }

  bool is_dead() const { return is_dead_; }
  void kill() { is_dead_ = true; }

 private:
  Symbol name_;
  List<View<Parameter>> parameters_;
  View<Expression> body_;
  bool is_block_;
  int captured_count_;

  bool is_dead_ = false;
};

class Reference : public Expression {
 public:
  explicit Reference(Source::Range range) : Expression(range) {}
  IMPLEMENTS(Reference)

  View<Node> target() const;
};

class ReferenceClass : public Reference {
 public:
  explicit ReferenceClass(View<Class> target, Source::Range range)
      : Reference(range), target_(target) {}
  IMPLEMENTS(ReferenceClass)

  View<Class> target() const { return target_; }

 private:
  View<Class> target_;
};

class ReferenceMethod : public Reference {
 public:
  ReferenceMethod(View<Method> target, Source::Range range) : Reference(range), target_(target) {}
  IMPLEMENTS(ReferenceMethod)

  View<Method> target() const { return target_; }

 private:
  View<Method> target_;
};

class ReferenceGlobal : public Reference {
 public:
  explicit ReferenceGlobal(View<Global> target, bool is_lazy, Source::Range range)
      : Reference(range), target_(target), is_lazy_(is_lazy) {}
  IMPLEMENTS(ReferenceGlobal)

  View<Global> target() const { return target_; }

  // Whether the reference to the global might trigger the lazy evaluation.
  bool is_lazy() const { return is_lazy_; }

 private:
  View<Global> target_;
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

  /// Whether the type also holds at runtime. Explicit types are checked.
  /// An inferred type (`x := b.m`) is whatever type the compiler computed
  /// for the right-hand side, which can be wrong: an overriding method can
  /// return a different type than the method it overrides.
  virtual bool has_guaranteed_type() const {
    return has_explicit_type_ || (has_guaranteed_inferred_type_ && is_effectively_final());
  }
  void mark_guaranteed_inferred_type() { has_guaranteed_inferred_type_ = true; }

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
  bool has_guaranteed_inferred_type_ = false;
  bool is_captured_ = false;
  Type type_;

 protected:
  int index_;
};

class Parameter : public Local {
 public:
  /// A type alternative for a parameter that is declared as `any`, given
  /// through a `// __TYPE-MIGRATION__ <name>: <type>` comment in front of the declaration.
  ///
  /// Temporary mechanism to migrate `any` parameters to concrete types.
  class MigrationType {
   public:
    MigrationType(Type type, bool is_deprecated, Symbol deprecation_message)
        : type_(type)
        , is_deprecated_(is_deprecated)
        , deprecation_message_(deprecation_message) {}

    Type type() const { return type_; }
    bool is_deprecated() const { return is_deprecated_; }
    /// Either empty, or starting with ". ", so it can be appended
    /// directly to a warning. Only valid if [is_deprecated].
    Symbol deprecation_message() const { return deprecation_message_; }

   private:
    Type type_;
    bool is_deprecated_;
    Symbol deprecation_message_;

    friend class ListBuilder<MigrationType>;
    MigrationType()
        : type_(Type::invalid())
        , is_deprecated_(false)
        , deprecation_message_(Symbol::invalid()) {}
  };

  Parameter(Symbol name,
            Type type,
            bool is_block,
            int index,
            bool has_default_value,
            Source::Range default_value_range,
            Source::Range range)
      : Parameter(name, type, is_block, index, -1, has_default_value, default_value_range, range) {}
  Parameter(Symbol name,
            Type type,
            bool is_block,
            int index,
            int original_index,
            bool has_default_value,
            Source::Range default_value_range,
            Source::Range range)
      : Local(name, false, is_block, type, range)  // By default parameters are not final.
      , has_default_value_(has_default_value)
      , default_value_range_(default_value_range)
      , original_index_(original_index) {
    index_ = index;
  }
  IMPLEMENTS(Parameter)

  /// The range of the default value (if one exists).
  /// This range is used for toitdoc generation and is not maintained during transformations.
  /// Once the summaries have been generated, this value shouldn't be used anymore.
  Source::Range default_value_range() const { return default_value_range_; }

  bool has_default_value() const { return has_default_value_; }
  void set_has_default_value(bool new_value) { has_default_value_ = new_value; }
  // The original index of the parameter, as written by the user.
  // We shuffle parameters around to make them more convenient, but for
  // documentation we want to keep the original ordering.
  // -1 if the parameter was not explicitly written.
  int original_index() const { return original_index_; }

  /// The type alternatives given through `// __TYPE-MIGRATION__` comments.
  /// Only set for parameters of type `any`. Empty if there are none.
  List<MigrationType> migration_types() const { return migration_types_; }
  void set_migration_types(List<MigrationType> types) {
    migration_types_ = types;
  }

 private:
  bool has_default_value_;
  Source::Range default_value_range_;
  int original_index_;
  List<MigrationType> migration_types_;
};

class CapturedLocal : public Parameter {
 public:
  CapturedLocal(View<Local> captured,
                int index,
                Source::Range range)
      : Parameter(captured->name(),
                  Type::any(), // Unused, since we forward to the captured local.
                  false,       // Unused, since we forward to the captured local.
                  index,
                  false,
                  Source::Range::invalid(),
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
  bool has_guaranteed_type() const { return captured_->has_guaranteed_type(); }
  Type type() const { return captured_->type(); }

  View<Local> local() const { return captured_; }

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
  View<Local> captured_;
};

class Block : public Local {
 public:
  Block(Symbol name, Source::Range range)
      : Local(name, true, true, range) {}
  IMPLEMENTS(Block);
};

class Dot : public Node {
 public:
  Dot(View<Expression> receiver, Symbol selector)
      : receiver_(receiver), selector_(selector) {}
  IMPLEMENTS(Dot)

  View<Expression> receiver() const { return receiver_; }
  Symbol selector() const { return selector_; }

  void replace_receiver(View<Expression> new_receiver) { receiver_ = new_receiver; }

 private:
  View<Expression> receiver_;
  Symbol selector_;
};

/// The target of an LSP operation, such as completion.
///
/// The selector of the node is the target of the operation.
class LspSelectionDot : public Dot {
 public:
  LspSelectionDot(View<Expression> receiver, Symbol selector, Symbol name)
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
  ReferenceLocal(View<Local> target, int block_depth, const Source::Range& range)
    : Reference(range), target_(target), block_depth_(block_depth) {}
  IMPLEMENTS(ReferenceLocal)

  View<Local> target() const { return target_; }
  int block_depth() const { return block_depth_; }
  bool is_block() const { return target()->is_block(); }

 private:
  View<Local> target_;
  int block_depth_;
};

class ReferenceBlock : public ReferenceLocal {
 public:
  ReferenceBlock(View<Block> target, int block_depth, Source::Range range)
      : ReferenceLocal(target, block_depth, range) {}
  IMPLEMENTS(ReferenceBlock)

  View<Block> target() const { return ReferenceLocal::target()->as_Block(); }
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
  Super(View<Expression> expression, bool is_explicit, bool is_at_end, Source::Range range)
      : Expression(range)
      , expression_(expression)
      , is_explicit_(is_explicit)
      , is_at_end_(is_at_end) {}
  IMPLEMENTS(Super)

  View<Expression> expression() const { return expression_; }
  void replace_expression(View<Expression> new_expression) { expression_ = new_expression; }

  bool is_explicit() const { return is_explicit_; }
  bool is_at_end() const { return is_at_end_; }

 private:
  View<Expression> expression_ = null;
  bool is_explicit_;
  bool is_at_end_;
};

class Call : public Expression {
 public:
  Call(List<View<Expression>> arguments, const CallShape& shape, Source::Range range)
      : Expression(range), arguments_(arguments), shape_(shape) {}
  IMPLEMENTS(Call)

  View<Node> target() const;
  List<View<Expression>> arguments() const { return arguments_; }
  CallShape shape() const { return shape_; }

  void mark_tail_call() { is_tail_call_ = true; }
  bool is_tail_call() const { return is_tail_call_; }

 private:
  List<View<Expression>> arguments_;
  CallShape shape_;
  bool is_tail_call_ = false;
};

class CallStatic : public Call {
 public:
  CallStatic(View<ReferenceMethod> method,
             const CallShape& shape,
             List<View<Expression>> arguments,
             Source::Range range)
      : Call(arguments, shape, range)
      , method_(method) {}
  CallStatic(View<ReferenceMethod> method,
             List<View<Expression>> arguments,
             const CallShape& shape,
             Source::Range range)
      : Call(arguments, shape, range)
      , method_(method) {}

  IMPLEMENTS(CallStatic)

  View<ReferenceMethod> target() const { return method_; }

  void replace_method(View<ReferenceMethod> new_target) { method_ = new_target; }

 private:
  View<ReferenceMethod> method_;
};

class Lambda : public CallStatic {
 public:
  Lambda(View<ReferenceMethod> method,
         const CallShape& shape,
         List<View<Expression>> arguments,
         Map<View<Local>, int> captured_depths,
         Source::Range range)
      : CallStatic(method, shape, arguments, range)
      , captured_depths_(std::move(captured_depths)) {}
  IMPLEMENTS(Lambda)

  View<Code> code() const { return arguments()[0]->as_Code(); }

  resolution::View<resolution::Expression> captured_args() const { return arguments()[1]; }
  void set_captured_args(resolution::View<resolution::Expression> new_captured) { arguments()[1] = new_captured; }

  Map<View<Local>, int> captured_depths() const { return captured_depths_; }

 private:
  Map<View<Local>, int> captured_depths_;
};

/// A call to a constructor.
/// Allocates an object first.
/// This class is not used for super-calls.
class CallConstructor : public CallStatic {
 public:
  CallConstructor(View<ReferenceMethod> target,
                  const CallShape& shape,
                  List<View<Expression>> arguments,
                  Source::Range range)
      : CallStatic(target, shape, arguments, range) {
    ASSERT(target->target()->is_constructor());
  }
  IMPLEMENTS(CallConstructor)

  View<Class> klass() const { return constructor()->klass(); }
  View<Constructor> constructor() const { return target()->target()->as_Constructor(); }

  bool is_box_construction() const { return is_box_construction_; }
  void mark_box_construction() { is_box_construction_ = true; }

 private:
  bool is_box_construction_ = false;
};

class CallVirtual : public Call {
 public:
  CallVirtual(View<Dot> target,
              const CallShape& shape,
              List<View<Expression>> arguments,
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
  CallVirtual(View<Dot> target,
              Opcode opcode)
      : Call(List<View<Expression>>(),
             CallShape(0).with_implicit_this(),
             Source::Range::invalid())
      , target_(target)
      , opcode_(opcode) {}
  IMPLEMENTS(CallVirtual)

  View<Dot> target() const { return target_; }
  View<Expression> receiver() const { return target_->receiver(); }
  Symbol selector() const { return target_->selector(); }

  void replace_target(View<Dot> new_target) { target_ = new_target; }

  Opcode opcode() const { return opcode_; }
  void set_opcode(Opcode new_opcode) { opcode_ = new_opcode; }

 private:
  View<Dot> target_;
  Opcode opcode_;
};

class CallBlock : public Call {
 public:
  CallBlock(View<Expression> target,
            const CallShape& shape,
            List<View<Expression>> arguments,
            Source::Range range)
      : Call(arguments, shape, range)
      , target_(target) {
    ASSERT(target->is_ReferenceBlock() ||
           (target->is_ReferenceLocal() && target->is_block()));
  }
  IMPLEMENTS(CallBlock)

  View<Expression> target() const { return target_; }

  void replace_target(View<Expression> new_target) { target_ = new_target; }

 private:
  View<Expression> target_;
};

class CallBuiltin : public Call {
 public:
  CallBuiltin(View<Builtin> builtin,
              const CallShape& shape,
              List<View<Expression>> arguments,
              Source::Range range)
      : Call(arguments, shape, range)
      , target_(builtin) {}
  IMPLEMENTS(CallBuiltin)

  View<Builtin> target() const { return target_; }

 private:
  View<Builtin> target_;
};

class Typecheck : public Expression {
 public:
  enum Kind {
    IS_CHECK,
    AS_CHECK,
    PARAMETER_AS_CHECK,
    LOCAL_AS_CHECK,
    GLOBAL_AS_CHECK,
    RETURN_AS_CHECK,
    FIELD_INITIALIZER_AS_CHECK,
    FIELD_AS_CHECK,
  };

  Typecheck(Kind kind, View<Expression> expression, Type type, Symbol type_name, Source::Range range)
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
      case GLOBAL_AS_CHECK:
      case RETURN_AS_CHECK:
      case FIELD_INITIALIZER_AS_CHECK:
      case FIELD_AS_CHECK:
        return true;
    }
    UNREACHABLE();
    return false;
  }

  View<Expression> expression() const { return expression_; }
  void replace_expression(View<Expression> expression) { expression_ = expression; }

  bool is_interface_check() const {
    return type_.is_class() && (type_.klass()->is_interface() || type_.klass()->is_mixin());
  }

  /// Returns the type name of this check.
  /// Since we might change the [type] of the check (for optimization purposes, or
  ///   because of tree-shaking), we should use the returned name for error messages.
  Symbol type_name() const { return type_name_; }

 private:
  Kind kind_;
  View<Expression> expression_;
  Type type_;
  Symbol type_name_;
};

class Return : public Expression {
 public:
  Return(View<Expression> value, bool is_end_of_method_return, Source::Range range)
      : Expression(range), value_(value), depth_(-1), is_end_of_method_return_(is_end_of_method_return) {
    if (is_end_of_method_return) ASSERT(value->is_LiteralNull());
  }
  Return(View<Expression> value, int depth, Source::Range range)
      : Expression(range), value_(value), depth_(depth), is_end_of_method_return_(false) {}
  IMPLEMENTS(Return)

  View<Expression> value() const { return value_; }

  // How many frames the return should leave.
  // -1: to the next outermost function.
  // 0: the immediately enclosing block/lambda.
  // ...
  int depth() const { return depth_; }

  void replace_value(View<Expression> new_value) { value_ = new_value; }

  bool is_end_of_method_return() const { return is_end_of_method_return_; }

 private:
  View<Expression> value_;
  int depth_;
  bool is_end_of_method_return_;
};

class LogicalBinary : public Expression {
 public:
  enum Operator {
    AND,
    OR
  };

  LogicalBinary(View<Expression> left, View<Expression> right, Operator op, Source::Range range)
      : Expression(range), left_(left), right_(right), operator_(op) {}
  IMPLEMENTS(LogicalBinary)

  View<Expression> left() const { return left_; }
  View<Expression> right() const { return right_; }
  Operator op() const { return operator_; }

  void replace_left(View<Expression> new_left) { left_ = new_left; }
  void replace_right(View<Expression> new_right) { right_ = new_right; }

 private:
  View<Expression> left_;
  View<Expression> right_;
  Operator operator_;
};

class Assignment : public Expression {
 public:
  Assignment(View<Node> left, View<Expression> right, Source::Range range)
      : Expression(range), left_(left), right_(right) {}
  IMPLEMENTS(Assignment)

  View<Node> left() const { return left_; }
  View<Expression> right() const { return right_; }

  void replace_right(View<Expression> new_right) { right_ = new_right; }

  bool is_block() const { return right_->is_block(); }

 private:
  View<Node> left_;
  View<Expression> right_;
};

class AssignmentLocal : public Assignment {
 public:
  AssignmentLocal(View<Local> left, int block_depth, View<Expression> right, Source::Range range)
      : Assignment(left, right, range), block_depth_(block_depth) {}
  IMPLEMENTS(AssignmentLocal)

  View<Local> local() const { return left()->as_Local(); }
  int block_depth() const { return block_depth_; }

 private:
  int block_depth_;
};

class AssignmentGlobal : public Assignment {
 public:
  AssignmentGlobal(View<Global> left, View<Expression> right, Source::Range range)
      : Assignment(left, right, range) {}
  IMPLEMENTS(AssignmentGlobal)

  View<Global> global() const { return left()->as_Global(); }
};

class AssignmentDefine : public Assignment {
 public:
  AssignmentDefine(View<Local> left, View<Expression> right, Source::Range range)
      : Assignment(left, right, range) {}
  IMPLEMENTS(AssignmentDefine)

  View<Local> local() const { return left()->as_Local(); }
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

} // namespace toit::compiler::resolution
} // namespace toit::compiler
} // namespace toit
