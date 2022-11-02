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
  Node() : range_(Source::Range::invalid()) { }
  virtual void accept(Visitor* visitor) = 0;

  Source::Range range() const { return range_; }
  void set_range(Source::Range value) { range_ = value; }

  void print();

#define DECLARE(name)                              \
  virtual bool is_##name() const { return false; } \
  virtual name* as_##name() { return null; }
NODES(DECLARE)
#undef DECLARE

  virtual const char* node_type() const { return "Node"; }

 private:
  Source::Range range_;
};

#define IMPLEMENTS(name)                                                 \
  virtual void accept(Visitor* visitor) { visitor->visit_##name(this); } \
  virtual bool is_##name() const { return true; }                        \
  virtual name* as_##name() { return this; }                             \
  virtual const char* node_type() const { return #name; }

class Unit : public Node {
 public:
  Unit(Source* source, List<Import*> imports, List<Export*> exports, List<Node*> declarations)
      : is_error_unit_(false)
      , source_(source)
      , imports_(imports)
      , exports_(exports)
      , declarations_(declarations) { }
  explicit Unit(bool is_error_unit)
      : is_error_unit_(is_error_unit)
      , source_(null)
      , imports_(List<Import*>())
      , exports_(List<Export*>())
      , declarations_(List<Node*>()) {
    ASSERT(is_error_unit);
  }

  IMPLEMENTS(Unit)

  const char* absolute_path() const {
    return source_ == null ? "" : source_->absolute_path();
  }
  std::string error_path() const {
    return source_ == null ? std::string("") : source_->error_path();
  }
  Source* source() const { return source_; }
  List<Import*> imports() const { return imports_; }
  List<Export*> exports() const { return exports_; }
  List<Node*> declarations() const { return declarations_; }
  void set_declarations(List<Node*> new_declarations) {
    declarations_ = new_declarations;
  }

  bool is_error_unit() const { return is_error_unit_; }

  Toitdoc<ast::Node*> toitdoc() const { return toitdoc_; }
  void set_toitdoc(Toitdoc<ast::Node*> toitdoc) {
    toitdoc_ = toitdoc;
  }

 private:
  bool is_error_unit_;
  Source* source_;
  List<Import*> imports_;
  List<Export*> exports_;
  List<Node*> declarations_;
  Toitdoc<ast::Node*> toitdoc_ = Toitdoc<ast::Node*>::invalid();
};

class Import : public Node {
 public:
  Import(bool is_relative,
         int dot_outs,
         List<Identifier*> segments,
         Identifier* prefix,
         List<Identifier*> show_identifiers,
         bool show_all)
      : is_relative_(is_relative)
      , dot_outs_(dot_outs)
      , segments_(segments)
      , prefix_(prefix)
      , show_identifiers_(show_identifiers)
      , show_all_(show_all)
      , unit_(null) {
    // Can't have a prefix with show.
    ASSERT(prefix == null || show_identifiers.is_empty());
    // Can't have a prefix with show-all.
    ASSERT(prefix == null || !show_all)
    // Can't have show-all and identifiers.
    ASSERT(show_identifiers.is_empty() || !show_all);
  }
  IMPLEMENTS(Import)

  bool is_relative() const { return is_relative_; }

  /// The number of dot-outs.
  ///
  /// For example: `import ...foo` has 2 dot-outs. The first dot is only a
  ///   signal that the import is relative.
  int dot_outs() const { return dot_outs_; }

  List<Identifier*> segments() const { return segments_; }

  /// Returns null if there wasn't any prefix.
  Identifier* prefix() const { return prefix_; }

  List<Identifier*> show_identifiers() const { return show_identifiers_; }

  bool show_all() const { return show_all_; }

  Unit* unit() const { return unit_; }
  void set_unit(Unit* unit) { unit_ = unit; }

 private:
  bool is_relative_;
  int dot_outs_;
  List<Identifier*> segments_;
  Identifier* prefix_;
  List<Identifier*> show_identifiers_;
  bool show_all_;
  Unit* unit_;
};

class Export : public Node {
 public:
  explicit Export(List<Identifier*> identifiers) : identifiers_(identifiers), export_all_(false) { }
  explicit Export(bool export_all) : export_all_(export_all) { }
  IMPLEMENTS(Export)

  List<Identifier*> identifiers() const { return identifiers_; }
  bool export_all() const { return export_all_; }

 private:
  List<Identifier*> identifiers_;
  bool export_all_;
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
      : name_(name)
      , super_(super)
      , interfaces_(interfaces)
      , members_(members)
      , is_abstract_(is_abstract)
      , is_monitor_(is_monitor)
      , is_interface_(is_interface) { }
  IMPLEMENTS(Class)

  bool has_super() const { return super_ != null; }

  Identifier* name() const { return name_; }
  Expression* super() const { return super_; }
  List<Expression*> interfaces() const { return interfaces_; }
  List<Declaration*> members() const { return members_; }

  bool is_abstract() const { return is_abstract_; }
  bool is_monitor() const { return is_monitor_; }
  bool is_interface() const { return is_interface_; }

  void set_toitdoc(Toitdoc<ast::Node*> toitdoc) {
    toitdoc_ = toitdoc;
  }
  Toitdoc<ast::Node*> toitdoc() const { return toitdoc_; }

 private:
  Identifier* name_;
  Expression* super_;
  List<Expression*> interfaces_;
  List<Declaration*> members_;
  bool is_abstract_;
  bool is_monitor_;
  bool is_interface_;
  Toitdoc<ast::Node*> toitdoc_ = Toitdoc<ast::Node*>::invalid();
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
      : name_(name)
      , inverted_(inverted)
      , expression_(expression) { }
  IMPLEMENTS(NamedArgument)

  Identifier* name() const { return name_; }
  // Expression may be null, if there wasn't any `=`.
  Expression* expression() const { return expression_; }

  // Whether the named argument was prefixed with a `no-`.
  bool inverted() const { return inverted_; }

 private:
  Identifier* name_;
  bool inverted_;
  Expression* expression_;
};

class Declaration : public Node {
 public:
  explicit Declaration(Expression* name_or_dot)  // name must be an Identifier or a Dot.
      : name_or_dot_(name_or_dot) { }
  IMPLEMENTS(Declaration)

  virtual Identifier* name() const {
    ASSERT(name_or_dot_->is_Identifier());
    return name_or_dot_->as_Identifier();
  }

  Expression* name_or_dot() const { return name_or_dot_; }

  void set_toitdoc(Toitdoc<ast::Node*> toitdoc) {
    toitdoc_ = toitdoc;
  }

  Toitdoc<ast::Node*> toitdoc() const { return toitdoc_; }

private:
  Expression* name_or_dot_;
  Toitdoc<ast::Node*> toitdoc_ = Toitdoc<ast::Node*>::invalid();
};

class Identifier : public Expression {
 public:
  explicit Identifier(Symbol data) : data_(data) { }
  IMPLEMENTS(Identifier)

  Symbol data() const { return data_; }

 private:
   const Symbol data_;
};

class Nullable : public Expression {
 public:
  explicit Nullable(Expression* type) : type_(type) { }
  IMPLEMENTS(Nullable)

  Expression* type() const { return type_; }

 private:
  Expression* type_;
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
      , type_(type)
      , initializer_(initializer)
      , is_static_(is_static)
      , is_abstract_(is_abstract)
      , is_final_(is_final) { }
  IMPLEMENTS(Field)

  Expression* type() const { return type_; }
  Expression* initializer() const { return initializer_; }
  bool is_static() const { return is_static_; }
  bool is_abstract() const { return is_abstract_; }
  bool is_final() const { return is_final_; }

 private:
  Expression* type_;
  Expression* initializer_;
  bool is_static_;
  bool is_abstract_;
  bool is_final_;
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
      , return_type_(return_type)
      , is_setter_(is_setter)
      , is_static_(is_static)
      , is_abstract_(is_abstract)
      , parameters_(parameters)
      , body_(body) { }
  IMPLEMENTS(Method)

  Expression* return_type() const { return return_type_; }
  bool is_setter() const { return is_setter_; }
  bool is_static() const { return is_static_; }
  bool is_abstract() const { return is_abstract_; }

  List<Parameter*> parameters() const { return parameters_; }

  /// Might be null if there was no body.
  Sequence* body() const { return body_; }

  /// The arity of the function, including block parameters, but not
  /// including implicit `this` arguments.
  int arity() const { return parameters_.length(); }

  Identifier* name() const {
    FATAL("don't use");
    return null;
  }

  Identifier* safe_name() const {
    ASSERT(name_or_dot()->is_Identifier());
    return name_or_dot()->as_Identifier();
  }

 private:
  Expression* return_type_;
  bool is_setter_;
  bool is_static_;
  bool is_abstract_;
  List<Parameter*> parameters_;

  Sequence* body_;

  List<Expression*> initializers_;
};

class BreakContinue : public Expression {
 public:
  BreakContinue(bool is_break) : BreakContinue(is_break, null, null) { }
  BreakContinue(bool is_break, Expression* value, Identifier* label)
      : is_break_(is_break)
      , value_(value)
      , label_(label) { }
  IMPLEMENTS(BreakContinue)

  bool is_break() const { return is_break_; }
  Expression* value() const { return value_; }
  Identifier* label() const { return label_; }

 private:
  bool is_break_;
  Expression* value_;
  Identifier* label_;
};

class Parenthesis : public Expression {
 public:
  explicit Parenthesis(Expression* expression) : expression_(expression) { }
  IMPLEMENTS(Parenthesis)

  Expression* expression() const { return expression_; }

 private:
  Expression* expression_;
};

class Block : public Expression {
 public:
  Block(Sequence* body, List<Parameter*> parameters)
      : body_(body)
      , parameters_(parameters) { }
  IMPLEMENTS(Block)

  Sequence* body() const { return body_; }

  List<Parameter*> parameters() const { return parameters_; }

 private:
  Sequence* body_;
  List<Parameter*> parameters_;
};

class Lambda : public Expression {
 public:
  Lambda(Sequence* body, List<Parameter*> parameters)
      : body_(body)
      , parameters_(parameters) { }
  IMPLEMENTS(Lambda)

  Sequence* body() const { return body_; }

  List<Parameter*> parameters() const { return parameters_; }

 private:
  Sequence* body_;
  List<Parameter*> parameters_;
};

class Sequence : public Expression {
 public:
  explicit Sequence(List<Expression*> expressions)
      : expressions_(expressions) { }
  IMPLEMENTS(Sequence)

  List<Expression*> expressions() const { return expressions_; }

 private:
  List<Expression*> expressions_;
};

class DeclarationLocal : public Expression {
 public:
  DeclarationLocal(Token::Kind kind, Identifier* name, Expression* type, Expression* value)
      : kind_(kind)
      , name_(name)
      , type_(type)
      , value_(value) { }
  IMPLEMENTS(DeclarationLocal)

  Token::Kind kind() const { return kind_; }
  Identifier* name() const { return name_; }
  Expression* type() const { return type_; }
  Expression* value() const { return value_; }

 private:
  Token::Kind kind_;
  Identifier* name_;
  Expression* type_;
  Expression* value_;
};

class If : public Expression {
 public:
  If(Expression* expression, Expression* yes, Expression* no)
      : expression_(expression)
      , yes_(yes)
      , no_(no) { }
  IMPLEMENTS(If)

  Expression* expression() const { return expression_; }
  Expression* yes() const { return yes_; }
  Expression* no() const { return no_; }

  void set_no(Expression* no) {
    ASSERT(no_ == null);
    no_ = no;
  }

 private:
  Expression* expression_;
  Expression* yes_;
  Expression* no_;
};

class While : public Expression {
 public:
  While(Expression* condition, Expression* body)
      : condition_(condition)
      , body_(body) { }
  IMPLEMENTS(While)

  Expression* condition() const { return condition_; }
  Expression* body() const { return body_; }

 private:
  Expression* condition_;
  Expression* body_;
};

class For : public Expression {
 public:
  For(Expression* initializer, Expression* condition, Expression* update, Expression* body)
      : initializer_(initializer)
      , condition_(condition)
      , body_(body)
      , update_(update) { }
  IMPLEMENTS(For)

  Expression* initializer() const { return initializer_; }
  Expression* condition() const { return condition_; }
  Expression* update() const { return update_; }
  Expression* body() const { return body_; }

 private:
  Expression* initializer_;
  Expression* condition_;
  Expression* body_;
  Expression* update_;

};

class TryFinally : public Expression {
 public:
  TryFinally(Sequence* body, List<Parameter*> handler_parameters, Sequence* handler)
      : body_(body)
      , handler_parameters_(handler_parameters)
      , handler_(handler) { }
  IMPLEMENTS(TryFinally)

  Sequence* body() const { return body_; }
  List<Parameter*> handler_parameters() const { return handler_parameters_; }
  Sequence* handler() const { return handler_; }

 private:
  Sequence* body_;
  List<Parameter*> handler_parameters_;
  Sequence* handler_;
};

class Return : public Expression {
 public:
  Return(Expression* value) : value_(value) { }
  IMPLEMENTS(Return)

  Expression* value() const { return value_; }

 private:
  Expression* value_;
};

class Unary : public Expression {
 public:
  Unary(Token::Kind kind, bool prefix, Expression* expression)
      : kind_(kind)
      , prefix_(prefix)
      , expression_(expression) { }
  IMPLEMENTS(Unary)

  Token::Kind kind() const { return kind_; }
  bool prefix() const { return prefix_; }
  Expression* expression() const { return expression_; }

 private:
  Token::Kind kind_;
  bool prefix_;
  Expression* expression_;
};

class Binary : public Expression {
 public:
  Binary(Token::Kind kind, Expression* left, Expression* right)
      : kind_(kind)
      , left_(left)
      , right_(right) { }
  IMPLEMENTS(Binary)

  Token::Kind kind() const { return kind_; }
  Expression* left() const { return left_; }
  Expression* right() const { return right_; }

 private:
  Token::Kind kind_;
  Expression* left_;
  Expression* right_;
};

class Dot : public Expression {
 public:
  Dot(Expression* receiver, Identifier* name)
     : receiver_(receiver)
     , name_(name) { }
  IMPLEMENTS(Dot)

  Expression* receiver() const { return receiver_; }
  Identifier* name() const { return name_; }

 private:
  Expression* receiver_;
  Identifier* name_;
};

class Index : public Expression {
 public:
  Index(Expression* receiver, List<Expression*> arguments)
      : receiver_(receiver)
      , arguments_(arguments) { }
  IMPLEMENTS(Index)

  Expression* receiver() const { return receiver_; }
  List<Expression*> arguments() const { return arguments_; }

 private:
  Expression* receiver_;
  List<Expression*> arguments_;
};

class IndexSlice : public Expression {
 public:
  IndexSlice(Expression* receiver, Expression* from, Expression* to)
      : receiver_(receiver)
      , from_(from)
      , to_(to) { }
  IMPLEMENTS(IndexSlice)

  Expression* receiver() const { return receiver_; }
  // May be null if none was given.
  Expression* from() const { return from_; }
  // May be null if none was given.
  Expression* to() const { return to_; }

 private:
  Expression* receiver_;
  Expression* from_;
  Expression* to_;
};

class Call : public Expression {
 public:
  Call(Expression* target, List<Expression*> arguments, bool is_call_primitive)
      : target_(target)
      , arguments_(arguments)
      , is_call_primitive_(is_call_primitive) { }
  IMPLEMENTS(Call)

  Expression* target() const { return target_; }
  List<Expression*> arguments() const { return arguments_; }
  bool is_call_primitive() const { return is_call_primitive_; }

 private:
  Expression* target_;
  List<Expression*> arguments_;
  bool is_call_primitive_;
};

class Parameter : public Expression {
 public:
  Parameter(Identifier* name,
            Expression* type,
            Expression* default_value,
            bool is_named,
            bool is_field_storing,
            bool is_block)
      : name_(name)
      , type_(type)
      , default_value_(default_value)
      , is_named_(is_named)
      , is_field_storing_(is_field_storing)
      , is_block_(is_block) { }
  IMPLEMENTS(Parameter)

  Identifier* name() const { return name_; }
  Expression* default_value() const { return default_value_; }
  Expression* type() const { return type_; }
  bool is_named() const { return is_named_; }
  bool is_field_storing() const { return is_field_storing_; }
  bool is_block() const { return is_block_; }

 private:
   Identifier* name_;
   Expression* type_;
   Expression* default_value_;
   bool is_named_;
   bool is_field_storing_;
   bool is_block_;
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
  explicit LiteralBoolean(bool value) : value_(value) { }
  IMPLEMENTS(LiteralBoolean)

  bool value() const { return value_; }

 private:
  bool value_;
};

class LiteralInteger : public Expression {
 public:
  explicit LiteralInteger(Symbol data) : data_(data) { }
  IMPLEMENTS(LiteralInteger)

  Symbol data() const { return data_; }
  bool is_negated() const { return _is_negated; }
  void set_is_negated(bool value) { _is_negated = value; }

 private:
  const Symbol data_;
  bool _is_negated = false;
};

class LiteralCharacter : public Expression {
 public:
  explicit LiteralCharacter(Symbol data) : data_(data) { }
  IMPLEMENTS(LiteralCharacter)

  Symbol data() const { return data_; }

 private:
  const Symbol data_;
};

class LiteralString : public Expression {
 public:
  explicit LiteralString(Symbol data, bool is_multiline)
      : data_(data)
      , is_multiline_(is_multiline) { }
  IMPLEMENTS(LiteralString)

  Symbol data() const { return data_; }
  bool is_multiline() const { return is_multiline_; }

 private:
  const Symbol data_;
  const bool is_multiline_;
};

class LiteralStringInterpolation : public Expression {
 public:
  LiteralStringInterpolation(
    List<LiteralString*> parts, List<LiteralString*> formats, List<Expression*> expressions)
      : parts_(parts)
      , formats_(formats)
      , expressions_(expressions) { }
  IMPLEMENTS(LiteralStringInterpolation)

  List<LiteralString*> parts() const { return parts_; }
  List<LiteralString*> formats() const { return formats_; }
  List<Expression*> expressions() const { return expressions_; }

 private:
  List<LiteralString*> parts_;
  List<LiteralString*> formats_;
  List<Expression*> expressions_;
};

class LiteralFloat : public Expression {
 public:
  explicit LiteralFloat(Symbol data) : data_(data) { }
  IMPLEMENTS(LiteralFloat)

  Symbol data() const { return data_; }
  bool is_negated() const { return _is_negated; }
  void set_is_negated(bool value) { _is_negated = value; }

 private:
  const Symbol data_;
  bool _is_negated = false;
};

class LiteralArray : public Expression {
 public:
  explicit LiteralArray(List<Expression*> elements) : elements_(elements) { }
  IMPLEMENTS(LiteralArray)

  List<Expression*> elements() const { return elements_; }

 private:
  List<Expression*> elements_;
};

class LiteralList : public Expression {
 public:
  explicit LiteralList(List<Expression*> elements) : elements_(elements) { }
  IMPLEMENTS(LiteralList)

  List<Expression*> elements() const { return elements_; }

 private:
  List<Expression*> elements_;
};

class LiteralByteArray : public Expression {
 public:
  explicit LiteralByteArray(List<Expression*> elements) : elements_(elements) { }
  IMPLEMENTS(LiteralByteArray)

  List<Expression*> elements() const { return elements_; }

 private:
  List<Expression*> elements_;
};

class LiteralSet : public Expression {
  public:
  explicit LiteralSet(List<Expression*> elements) : elements_(elements) { }
  IMPLEMENTS(LiteralSet)

  List<Expression*> elements() const { return elements_; }

 private:
  List<Expression*> elements_;
};

class LiteralMap : public Expression {
 public:
  LiteralMap(List<Expression*> keys, List<Expression*> values)
      : keys_(keys)
      , values_(values) { }
  IMPLEMENTS(LiteralMap)

  List<Expression*> keys() const { return keys_; }
  List<Expression*> values() const { return values_; }

 private:
  List<Expression*> keys_;
  List<Expression*> values_;
};

class ToitdocReference : public Node {
 public:
  ToitdocReference(Expression* target, bool is_setter)
      : is_signature_reference_(false)
      , target_(target)
      , is_setter_(is_setter) { }

  ToitdocReference(Expression* target, bool target_is_setter, List<Parameter*> parameters)
      : is_signature_reference_(true)
      , target_(target)
      , is_setter_(target_is_setter)
      , parameters_(parameters) { }
  IMPLEMENTS(ToitdocReference);

  bool is_error() const {
    return target_->is_Error();
  }

  /// Whether this reference was parenthesized, and thus the whole signature should match.
  bool is_signature_reference() const {
    return is_signature_reference_;
  }

  /// Returns the target of the reference.
  /// This can be:
  /// - an Identifier (potentially an operator, like '+')
  /// - a Dot
  /// - an `Error` instance if the parsing failed.
  Expression* target() const { return target_; }

  /// Whether the target is a setter (where the identifier was suffixed by a '=').
  bool is_setter() const { return is_setter_; }

  List<Parameter*> parameters() const { return parameters_; }

 private:
  bool is_signature_reference_;
  Expression* target_;
  bool is_setter_;
  List<Parameter*> parameters_;
};

#undef IMPLEMENTS

} // namespace toit::compiler::ast
} // namespace toit::compiler
} // namespace toit
