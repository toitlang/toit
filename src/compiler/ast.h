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

#include <string>

#include "list.h"
#include "sources.h"
#include "symbol.h"
#include "token.h"
#include "toitdoc.h"

namespace toit {
namespace compiler {

namespace ast {

class Node;

#define NODES(V)                \
  V(Unit)                       \
  V(Import)                     \
  V(Export)                     \
  V(Class)                      \
  V(Declaration)                \
  V(Field)                      \
  V(Method)                     \
  V(Expression)                 \
  V(Error)                      \
  V(NamedArgument)              \
  V(BreakContinue)              \
  V(Parenthesis)                \
  V(Block)                      \
  V(Lambda)                     \
  V(Sequence)                   \
  V(DeclarationLocal)           \
  V(If)                         \
  V(While)                      \
  V(For)                        \
  V(TryFinally)                 \
  V(Return)                     \
  V(Unary)                      \
  V(Binary)                     \
  V(Call)                       \
  V(Dot)                        \
  V(Index)                      \
  V(IndexSlice)                 \
  V(Identifier)                 \
  V(Nullable)                   \
  V(LspSelection)               \
  V(Parameter)                  \
  V(LiteralNull)                \
  V(LiteralUndefined)           \
  V(LiteralBoolean)             \
  V(LiteralInteger)             \
  V(LiteralCharacter)           \
  V(LiteralString)              \
  V(LiteralStringInterpolation) \
  V(LiteralFloat)               \
  V(LiteralArray)               \
  V(LiteralList)                \
  V(LiteralByteArray)           \
  V(LiteralSet)                 \
  V(LiteralMap)                 \
  V(ToitdocReference)           \

#define DECLARE(name) class name;
NODES(DECLARE)
#undef DECLARE

class Visitor {
 public:
  virtual void visit(Node* node);

#define DECLARE(name) virtual void visit_##name(name* node);
NODES(DECLARE)
#undef DECLARE
};

class TraversingVisitor : public Visitor {
 public:
#define DECLARE(name) virtual void visit_##name(name* node);
NODES(DECLARE)
#undef DECLARE
};

class Node {
 public:
  Node() : _range(Source::Range::invalid()) { }
  virtual void accept(Visitor* visitor) = 0;

  Source::Range range() const { return _range; }
  void set_range(Source::Range value) { _range = value; }

  void print();

#define DECLARE(name)                              \
  virtual bool is_##name() const { return false; } \
  virtual name* as_##name() { return null; }
NODES(DECLARE)
#undef DECLARE

  virtual const char* node_type() const { return "Node"; }

 private:
  Source::Range _range;
};

#define IMPLEMENTS(name)                                                 \
  virtual void accept(Visitor* visitor) { visitor->visit_##name(this); } \
  virtual bool is_##name() const { return true; }                        \
  virtual name* as_##name() { return this; }                             \
  virtual const char* node_type() const { return #name; }

class Unit : public Node {
 public:
  Unit(Source* source, List<Import*> imports, List<Export*> exports, List<Node*> declarations)
      : _is_error_unit(false)
      , _source(source)
      , _imports(imports)
      , _exports(exports)
      , _declarations(declarations) { }
  explicit Unit(bool is_error_unit)
      : _is_error_unit(is_error_unit)
      , _source(null)
      , _imports(List<Import*>())
      , _exports(List<Export*>())
      , _declarations(List<Node*>()) {
    ASSERT(is_error_unit);
  }

  IMPLEMENTS(Unit)

  const char* absolute_path() const {
    return _source == null ? "" : _source->absolute_path();
  }
  std::string error_path() const {
    return _source == null ? std::string("") : _source->error_path();
  }
  Source* source() const { return _source; }
  List<Import*> imports() const { return _imports; }
  List<Export*> exports() const { return _exports; }
  List<Node*> declarations() const { return _declarations; }
  void set_declarations(List<Node*> new_declarations) {
    _declarations = new_declarations;
  }

  bool is_error_unit() const { return _is_error_unit; }

  Toitdoc<ast::Node*> toitdoc() const { return _toitdoc; }
  void set_toitdoc(Toitdoc<ast::Node*> toitdoc) {
    _toitdoc = toitdoc;
  }

 private:
  bool _is_error_unit;
  Source* _source;
  List<Import*> _imports;
  List<Export*> _exports;
  List<Node*> _declarations;
  Toitdoc<ast::Node*> _toitdoc = Toitdoc<ast::Node*>::invalid();
};

class Import : public Node {
 public:
  Import(bool is_relative,
         int dot_outs,
         List<Identifier*> segments,
         Identifier* prefix,
         List<Identifier*> show_identifiers,
         bool show_all)
      : _is_relative(is_relative)
      , _dot_outs(dot_outs)
      , _segments(segments)
      , _prefix(prefix)
      , _show_identifiers(show_identifiers)
      , _show_all(show_all)
      , _unit(null) {
    // Can't have a prefix with show.
    ASSERT(prefix == null || show_identifiers.is_empty());
    // Can't have a prefix with show-all.
    ASSERT(prefix == null || !show_all)
    // Can't have show-all and identifiers.
    ASSERT(show_identifiers.is_empty() || !show_all);
  }
  IMPLEMENTS(Import)

  bool is_relative() const { return _is_relative; }

  /// The number of dot-outs.
  ///
  /// For example: `import ...foo` has 2 dot-outs. The first dot is only a
  ///   signal that the import is relative.
  int dot_outs() const { return _dot_outs; }

  List<Identifier*> segments() const { return _segments; }

  /// Returns null if there wasn't any prefix.
  Identifier* prefix() const { return _prefix; }

  List<Identifier*> show_identifiers() const { return _show_identifiers; }

  bool show_all() const { return _show_all; }

  Unit* unit() const { return _unit; }
  void set_unit(Unit* unit) { _unit = unit; }

 private:
  bool _is_relative;
  int _dot_outs;
  List<Identifier*> _segments;
  Identifier* _prefix;
  List<Identifier*> _show_identifiers;
  bool _show_all;
  Unit* _unit;
};

class Export : public Node {
 public:
  explicit Export(List<Identifier*> identifiers) : _identifiers(identifiers), _export_all(false) { }
  explicit Export(bool export_all) : _export_all(export_all) { }
  IMPLEMENTS(Export)

  List<Identifier*> identifiers() const { return _identifiers; }
  bool export_all() const { return _export_all; }

 private:
  List<Identifier*> _identifiers;
  bool _export_all;
};

class Class : public Node {
 public:
  // Super is either an identifier or a prefixed identifier (that is, a Dot).
  Class(Identifier* name,
        Expression* super,
        List<Expression*> interfaces,
        List<Declaration*> members,
        bool is_abstract,
        bool is_monitor,
        bool is_interface)
      : _name(name)
      , _super(super)
      , _interfaces(interfaces)
      , _members(members)
      , _is_abstract(is_abstract)
      , _is_monitor(is_monitor)
      , _is_interface(is_interface) { }
  IMPLEMENTS(Class)

  bool has_super() const { return _super != null; }

  Identifier* name() const { return _name; }
  Expression* super() const { return _super; }
  List<Expression*> interfaces() const { return _interfaces; }
  List<Declaration*> members() const { return _members; }

  bool is_abstract() const { return _is_abstract; }
  bool is_monitor() const { return _is_monitor; }
  bool is_interface() const { return _is_interface; }

  void set_toitdoc(Toitdoc<ast::Node*> toitdoc) {
    _toitdoc = toitdoc;
  }
  Toitdoc<ast::Node*> toitdoc() const { return _toitdoc; }

 private:
  Identifier* _name;
  Expression* _super;
  List<Expression*> _interfaces;
  List<Declaration*> _members;
  bool _is_abstract;
  bool _is_monitor;
  bool _is_interface;
  Toitdoc<ast::Node*> _toitdoc = Toitdoc<ast::Node*>::invalid();
};

class Expression : public Node {
 public:
  IMPLEMENTS(Expression)
};

class Error : public Expression {
 public:
  IMPLEMENTS(Error);
};

class NamedArgument : public Expression {
 public:
  NamedArgument(Identifier* name, bool inverted, Expression* expression)
      : _name(name)
      , _inverted(inverted)
      , _expression(expression) { }
  IMPLEMENTS(NamedArgument)

  Identifier* name() const { return _name; }
  // Expression may be null, if there wasn't any `=`.
  Expression* expression() const { return _expression; }

  // Whether the named argument was prefixed with a `no-`.
  bool inverted() const { return _inverted; }

 private:
  Identifier* _name;
  bool _inverted;
  Expression* _expression;
};

class Declaration : public Node {
 public:
  explicit Declaration(Expression* name_or_dot)  // name must be an Identifier or a Dot.
      : _name_or_dot(name_or_dot) { }
  IMPLEMENTS(Declaration)

  virtual Identifier* name() const {
    ASSERT(_name_or_dot->is_Identifier());
    return _name_or_dot->as_Identifier();
  }

  Expression* name_or_dot() const { return _name_or_dot; }

  void set_toitdoc(Toitdoc<ast::Node*> toitdoc) {
    _toitdoc = toitdoc;
  }

  Toitdoc<ast::Node*> toitdoc() const { return _toitdoc; }

private:
  Expression* _name_or_dot;
  Toitdoc<ast::Node*> _toitdoc = Toitdoc<ast::Node*>::invalid();
};

class Identifier : public Expression {
 public:
  explicit Identifier(Symbol data) : _data(data) { }
  IMPLEMENTS(Identifier)

  Symbol data() const { return _data; }

 private:
   const Symbol _data;
};

class Nullable : public Expression {
 public:
  explicit Nullable(Expression* type) : _type(type) { }
  IMPLEMENTS(Nullable)

  Expression* type() const { return _type; }

 private:
  Expression* _type;
};

/// The selection of an LSP request.
class LspSelection : public Identifier {
 public:
  explicit LspSelection(Symbol data) : Identifier(data) { }
  IMPLEMENTS(LspSelection)
};

class Field : public Declaration {
 public:
  Field(Identifier* name,
        Expression* type,
        Expression* initializer,
        bool is_static,
        bool is_abstract,
        bool is_final)
      : Declaration(name)
      , _type(type)
      , _initializer(initializer)
      , _is_static(is_static)
      , _is_abstract(is_abstract)
      , _is_final(is_final) { }
  IMPLEMENTS(Field)

  Expression* type() const { return _type; }
  Expression* initializer() const { return _initializer; }
  bool is_static() const { return _is_static; }
  bool is_abstract() const { return _is_abstract; }
  bool is_final() const { return _is_final; }

 private:
  Expression* _type;
  Expression* _initializer;
  bool _is_static;
  bool _is_abstract;
  bool _is_final;
};

class Method : public Declaration {
 public:
  Method(Expression* name_or_dot,  // Identifier* or Dot*
         Expression* return_type,  // null, Identififer* or Dot*
         bool is_setter,
         bool is_static,
         bool is_abstract,
         List<Parameter*> parameters,
         Sequence* body)
      : Declaration(name_or_dot)
      , _return_type(return_type)
      , _is_setter(is_setter)
      , _is_static(is_static)
      , _is_abstract(is_abstract)
      , _parameters(parameters)
      , _body(body) { }
  IMPLEMENTS(Method)

  Expression* return_type() const { return _return_type; }
  bool is_setter() const { return _is_setter; }
  bool is_static() const { return _is_static; }
  bool is_abstract() const { return _is_abstract; }

  List<Parameter*> parameters() const { return _parameters; }

  /// Might be null if there was no body.
  Sequence* body() const { return _body; }

  /// The arity of the function, including block parameters, but not
  /// including implicit `this` arguments.
  int arity() const { return _parameters.length(); }

  Identifier* name() const {
    FATAL("don't use");
    return null;
  }

  Identifier* safe_name() const {
    ASSERT(name_or_dot()->is_Identifier());
    return name_or_dot()->as_Identifier();
  }

 private:
  Expression* _return_type;
  bool _is_setter;
  bool _is_static;
  bool _is_abstract;
  List<Parameter*> _parameters;

  Sequence* _body;

  List<Expression*> _initializers;
};

class BreakContinue : public Expression {
 public:
  BreakContinue(bool is_break) : BreakContinue(is_break, null, null) { }
  BreakContinue(bool is_break, Expression* value, Identifier* label)
      : _is_break(is_break)
      , _value(value)
      , _label(label) { }
  IMPLEMENTS(BreakContinue)

  bool is_break() const { return _is_break; }
  Expression* value() const { return _value; }
  Identifier* label() const { return _label; }

 private:
  bool _is_break;
  Expression* _value;
  Identifier* _label;
};

class Parenthesis : public Expression {
 public:
  explicit Parenthesis(Expression* expression) : _expression(expression) { }
  IMPLEMENTS(Parenthesis)

  Expression* expression() const { return _expression; }

 private:
  Expression* _expression;
};

class Block : public Expression {
 public:
  Block(Sequence* body, List<Parameter*> parameters)
      : _body(body)
      , _parameters(parameters) { }
  IMPLEMENTS(Block)

  Sequence* body() const { return _body; }

  List<Parameter*> parameters() const { return _parameters; }

 private:
  Sequence* _body;
  List<Parameter*> _parameters;
};

class Lambda : public Expression {
 public:
  Lambda(Sequence* body, List<Parameter*> parameters)
      : _body(body)
      , _parameters(parameters) { }
  IMPLEMENTS(Lambda)

  Sequence* body() const { return _body; }

  List<Parameter*> parameters() const { return _parameters; }

 private:
  Sequence* _body;
  List<Parameter*> _parameters;
};

class Sequence : public Expression {
 public:
  explicit Sequence(List<Expression*> expressions)
      : _expressions(expressions) { }
  IMPLEMENTS(Sequence)

  List<Expression*> expressions() const { return _expressions; }

 private:
  List<Expression*> _expressions;
};

class DeclarationLocal : public Expression {
 public:
  DeclarationLocal(Token::Kind kind, Identifier* name, Expression* type, Expression* value)
      : _kind(kind)
      , _name(name)
      , _type(type)
      , _value(value) { }
  IMPLEMENTS(DeclarationLocal)

  Token::Kind kind() const { return _kind; }
  Identifier* name() const { return _name; }
  Expression* type() const { return _type; }
  Expression* value() const { return _value; }

 private:
  Token::Kind _kind;
  Identifier* _name;
  Expression* _type;
  Expression* _value;
};

class If : public Expression {
 public:
  If(Expression* expression, Expression* yes, Expression* no)
      : _expression(expression)
      , _yes(yes)
      , _no(no) { }
  IMPLEMENTS(If)

  Expression* expression() const { return _expression; }
  Expression* yes() const { return _yes; }
  Expression* no() const { return _no; }

  void set_no(Expression* no) {
    ASSERT(_no == null);
    _no = no;
  }

 private:
  Expression* _expression;
  Expression* _yes;
  Expression* _no;
};

class While : public Expression {
 public:
  While(Expression* condition, Expression* body)
      : _condition(condition)
      , _body(body) { }
  IMPLEMENTS(While)

  Expression* condition() const { return _condition; }
  Expression* body() const { return _body; }

 private:
  Expression* _condition;
  Expression* _body;
};

class For : public Expression {
 public:
  For(Expression* initializer, Expression* condition, Expression* update, Expression* body)
      : _initializer(initializer)
      , _condition(condition)
      , _body(body)
      , _update(update) { }
  IMPLEMENTS(For)

  Expression* initializer() const { return _initializer; }
  Expression* condition() const { return _condition; }
  Expression* update() const { return _update; }
  Expression* body() const { return _body; }

 private:
  Expression* _initializer;
  Expression* _condition;
  Expression* _body;
  Expression* _update;

};

class TryFinally : public Expression {
 public:
  TryFinally(Sequence* body, List<Parameter*> handler_parameters, Sequence* handler)
      : _body(body)
      , _handler_parameters(handler_parameters)
      , _handler(handler) { }
  IMPLEMENTS(TryFinally)

  Sequence* body() const { return _body; }
  List<Parameter*> handler_parameters() const { return _handler_parameters; }
  Sequence* handler() const { return _handler; }

 private:
  Sequence* _body;
  List<Parameter*> _handler_parameters;
  Sequence* _handler;
};

class Return : public Expression {
 public:
  Return(Expression* value) : _value(value) { }
  IMPLEMENTS(Return)

  Expression* value() const { return _value; }

 private:
  Expression* _value;
};

class Unary : public Expression {
 public:
  Unary(Token::Kind kind, bool prefix, Expression* expression)
      : _kind(kind)
      , _prefix(prefix)
      , _expression(expression) { }
  IMPLEMENTS(Unary)

  Token::Kind kind() const { return _kind; }
  bool prefix() const { return _prefix; }
  Expression* expression() const { return _expression; }

 private:
  Token::Kind _kind;
  bool _prefix;
  Expression* _expression;
};

class Binary : public Expression {
 public:
  Binary(Token::Kind kind, Expression* left, Expression* right)
      : _kind(kind)
      , _left(left)
      , _right(right) { }
  IMPLEMENTS(Binary)

  Token::Kind kind() const { return _kind; }
  Expression* left() const { return _left; }
  Expression* right() const { return _right; }

 private:
  Token::Kind _kind;
  Expression* _left;
  Expression* _right;
};

class Dot : public Expression {
 public:
  Dot(Expression* receiver, Identifier* name)
     : _receiver(receiver)
     , _name(name) { }
  IMPLEMENTS(Dot)

  Expression* receiver() const { return _receiver; }
  Identifier* name() const { return _name; }

 private:
  Expression* _receiver;
  Identifier* _name;
};

class Index : public Expression {
 public:
  Index(Expression* receiver, List<Expression*> arguments)
      : _receiver(receiver)
      , _arguments(arguments) { }
  IMPLEMENTS(Index)

  Expression* receiver() const { return _receiver; }
  List<Expression*> arguments() const { return _arguments; }

 private:
  Expression* _receiver;
  List<Expression*> _arguments;
};

class IndexSlice : public Expression {
 public:
  IndexSlice(Expression* receiver, Expression* from, Expression* to)
      : _receiver(receiver)
      , _from(from)
      , _to(to) { }
  IMPLEMENTS(IndexSlice)

  Expression* receiver() const { return _receiver; }
  // May be null if none was given.
  Expression* from() const { return _from; }
  // May be null if none was given.
  Expression* to() const { return _to; }

 private:
  Expression* _receiver;
  Expression* _from;
  Expression* _to;
};

class Call : public Expression {
 public:
  Call(Expression* target, List<Expression*> arguments, bool is_call_primitive)
      : _target(target)
      , _arguments(arguments)
      , _is_call_primitive(is_call_primitive) { }
  IMPLEMENTS(Call)

  Expression* target() const { return _target; }
  List<Expression*> arguments() const { return _arguments; }
  bool is_call_primitive() const { return _is_call_primitive; }

 private:
  Expression* _target;
  List<Expression*> _arguments;
  bool _is_call_primitive;
};

class Parameter : public Expression {
 public:
  Parameter(Identifier* name,
            Expression* type,
            Expression* default_value,
            bool is_named,
            bool is_field_storing,
            bool is_block)
      : _name(name)
      , _type(type)
      , _default_value(default_value)
      , _is_named(is_named)
      , _is_field_storing(is_field_storing)
      , _is_block(is_block) { }
  IMPLEMENTS(Parameter)

  Identifier* name() const { return _name; }
  Expression* default_value() const { return _default_value; }
  Expression* type() const { return _type; }
  bool is_named() const { return _is_named; }
  bool is_field_storing() const { return _is_field_storing; }
  bool is_block() const { return _is_block; }

 private:
   Identifier* _name;
   Expression* _type;
   Expression* _default_value;
   bool _is_named;
   bool _is_field_storing;
   bool _is_block;
};

class LiteralNull : public Expression {
 public:
  LiteralNull() { }
  IMPLEMENTS(LiteralNull)
};

class LiteralUndefined : public Expression {
 public:
  LiteralUndefined() { }
  IMPLEMENTS(LiteralUndefined)
};

class LiteralBoolean : public Expression {
 public:
  explicit LiteralBoolean(bool value) : _value(value) { }
  IMPLEMENTS(LiteralBoolean)

  bool value() const { return _value; }

 private:
  bool _value;
};

class LiteralInteger : public Expression {
 public:
  explicit LiteralInteger(Symbol data) : _data(data) { }
  IMPLEMENTS(LiteralInteger)

  Symbol data() const { return _data; }
  bool is_negated() const { return _is_negated; }
  void set_is_negated(bool value) { _is_negated = value; }

 private:
  const Symbol _data;
  bool _is_negated = false;
};

class LiteralCharacter : public Expression {
 public:
  explicit LiteralCharacter(Symbol data) : _data(data) { }
  IMPLEMENTS(LiteralCharacter)

  Symbol data() const { return _data; }

 private:
  const Symbol _data;
};

class LiteralString : public Expression {
 public:
  explicit LiteralString(Symbol data, bool is_multiline)
      : _data(data)
      , _is_multiline(is_multiline) { }
  IMPLEMENTS(LiteralString)

  Symbol data() const { return _data; }
  bool is_multiline() const { return _is_multiline; }

 private:
  const Symbol _data;
  const bool _is_multiline;
};

class LiteralStringInterpolation : public Expression {
 public:
  LiteralStringInterpolation(
    List<LiteralString*> parts, List<LiteralString*> formats, List<Expression*> expressions)
      : _parts(parts)
      , _formats(formats)
      , _expressions(expressions) { }
  IMPLEMENTS(LiteralStringInterpolation)

  List<LiteralString*> parts() const { return _parts; }
  List<LiteralString*> formats() const { return _formats; }
  List<Expression*> expressions() const { return _expressions; }

 private:
  List<LiteralString*> _parts;
  List<LiteralString*> _formats;
  List<Expression*> _expressions;
};

class LiteralFloat : public Expression {
 public:
  explicit LiteralFloat(Symbol data) : _data(data) { }
  IMPLEMENTS(LiteralFloat)

  Symbol data() const { return _data; }
  bool is_negated() const { return _is_negated; }
  void set_is_negated(bool value) { _is_negated = value; }

 private:
  const Symbol _data;
  bool _is_negated = false;
};

class LiteralArray : public Expression {
 public:
  explicit LiteralArray(List<Expression*> elements) : _elements(elements) { }
  IMPLEMENTS(LiteralArray)

  List<Expression*> elements() const { return _elements; }

 private:
  List<Expression*> _elements;
};

class LiteralList : public Expression {
 public:
  explicit LiteralList(List<Expression*> elements) : _elements(elements) { }
  IMPLEMENTS(LiteralList)

  List<Expression*> elements() const { return _elements; }

 private:
  List<Expression*> _elements;
};

class LiteralByteArray : public Expression {
 public:
  explicit LiteralByteArray(List<Expression*> elements) : _elements(elements) { }
  IMPLEMENTS(LiteralByteArray)

  List<Expression*> elements() const { return _elements; }

 private:
  List<Expression*> _elements;
};

class LiteralSet : public Expression {
  public:
  explicit LiteralSet(List<Expression*> elements) : _elements(elements) { }
  IMPLEMENTS(LiteralSet)

  List<Expression*> elements() const { return _elements; }

 private:
  List<Expression*> _elements;
};

class LiteralMap : public Expression {
 public:
  LiteralMap(List<Expression*> keys, List<Expression*> values)
      : _keys(keys)
      , _values(values) { }
  IMPLEMENTS(LiteralMap)

  List<Expression*> keys() const { return _keys; }
  List<Expression*> values() const { return _values; }

 private:
  List<Expression*> _keys;
  List<Expression*> _values;
};

class ToitdocReference : public Node {
 public:
  ToitdocReference(Expression* target, bool is_setter)
      : _is_signature_reference(false)
      , _target(target)
      , _is_setter(is_setter) { }

  ToitdocReference(Expression* target, bool target_is_setter, List<Parameter*> parameters)
      : _is_signature_reference(true)
      , _target(target)
      , _is_setter(target_is_setter)
      , _parameters(parameters) { }
  IMPLEMENTS(ToitdocReference);

  bool is_error() const {
    return _target->is_Error();
  }

  /// Whether this reference was parenthesized, and thus the whole signature should match.
  bool is_signature_reference() const {
    return _is_signature_reference;
  }

  /// Returns the target of the reference.
  /// This can be:
  /// - an Identifier (potentially an operator, like '+')
  /// - a Dot
  /// - an `Error` instance if the parsing failed.
  Expression* target() const { return _target; }

  /// Whether the target is a setter (where the identifier was suffixed by a '=').
  bool is_setter() const { return _is_setter; }

  List<Parameter*> parameters() const { return _parameters; }

 private:
  bool _is_signature_reference;
  Expression* _target;
  bool _is_setter;
  List<Parameter*> _parameters;
};

#undef IMPLEMENTS

} // namespace toit::compiler::ast
} // namespace toit::compiler
} // namespace toit
