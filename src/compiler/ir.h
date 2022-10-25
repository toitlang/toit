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
  explicit Type(Class* klass) : _kind(kClass), _class(klass), _is_nullable(false) {
    ASSERT(klass != null);
  }

  static Type none() { return Type(kNone, false); }
  static Type any()  { return Type(kAny, true); }
  static Type invalid() { return Type(kInvalid, false); }

  bool is_nullable() const { return _is_nullable; }

  bool is_class() const { return _kind == kClass; }
  bool is_none() const { return _kind == kNone; }
  bool is_any() const { return _kind == kAny; }
  bool is_valid() const { return _kind != kInvalid; }
  bool is_special() const { return is_none() || is_any() || !is_valid(); }

  Class* klass() const { return _class; }

  Type to_nullable() const {
    if (is_special()) return *this;
    return Type(_kind, _class, true);
  }

  Type to_non_nullable() const {
    if (is_none() || !is_valid()) return *this;
    return Type(_kind, _class, false);
  }

  bool operator ==(const Type& other) const {
    return _kind == other._kind && _class == other._class;
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
      : _kind(kind), _class(null), _is_nullable(is_nullable) {}

  Type(int kind, Class* klass, bool is_nullable)
      : _kind(kind), _class(klass), _is_nullable(is_nullable) {}

  friend class ListBuilder<Type>;
  Type() { }

  int _kind;
  Class* _class;
  bool _is_nullable;
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
          Method* identical,
          Method* lookup_failure,
          Method* as_check_failure,
          Class* lambda_box)
      : _classes(classes)
      , _methods(methods)
      , _globals(globals)
      , _tree_roots(tree_roots)
      , _entry_points(entry_points)
      , _literal_types(literal_types)
      , _identical(identical)
      , _lookup_failure(lookup_failure)
      , _as_check_failure(as_check_failure)
      , _lambda_box(lambda_box) { }
  IMPLEMENTS(Program)

  List<Class*> classes() const { return _classes; }
  List<Method*> methods() const { return _methods; }
  List<Global*> globals() const { return _globals; }

  void replace_classes(List<Class*> new_classes) { _classes = new_classes; }
  void replace_methods(List<Method*> new_methods) { _methods = new_methods; }
  void replace_globals(List<Global*> new_globals) { _globals = new_globals; }

  void set_methods(List<Method*> methods) {
    _methods = methods;
  }

  Method* lookup_failure() const { return _lookup_failure; }
  Method* identical() const { return _identical; }
  Method* as_check_failure() const { return _as_check_failure; }

  Class* lambda_box() const { return _lambda_box; }

  List<Class*> tree_roots() const { return _tree_roots; }

  List<Method*> entry_points() const { return _entry_points; }

  List<Type> literal_types() const { return _literal_types; }

 private:
  List<Class*> _classes;
  List<Method*> _methods;
  List<Global*> _globals;
  List<Class*> _tree_roots;
  List<Method*> _entry_points;
  List<Type> _literal_types;
  Method* _identical;
  Method* _lookup_failure;
  Method* _as_check_failure;
  Class* _lambda_box;
};

class Class : public Node {
 public:
  Class(Symbol name, bool is_interface, bool is_abstract, Source::Range range)
      : _name(name)
      , _range(range)
      , _is_runtime_class(false)
      , _super(null)
      , _is_abstract(is_abstract)
      , _is_interface(is_interface)
      , _typecheck_selector(Selector<CallShape>(Symbol::invalid(), CallShape::invalid()))
      , _id(-1)
      , _start_id(-1)
      , _end_id(-1)
      , _first_subclass(null)
      , _subclass_sibling_link(null)
      , _total_field_count(-1) { }
  IMPLEMENTS(Class)

  Symbol name() const { return _name; }
  bool has_super() const { return _super != null; }
  /// The id of this class.
  /// This value is only set in the dispatch-table builder and must not be
  ///   used earlier.
  int id() const {
    ASSERT(_id != -1);
    return _id;
  }

  bool is_task_class() const { return _is_runtime_class && _name == Symbols::Task_; }
  bool is_runtime_class() const { return _is_runtime_class; }
  void mark_runtime_class() { _is_runtime_class = true; }

  Class* super() const { return _super; }
  void set_super(Class* klass) {
    ASSERT(_super == null);
    _super = klass;
  }
  void replace_super(Class* klass) {
    _super = klass;
  }

  List<Class*> interfaces() const { return _interfaces; }
  void set_interfaces(List<Class*> interfaces) {
    ASSERT(_interfaces.is_empty());
    _interfaces = interfaces;
  }
  void replace_interfaces(List<Class*> interfaces) {
    _interfaces = interfaces;
  }

  /// The unnamed constructors.
  ///
  /// The named constructors are stored in the [statics] scope.
  List<Method*> constructors() const { return _constructors; }
  void set_constructors(List<Method*> constructors) {
    ASSERT(_constructors.is_empty());
    _constructors = constructors;
  }
  void replace_constructors(List<Method*> new_constructors) { _constructors = new_constructors; }

  /// The unnamed factories.
  ///
  /// The named factories are stored in the [statics] scope.
  List<Method*> factories() const { return _factories; }
  void set_factories(List<Method*> factories) {
    ASSERT(_factories.is_empty());
    _factories = factories;
  }
  void replace_factories(List<Method*> new_factories) { _factories = new_factories; }

  StaticsScope* statics() const { return _statics; }
  void set_statics(StaticsScope* statics) {
    ASSERT(_statics == null);
    _statics = statics;
  }

  /// The elements visible for toitdoc scopes.
  /// This includes constructors, static/instance methods, static/instance fields all
  ///   mixed together.
  Scope* toitdoc_scope() const { return _toitdoc_scope; }
  void set_toitdoc_scope(Scope* scope) { _toitdoc_scope = scope; }

  List<MethodInstance*> methods() const { return _methods; }
  void set_methods(List<MethodInstance*> methods) {
    ASSERT(_methods.is_empty());
    _methods = methods;
  }
  void replace_methods(List<MethodInstance*> new_methods) { _methods = new_methods; }

  List<Field*> fields() const { return _fields; }
  void set_fields(List<Field*> fields) { _fields = fields; }

  bool is_abstract() const { return _is_abstract; }

  bool is_interface() const { return _is_interface; }

  Source::Range range() const { return _range; }

  /// These functions are set by the tree-shaker.
  bool is_instantiated() const { return _is_instantiated; }
  void set_is_instantiated(bool value) { _is_instantiated = value; }

  Selector<CallShape> typecheck_selector() const { return _typecheck_selector; }
  void set_typecheck_selector(Selector<CallShape> selector) {
    ASSERT(is_interface());
    _typecheck_selector = selector;
  }

  // A token that is dependent on the class' location.
  // Returns -1 if there is no location attached to this class.
  int location_id() const {
    auto range = this->range();
    if (!range.is_valid()) return -1;
    return range.from().token();
  }

 private:
  const Symbol _name;
  Source::Range _range;
  bool _is_runtime_class;
  Class* _super;
  List<Class*> _interfaces;
  bool _is_abstract;
  bool _is_interface;
  // Only set for interfaces.
  Selector<CallShape> _typecheck_selector;

  List<Method*> _constructors;
  List<Method*> _factories;
  List<MethodInstance*> _methods;
  List<Field*> _fields;

  StaticsScope* _statics = null;
  Scope* _toitdoc_scope = null;

  bool _is_instantiated = true;

  int _id;
  int _start_id;
  int _end_id;

 private:
  // This is redundant information.
  // For now we restrict its use to the resolver, so that modifications to the
  // program structure don't need to update these fields.
  friend class ::toit::compiler::Resolver;

  Class* _first_subclass;
  Class* _subclass_sibling_link;

  Class* first_subclass() { return _first_subclass; }
  Class* subclass_sibling() { return _subclass_sibling_link; }

  void link_subclass(Class* next_subclass) {
    next_subclass->_subclass_sibling_link = _first_subclass;
    _first_subclass = next_subclass;
  }

 public:
  // Reserved for DispatchTable and the backend:

  /// Every class in the range `start_id` .. `end_id`(exclusive) is a subclass
  /// of this class. The `start_id` might me the class itself (equal to `id()`).
  /// When this class is not instantiated, then the start_id does not include this
  /// class.
  int start_id() const { return _start_id; }
  int end_id() const { return _end_id; }

  void set_id(int id) {
    ASSERT(_id == -1);
    _id = id;
  }

  void set_start_id(int id) {
    ASSERT(_start_id == -1);
    _start_id = id;
  }

  void set_end_id(int end_id) {
    ASSERT(_end_id == -1);
    _end_id = end_id;
  }

 public:
  // Reserved for Compiler and ByteGen.
  int total_field_count() const { return _total_field_count; }
  void set_total_field_count(int count) {
    ASSERT(_total_field_count == -1);
    _total_field_count = count;
  }

  int _total_field_count;
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
      : _name(name)
      , _holder(holder)
      , _return_type(Type::invalid())
      , _use_resolution_shape(true)
      , _resolution_shape(shape)
      , _plain_shape(PlainShape::invalid())
      , _is_abstract(is_abstract)
      , _does_not_return(false)
      , _is_runtime_method(false)
      , _kind(kind)
      , _range(range)
      , _body(null)
      , _index(-1) { }

  explicit Method(Symbol name,
                  Class* holder,  // `null` if not inside a class.
                  const PlainShape& shape,
                  bool is_abstract,
                  MethodKind kind,
                  Source::Range range)
      : _name(name)
      , _holder(holder)
      , _return_type(Type::invalid())
      , _use_resolution_shape(false)
      , _resolution_shape(ResolutionShape::invalid())
      , _plain_shape(shape)
      , _is_abstract(is_abstract)
      , _does_not_return(false)
      , _is_runtime_method(false)
      , _kind(kind)
      , _range(range)
      , _body(null)
      , _index(-1) { }

 public:
  IMPLEMENTS(Method)

  Symbol name() const { return _name; }

  /// The shape of this method, as used during resolution.
  ///
  /// A resolution-shape may represent multiple method signatures. It can have
  /// optional arguments, and all arguments may be used with their respective
  /// names (if they are available).
  ResolutionShape resolution_shape() const {
    ASSERT(_use_resolution_shape && _resolution_shape.is_valid());
    return _resolution_shape;
  }

  /// The resolution shape of this method without any implicit this.
  ResolutionShape resolution_shape_no_this() const {
    ASSERT(_use_resolution_shape && _resolution_shape.is_valid());
    if (is_instance() || is_constructor()) {
      return _resolution_shape.without_implicit_this();
    }
    return _resolution_shape;
  }

  /// The unique shape of this method.
  ///
  /// This shape does not contain any optional parameters anymore.
  /// If it has named arguments, these are required.
  PlainShape plain_shape() const {
    ASSERT(!_use_resolution_shape && _plain_shape.is_valid());
    return _plain_shape;
  }
  void set_plain_shape(const PlainShape& shape) {
    _plain_shape = shape;
    _resolution_shape = ResolutionShape::invalid();
    _use_resolution_shape = false;
  }

  MethodKind kind() const { return _kind; }

  bool is_static() const { return !is_instance(); }
  bool is_global_fun() const { return kind() == GLOBAL_FUN; }
  bool is_instance() const { return kind() == INSTANCE || kind() == FIELD_INITIALIZER; }
  bool is_constructor() const { return kind() == CONSTRUCTOR; }
  bool is_factory() const { return kind() == FACTORY; }
  bool is_initializer() const { return kind() == GLOBAL_INITIALIZER; }
  bool is_field_initializer() const { return kind() == FIELD_INITIALIZER; }
  bool is_setter() const {
    if (_use_resolution_shape) return resolution_shape().is_setter();
    return plain_shape().is_setter();
  }

  bool has_implicit_this() const {
    return is_instance() || is_constructor();
  }

  bool is_abstract() const { return _is_abstract; }
  bool has_body() const { return _body != null; }

  bool does_not_return() const { return _does_not_return; }
  void mark_does_not_return() { _does_not_return = true; }

  bool is_runtime_method() const { return _is_runtime_method; }
  void mark_runtime_method() { _is_runtime_method = true; }

  Type return_type() const { return _return_type; }
  void set_return_type(Type type) {
    ASSERT(!_return_type.is_valid());
    _return_type = type;
  }
  Expression* body() const { return _body; }
  void set_body(Expression* body) {
    ASSERT(_body == null);
    _body = body;
  }

  void replace_body(Expression* new_body) { _body = new_body; }

  List<Parameter*> parameters() const { return _parameters; }
  void set_parameters(List<Parameter*> parameters) {
    ASSERT(_parameters_have_correct_index(parameters));
    _parameters = parameters;
  }

  /// Returns the syntactic holder of this method.
  /// Static functions that are declared inside a class have a holder.
  Class* holder() const { return _holder; }

  Source::Range range() const { return _range; }

  virtual bool is_synthetic() const {
    return _kind == FIELD_INITIALIZER;
  }

 private:
  const Symbol _name;
  Class* _holder;

  Type _return_type;

  bool _use_resolution_shape;

  // The `MethodShape` is used for resolution. It represents all possible
  // shapes a method can take. For example, it can have default-values, ...
  ResolutionShape _resolution_shape;

  // The `InstanceMethodShape` is used after resolution and only valid
  // for instance methods. Static methods don't need any shape after resolution
  // anymore.
  // It represents one (and only one) shape of the possible calling-conventions
  // of the method-shape.
  PlainShape _plain_shape;

  const bool _is_abstract;
  bool _does_not_return;
  bool _is_runtime_method;
  const MethodKind _kind;
  const Source::Range _range;

  List<Parameter*> _parameters;
  Expression* _body;

  static bool _parameters_have_correct_index(List<Parameter*> parameters);

 private:
  friend class ::toit::compiler::DispatchTable;
  friend class ::toit::compiler::DispatchTableBuilder;

  // The global index during emission.
  int _index;

  int index() const {
    ASSERT(_index != -1);
    return _index;
  }
  bool index_is_set() const {
    return _index != -1;
  }
  void set_index(int index) {
    ASSERT(_index == -1);
    _index = index;
  }
};

class MethodInstance : public Method {
 public:
  MethodInstance(Symbol name, Class* holder, const ResolutionShape& shape, bool is_abstract, Source::Range range)
      : Method(name, holder, shape, is_abstract, INSTANCE, range) { }
  MethodInstance(Symbol name, Class* holder, const PlainShape& shape, bool is_abstract, Source::Range range)
      : Method(name, holder, shape, is_abstract, INSTANCE, range) { }
  MethodInstance(Method::MethodKind kind, Symbol name, Class* holder, const ResolutionShape& shape, bool is_abstract, Source::Range range)
      : Method(name, holder, shape, is_abstract, kind, range) { }
  IMPLEMENTS(MethodInstance)
};

class MonitorMethod : public MethodInstance {
 public:
  MonitorMethod(Symbol name, Class* holder, const ResolutionShape& shape, Source::Range range)
      : MethodInstance(name, holder, shape, false, range) { }
  IMPLEMENTS(MonitorMethod)
};

class AdapterStub : public MethodInstance {
 public:
  AdapterStub(Symbol name, Class* holder, const PlainShape& shape, Source::Range range)
      : MethodInstance(name, holder, shape, false, range) { }
  IMPLEMENTS(AdapterStub)
};

class IsInterfaceStub : public MethodInstance {
 public:
  IsInterfaceStub(Symbol name, Class* holder, const PlainShape& shape, Source::Range range)
      : MethodInstance(name, holder, shape, false, range) { }
  IMPLEMENTS(IsInterfaceStub);
};

// TODO(florian): the kind is called "GLOBAL_FUN", but the class is called
// "MethodStatic". Not completely consistent.
class MethodStatic : public Method {
 public:
  MethodStatic(Symbol name, Class* holder, const ResolutionShape& shape, MethodKind kind, Source::Range range)
      : Method(name, holder, shape, false, kind, range) { }
  IMPLEMENTS(MethodStatic)
};

class Constructor : public Method {
 public:
  Constructor(Symbol name, Class* klass, const ResolutionShape& shape, Source::Range range)
      : Method(name, klass, shape, false, CONSTRUCTOR, range) { }

  // Synthetic default constructor.
  Constructor(Symbol name, Class* klass, Source::Range range)
      : Method(name, klass, ResolutionShape(0).with_implicit_this(), false, CONSTRUCTOR, range)
      , _is_synthetic(true) { }
  IMPLEMENTS(Constructor)

  Class* klass() const { return holder(); }
  bool is_synthetic() const { return _is_synthetic; }

 private:
  bool _is_synthetic = false;
};

class Global : public Method {
 public:
  Global(Symbol name, bool is_final, Source::Range range)
      : Method(name, null, ResolutionShape(0), false, GLOBAL_INITIALIZER, range)
      , _is_final(is_final)
      , _is_lazy(true)
      , _global_id(-1) { }
  Global(Symbol name, Class* holder, bool is_final, Source::Range range)
      : Method(name, holder, ResolutionShape(0), false, GLOBAL_INITIALIZER, range)
      , _is_final(is_final)
      , _is_lazy(true)
      , _global_id(-1) { }
  IMPLEMENTS(Global)

  // Whether this global is marked to be final.
  // Implies is_effectively_final.
  bool is_final() const { return _is_final; }

  // Whether the global is effectively final. This property is conservative and
  // might not return true for every effectively final global.
  // This property is only valid after the first resolution pass, as mutations
  // are only recorded during that pass.
  bool is_effectively_final() const { return _mutation_count == 0; }
  void register_mutation() { _mutation_count++; }

  void set_explicit_return_type(Type type) {
    Method::set_return_type(type);
    _has_explicit_type = true;
  }

  bool has_explicit_type() const {
    return _has_explicit_type;
  }

 public:
  // Reserved for ByteGen and Compiler.
  // The ids of globals must be continuous, and should therefore only be set
  // at the end of the compilation process (in case we can remove some).
  int global_id() const { return _global_id; }
  void set_global_id(int id) {
    ASSERT(_global_id == -1 && id >= 0);
    _global_id = id;
  }

  void mark_eager() {
    _is_lazy = false;
  }

 public:
  // Reserved for the ByteGen.
  // This field might be changed at a later point (after optimizations).
  bool is_lazy() { return _is_lazy; }

 private:
  int _mutation_count = 0;
  bool _is_final;
  bool _is_lazy;
  int _global_id;
  bool _has_explicit_type = false;
};

class Field : public Node {
 public:
  Field(Symbol name, Class* holder, bool is_final, Source::Range range)
      : _name(name)
      , _holder(holder)
      , _type(Type::invalid())
      , _is_final(is_final)
      , _resolved_index(-1)
      , _range(range) { }
  IMPLEMENTS(Field)

  Symbol name() const { return _name; }

  Class* holder() const { return _holder; }

  // Whether the field is marked as final.
  bool is_final() const { return _is_final; }

  Type type() const { return _type; }
  void set_type(Type type) {
    ASSERT(!_type.is_valid());
    _type = type;
  }

  Source::Range range() const { return _range; }

 public:
  // Reserved for compiler/bytegen.
  int resolved_index() const { return _resolved_index; }
  void set_resolved_index(int index) {
    ASSERT(_resolved_index == -1);
    _resolved_index = index;
  }

 private:
  Symbol _name;
  Class* _holder;
  Type _type;
  bool _is_final;
  int _resolved_index;
  Source::Range _range;
};

class FieldStub : public MethodInstance {
 public:
  FieldStub(Field* field, Class* holder, bool is_getter, Source::Range range)
      : MethodInstance(field->name(),
                       holder,
                       ResolutionShape::for_instance_field_accessor(is_getter),
                       false,
                       range)
      , _field(field)
      , _checked_type(Type::invalid()) { }
  IMPLEMENTS(FieldStub)

  Field* field() const { return _field; }
  bool is_getter() const { return !is_setter(); }

  bool is_synthetic() const { return true; }

  bool is_throwing() const { return _is_throwing; }
  void mark_throwing() { _is_throwing = true; }

  bool is_checking_setter() const {
    ASSERT(!_checked_type.is_valid() || !is_getter());
    return _checked_type.is_valid();
  }
  Type checked_type() const { return _checked_type; }
  void set_checked_type(Type checked_type) {
    ASSERT(!is_getter());
    _checked_type = checked_type;
  }

 private:
   Field* _field;
   bool _is_throwing = false;
   Type _checked_type;
};

// TODO(kasper): Not really an expression. Maybe just a node? or a body part?
class Expression : public Node {
 public:
  explicit Expression(Source::Range range) : _range(range) { }
  IMPLEMENTS(Expression)

  virtual bool is_block() const { return false; }
  Source::Range range() { return _range; }

 private:
  Source::Range _range;
};

class Error : public Expression {
 public:
  explicit Error(Source::Range range)
      : Expression(range), _nested(List<Expression*>()) { }
  Error(Source::Range range, List<ir::Expression*> nested)
      : Expression(range), _nested(nested) { }
  IMPLEMENTS(Error);

  List<Expression*> nested() const { return _nested; }
  void set_nested(List<Expression*> nested) { _nested = nested; }

 private:
  List<Expression*> _nested;
};

class Nop : public Expression {
 public:
  explicit Nop(Source::Range range) : Expression(range) { }
  IMPLEMENTS(Nop)
};

class FieldStore : public Expression {
 public:
  FieldStore(Expression* receiver,
             Field* field,
             Expression* value,
             Source::Range range)
      : Expression(range)
      , _receiver(receiver)
      , _field(field)
      , _value(value) { }
  IMPLEMENTS(FieldStore)

  Expression* receiver() const { return _receiver; }
  Field* field() const { return _field; }
  Expression* value() const { return _value; }

  void replace_value(Expression* new_value) { _value = new_value; }

  bool is_box_store() const { return _is_box_store; }
  void mark_box_store() { _is_box_store = true; }

 private:
  Expression* _receiver;
  Field* _field;
  Expression* _value;
  bool _is_box_store = false;
};

class FieldLoad : public Expression {
 public:
  FieldLoad(Expression* receiver, Field* field, Source::Range range)
      : Expression(range), _receiver(receiver), _field(field) { }
  IMPLEMENTS(FieldLoad)

  Expression* receiver() const { return _receiver; }
  Field* field() const { return _field; }

  void replace_receiver(Expression* new_receiver) { _receiver = new_receiver; }

  bool is_box_load() const { return _is_box_load; }
  void mark_box_load() { _is_box_load = true; }

 private:
  Expression* _receiver;
  Field* _field;
  bool _is_box_load = false;
};

class Sequence : public Expression {
 public:
  Sequence(List<Expression*> expressions, Source::Range range)
      : Expression(range), _expressions(expressions) { }
  IMPLEMENTS(Sequence)

  List<Expression*> expressions() const { return _expressions; }
  void replace_expressions(List<Expression*> new_expressions) { _expressions = new_expressions; }

  bool is_block() const {
    if (expressions().is_empty()) return false;
    return expressions().last()->is_block();
  }

 private:
   List<Expression*> _expressions;
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
  };

  explicit Builtin(BuiltinKind kind) : _kind(kind) { }
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
    // The global-id builtin isn't accessible from userspace.
    return null;
  }

  BuiltinKind kind() const { return _kind; }

  int arity() const {
    switch (kind()) {
      case STORE_GLOBAL:
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
  BuiltinKind _kind;
};

class TryFinally : public Expression {
 public:
  TryFinally(Code* body, List<ir::Local*> handler_parameters, Expression* handler, Source::Range range)
      : Expression(range)
      , _body(body)
      , _handler_parameters(handler_parameters)
      , _handler(handler) { }
  IMPLEMENTS(TryFinally)

  Code* body() const { return _body; }
  List<ir::Local*> handler_parameters() const { return _handler_parameters; }
  Expression* handler() const { return _handler; }

  void replace_body(Code* new_body) { _body = new_body; }
  void replace_handler(Expression* new_handler) { _handler = new_handler; }

 private:
  Code* _body;
  List<Local*> _handler_parameters;
  Expression* _handler;
};

class If : public Expression {
 public:
  If(Expression* condition, Expression* yes, Expression* no, Source::Range range)
      : Expression(range), _condition(condition), _yes(yes), _no(no) { }
  IMPLEMENTS(If)

  Expression* condition() const { return _condition; }
  Expression* yes() const { return _yes; }
  Expression* no() const { return _no; }

  void replace_condition(Expression* new_condition) { _condition = new_condition; }
  void replace_yes(Expression* new_yes) { _yes = new_yes; }
  void replace_no(Expression* new_no) { _no = new_no; }

 private:
  Expression* _condition;
  Expression* _yes;
  Expression* _no;
};

class Not : public Expression {
 public:
  explicit Not(Expression* value, Source::Range range)
      : Expression(range), _value(value) { }
  IMPLEMENTS(Not)

  Expression* value() const { return _value; }
  void replace_value(Expression* new_value) { _value = new_value; }

 private:
  Expression* _value;
};

class While : public Expression {
 public:
  While(Expression* condition, Expression* body, Expression* update, Local* loop_variable, Source::Range range)
      : Expression(range)
      , _condition(condition)
      , _body(body)
      , _update(update)
      , _loop_variable(loop_variable) { }
  IMPLEMENTS(While)

  Expression* condition() const { return _condition; }
  Expression* body() const { return _body; }
  Expression* update() const { return _update; }

  Local* loop_variable() const { return _loop_variable; }

  void replace_condition(Expression* new_condition) { _condition = new_condition; }
  void replace_body(Expression* new_body) { _body = new_body; }
  void replace_update(Expression* new_update) { _update = new_update; }

 private:
  Expression* _condition;
  Expression* _body;
  Expression* _update;
  Local* _loop_variable;
};

class LoopBranch : public Expression {
 public:
  LoopBranch(bool is_break, int loop_depth, Source::Range range)
      : Expression(range), _is_break(is_break), _block_depth(loop_depth) { }
  IMPLEMENTS(LoopBranch)

  bool is_break() const { return _is_break; }
  int block_depth() const { return _block_depth; }

 private:
  bool _is_break;
  int _block_depth;
};

class Code : public Expression {
 public:
  Code(List<Parameter*> parameters, Expression* body, bool is_block, Source::Range range)
      : Expression(range)
      , _parameters(parameters)
      , _body(body)
      , _is_block(is_block)
      , _captured_count(0) {
    ASSERT(_captured_count == 0 || !is_block);
  }
  IMPLEMENTS(Code)

  // Contains the captured arguments, but not the block-parameter (if it is a block).
  List<Parameter*> parameters() const { return _parameters; }
  void set_parameters(List<Parameter*> new_params) { _parameters = new_params; }

  Expression* body() const { return _body; }
  bool is_block() const { return _is_block; }
  int captured_count() const { return _captured_count; }
  void set_captured_count(int count) { _captured_count = count; }

  void replace_body(Expression* new_body) { _body = new_body; }

 private:
  List<Parameter*> _parameters;
  Expression* _body;
  bool _is_block;
  int _captured_count;
};

class Reference : public Expression {
 public:
  explicit Reference(Source::Range range) : Expression(range) { }
  IMPLEMENTS(Reference)

  virtual Node* target() const = 0;
};

class ReferenceClass : public Reference {
 public:
  explicit ReferenceClass(Class* target, Source::Range range)
      : Reference(range), _target(target) { }
  IMPLEMENTS(ReferenceClass)

  Class* target() const { return _target; }

 private:
  Class* _target;
};

class ReferenceMethod : public Reference {
 public:
  ReferenceMethod(Method* target, Source::Range range) : Reference(range), _target(target) { }
  IMPLEMENTS(ReferenceMethod)

  Method* target() const { return _target; }

 private:
  Method* _target;
};

class ReferenceGlobal : public Reference {
 public:
  explicit ReferenceGlobal(Global* target, bool is_lazy, Source::Range range)
      : Reference(range), _target(target), _is_lazy(is_lazy) { }
  IMPLEMENTS(ReferenceGlobal)

  Global* target() const { return _target; }

  // Whether the reference to the global might trigger the lazy evaluation.
  bool is_lazy() const { return _is_lazy; }

 private:
  Global* _target;
  bool _is_lazy;
};

class Local : public Node {
 public:
  Local(Symbol name, bool is_final, bool is_block, Type type, Source::Range range)
      : _name(name)
      , _range(range)
      , _is_final(is_final)
      , _is_block(is_block)
      , _has_explicit_type(type.is_valid())
      , _type(type)
      , _index(-1) { }
  Local(Symbol name, bool is_final, bool is_block, Source::Range range)
      : Local(name, is_final, is_block, Type::invalid(), range) { }
  IMPLEMENTS(Local)

  Symbol name() const { return _name; }

  /// Whether this local is marked as final.
  virtual bool is_final() const { return _is_final; }

  /// Whether this local is effectively final.
  /// This property is only valid after the first resolution pass, as mutations
  /// are only recorded during that pass.
  virtual bool is_effectively_final() const { return _mutation_count == 0; }
  virtual void register_mutation() { _mutation_count++; }

  virtual bool is_captured() const { return _is_captured; }
  virtual void mark_captured() { _is_captured = true; }
  virtual int mutation_count() const { return _mutation_count; }

  void mark_effectively_final_loop_variable() { _is_effectively_final_loop_variable = true; }
  /// Whether this local is a loop variable that is unchanged in the loop's body.
  virtual bool is_effectively_final_loop_variable() const { return _is_effectively_final_loop_variable; }

  virtual bool is_block() const { return _is_block; }

  virtual bool has_explicit_type() const { return _has_explicit_type; }

  // The index is required for bytecode generation.
  // The index for parameters is fixed, whereas the one for locals is set
  // during bytecode emission.
  int index() const {
    ASSERT(!is_Parameter() || _index != -1);
    return _index;
  }
  void set_index(int index) {
    ASSERT(!is_Parameter());
    _index = index;
  }

  virtual Type type() const { return _type; }
  virtual void set_type(Type type) {
    ASSERT(type.is_valid());
    _type = type;
  }

  Source::Range range() const { return _range; }

 private:
  Symbol _name;
  Source::Range _range;
  int _mutation_count = 0;
  bool _is_final;
  bool _is_effectively_final_loop_variable = false;
  bool _is_block;
  bool _has_explicit_type;
  bool _is_captured = false;
  Type _type;

 protected:
  int _index;
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
      , _has_default_value(has_default_value)
      , _original_index(original_index) {
    _index = index;
  }
  IMPLEMENTS(Parameter)

  bool has_default_value() const { return _has_default_value; }
  void set_has_default_value(bool new_value) { _has_default_value = new_value; }
  // The original index of the parameter, as written by the user.
  // We shuffle parameters around to make them more convenient, but for
  // documentation we want to keep the original ordering.
  // -1 if the parameter was not explicitly written.
  int original_index() const { return _original_index; }

 private:
  bool _has_default_value;
  int _original_index;
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
      , _captured(captured) {
  }
  IMPLEMENTS(CapturedLocal)

  bool is_final() const { return _captured->is_final(); }
  bool is_effectively_final() const { return _captured->is_effectively_final(); }
  bool is_effectively_final_loop_variable() const {
    return _captured->is_effectively_final_loop_variable();
  }
  void register_mutation() { _captured->register_mutation(); }
  int mutation_count() const { return _captured->mutation_count(); }

  bool is_block() const { return _captured->is_block(); }
  bool has_explicit_type() const { return _captured->has_explicit_type(); }
  Type type() const { return _captured->type(); }

  Local* local() const { return _captured; }

  virtual void set_type(Type type) {
    UNREACHABLE();
  }

  void mark_captured() {
    // Can be ignored, since we already represent a captured variable.
    ASSERT(_captured->is_captured());
  }
  bool is_captured() const {
    ASSERT(_captured->is_captured());
    return true;
  }

 private:
  Local* _captured;
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
      : _receiver(receiver), _selector(selector) { }
  IMPLEMENTS(Dot)

  Expression* receiver() const { return _receiver; }
  Symbol selector() const { return _selector; }

  void replace_receiver(Expression* new_receiver) { _receiver = new_receiver; }

 private:
  Expression* _receiver;
  Symbol _selector;
};

/// The target of an LSP operation, such as completion.
///
/// The selector of the node is the target of the operation.
class LspSelectionDot : public Dot {
 public:
  LspSelectionDot(Expression* receiver, Symbol selector, Symbol name)
      : Dot(receiver, selector)
      , _name(name) {}
  IMPLEMENTS(LspSelectionDot)

  bool is_for_named() const { return _name.is_valid(); }
  Symbol name() const { return _name; }

 private:
  Symbol _name;
};

class ReferenceLocal : public Reference {
 public:
  ReferenceLocal(Local* target, int block_depth, const Source::Range& range)
    : Reference(range), _target(target), _block_depth(block_depth) { }
  IMPLEMENTS(ReferenceLocal)

  Local* target() const { return _target; }
  int block_depth() const { return _block_depth; }
  bool is_block() const { return target()->is_block(); }

 private:
  Local* _target;
  int _block_depth;
};

class ReferenceBlock : public ReferenceLocal {
 public:
  ReferenceBlock(Block* target, int block_depth, Source::Range range)
      : ReferenceLocal(target, block_depth, range) { }
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
      , _is_explicit(false)
      , _is_at_end(is_at_end) { }
  Super(Expression* expression, bool is_explicit, bool is_at_end, Source::Range range)
      : Expression(range)
      , _expression(expression)
      , _is_explicit(is_explicit)
      , _is_at_end(is_at_end) { }
  IMPLEMENTS(Super)

  Expression* expression() const { return _expression; }
  void replace_expression(Expression* new_expression) { _expression = new_expression; }

  bool is_explicit() const { return _is_explicit; }
  bool is_at_end() const { return _is_at_end; }

 private:
  Expression* _expression = null;
  bool _is_explicit;
  bool _is_at_end;
};

class Call : public Expression {
 public:
  Call(List<Expression*> arguments, const CallShape& shape, Source::Range range)
      : Expression(range), _arguments(arguments), _shape(shape) { }
  IMPLEMENTS(Call)

  virtual Node* target() const = 0;
  List<Expression*> arguments() const { return _arguments; }
  CallShape shape() const { return _shape; }

  void mark_tail_call() { _is_tail_call = true; }
  bool is_tail_call() const { return _is_tail_call; }

 private:
  List<Expression*> _arguments;
  CallShape _shape;
  bool _is_tail_call = false;
};

class CallStatic : public Call {
 public:
  CallStatic(ReferenceMethod* method,
             const CallShape& shape,
             List<Expression*> arguments,
             Source::Range range)
      : Call(arguments, shape, range)
      , _method(method) { }
  CallStatic(ReferenceMethod* method,
             List<Expression*> arguments,
             const CallShape& shape,
             Source::Range range)
      : Call(arguments, shape, range)
      , _method(method) { }

  IMPLEMENTS(CallStatic)

  ReferenceMethod* target() const { return _method; }

  void replace_method(ReferenceMethod* new_target) { _method = new_target; }

 private:
  ReferenceMethod* _method;
};

class Lambda : public CallStatic {
 public:
  Lambda(ReferenceMethod* method,
         const CallShape& shape,
         List<Expression*> arguments,
         Map<Local*, int> captured_depths,
         Source::Range range)
      : CallStatic(method, shape, arguments, range)
      , _captured_depths(captured_depths) {}
  IMPLEMENTS(Lambda)

  Code* code() const { return arguments()[0]->as_Code(); }

  ir::Expression* captured_args() const { return arguments()[1]; }
  void set_captured_args(ir::Expression* new_captured) { arguments()[1] = new_captured; }

  Map<Local*, int> captured_depths() const { return _captured_depths; }

 private:
  Map<Local*, int> _captured_depths;
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

  bool is_box_construction() const { return _is_box_construction; }
  void mark_box_construction() { _is_box_construction = true; }

 private:
  bool _is_box_construction = false;
};

class CallVirtual : public Call {
 public:
  CallVirtual(Dot* target,
              const CallShape& shape,
              List<Expression*> arguments,
              Source::Range range)
      : Call(arguments, shape, range)
      , _target(target)
      , _opcode(INVOKE_VIRTUAL) {
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
      , _target(target)
      , _opcode(opcode) { }
  IMPLEMENTS(CallVirtual)

  Dot* target() const { return _target; }
  Expression* receiver() const { return _target->receiver(); }
  Symbol selector() const { return _target->selector(); }

  void replace_target(Dot* new_target) { _target = new_target; }

  Opcode opcode() const { return _opcode; }
  void set_opcode(Opcode new_opcode) { _opcode = new_opcode; }

 private:
  Dot* _target;
  Opcode _opcode;
};

class CallBlock : public Call {
 public:
  CallBlock(Expression* target,
            const CallShape& shape,
            List<Expression*> arguments,
            Source::Range range)
      : Call(arguments, shape, range)
      , _target(target) {
    ASSERT(target->is_ReferenceBlock() ||
           (target->is_ReferenceLocal() && target->is_block()));
  }
  IMPLEMENTS(CallBlock)

  Expression* target() const { return _target; }

  void replace_target(Expression* new_target) { _target = new_target; }

 private:
  Expression* _target;
};

class CallBuiltin : public Call {
 public:
  CallBuiltin(Builtin* builtin,
              const CallShape& shape,
              List<Expression*> arguments,
              Source::Range range)
      : Call(arguments, shape, range)
      , _target(builtin) { }
  IMPLEMENTS(CallBuiltin)

  Builtin* target() const { return _target; }

 private:
  Builtin* _target;
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
      , _kind(kind)
      , _expression(expression)
      , _type(type)
      , _type_name(type_name) { }
  IMPLEMENTS(Typecheck);

  Type type() const { return _type; }

  Kind kind() const { return _kind; }

  /// Whether this is an 'is' or 'as' check.
  bool is_as_check() const {
    switch (_kind) {
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

  Expression* expression() const { return _expression; }
  void replace_expression(Expression* expression) { _expression = expression; }

  bool is_interface_check() const {
    return _type.is_class() && _type.klass()->is_interface();
  }

  /// Returns the type name of this check.
  /// Since we might change the [type] of the check (for optimization purposes, or
  ///   because of tree-shaking), we should use the returned name for error messages.
  Symbol type_name() const { return _type_name; }

 private:
  Kind _kind;
  Expression* _expression;
  Type _type;
  Symbol _type_name;
};

class Return : public Expression {
 public:
  Return(Expression* value, bool is_end_of_method_return, Source::Range range)
      : Expression(range), _value(value), _depth(-1), _is_end_of_method_return(is_end_of_method_return) {
    if (is_end_of_method_return) ASSERT(value->is_LiteralNull());
  }
  Return(Expression* value, int depth, Source::Range range)
      : Expression(range), _value(value), _depth(depth), _is_end_of_method_return(false) { }
  IMPLEMENTS(Return)

  Expression* value() const { return _value; }

  // How many frames the return should leave.
  // -1: to the next outermost function.
  // 0: the immediately enclosing block/lambda.
  // ...
  int depth() const { return _depth; }

  void replace_value(Expression* new_value) { _value = new_value; }

  bool is_end_of_method_return() const { return _is_end_of_method_return; }

 private:
  Expression* _value;
  int _depth;
  bool _is_end_of_method_return;
};

class LogicalBinary : public Expression {
 public:
  enum Operator {
    AND,
    OR
  };

  LogicalBinary(Expression* left, Expression* right, Operator op, Source::Range range)
      : Expression(range), _left(left), _right(right), _operator(op) { }
  IMPLEMENTS(LogicalBinary)

  Expression* left() const { return _left; }
  Expression* right() const { return _right; }
  Operator op() const { return _operator; }

  void replace_left(Expression* new_left) { _left = new_left; }
  void replace_right(Expression* new_right) { _right = new_right; }

 private:
  Expression* _left;
  Expression* _right;
  Operator _operator;
};

class Assignment : public Expression {
 public:
  Assignment(Node* left, Expression* right, Source::Range range)
      : Expression(range), _left(left), _right(right) { }
  IMPLEMENTS(Assignment)

  Node* left() const { return _left; }
  Expression* right() const { return _right; }

  void replace_right(Expression* new_right) { _right = new_right; }

  bool is_block() const { return _right->is_block(); }

 private:
  Node* _left;
  Expression* _right;
};

class AssignmentLocal : public Assignment {
 public:
  AssignmentLocal(Local* left, int block_depth, Expression* right, Source::Range range)
      : Assignment(left, right, range), _block_depth(block_depth) { }
  IMPLEMENTS(AssignmentLocal)

  Local* local() const { return left()->as_Local(); }
  int block_depth() const { return _block_depth; }

 private:
  int _block_depth;
};

class AssignmentGlobal : public Assignment {
 public:
  AssignmentGlobal(Global* left, Expression* right, Source::Range range)
      : Assignment(left, right, range) { }
  IMPLEMENTS(AssignmentGlobal)

  Global* global() const { return left()->as_Global(); }
};

class AssignmentDefine : public Assignment {
 public:
  AssignmentDefine(Local* left, Expression* right, Source::Range range)
      : Assignment(left, right, range) { }
  IMPLEMENTS(AssignmentDefine)

  Local* local() const { return left()->as_Local(); }
};

class Literal : public Expression {
 public:
  explicit Literal(Source::Range range) : Expression(range) { }
  IMPLEMENTS(Literal)
};

class LiteralNull : public Literal {
 public:
  explicit LiteralNull(Source::Range range) : Literal(range) { }
  IMPLEMENTS(LiteralNull)
};


// Used to indicate that a field/variable hasn't been initialized yet.
// It is equivalent to `null`, but we check statically that it is never
//   read.
class LiteralUndefined : public Literal {
 public:
  LiteralUndefined(Source::Range range) : Literal(range) { }
  IMPLEMENTS(LiteralUndefined)
};

class LiteralInteger : public Literal {
 public:
  explicit LiteralInteger(int64 value, Source::Range range) : Literal(range), _value(value) { }
  IMPLEMENTS(LiteralInteger)

  int64 value() const { return _value; }

 private:
  int64 _value;
};

class LiteralFloat : public Literal {
 public:
  explicit LiteralFloat(double value, Source::Range range) : Literal(range), _value(value) { }
  IMPLEMENTS(LiteralFloat)

  double value() const { return _value; }

 private:
  double _value;
};

class LiteralString : public Literal {
 public:
  LiteralString(const char* value, int length, Source::Range range)
      : Literal(range), _value(value), _length(length) { }
  IMPLEMENTS(LiteralString)

  const char* value() const { return _value; }
  int length() const { return _length; }

 private:
  const char* _value;
  int _length;
};

class LiteralByteArray : public Literal {
 public:
  LiteralByteArray(List<uint8> data, Source::Range range) : Literal(range), _data(data) { }
  IMPLEMENTS(LiteralByteArray)

  List<uint8> data() { return _data; }

 private:
  List<uint8> _data;
};

class LiteralBoolean : public Literal {
 public:
  explicit LiteralBoolean(bool value, Source::Range range) : Literal(range), _value(value) { }
  IMPLEMENTS(LiteralBoolean)

  bool value() const { return _value; }

 private:
  bool _value;
};

class PrimitiveInvocation : public Expression {
 public:
  PrimitiveInvocation(Symbol module,
                      Symbol primitive,
                      int module_index,
                      int primitive_index,
                      Source::Range range)
      : Expression(range)
      , _module(module)
      , _primitive(primitive)
      , _module_index(module_index)
      , _primitive_index(primitive_index) { }
  IMPLEMENTS(PrimitiveInvocation)

  Symbol module() const { return _module; }
  Symbol primitive() const { return _primitive; }
  int module_index() const { return _module_index; }
  int primitive_index() const { return _primitive_index; }

 private:
  Symbol _module;
  Symbol _primitive;
  int _module_index;
  int _primitive_index;
};

#undef IMPLEMENTS

} // namespace toit::compiler::ir
} // namespace toit::compiler
} // namespace toit
