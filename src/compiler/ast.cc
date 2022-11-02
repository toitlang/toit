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

#include "ast.h"
#include "../utils.h"

namespace toit {
namespace compiler {
namespace ast {

void Visitor::visit(Node* node) {
  node->accept(this);
}

#define DECLARE(name)                                           \
void Visitor::visit_##name(name* node) {                        \
}
NODES(DECLARE)
#undef DECLARE

void TraversingVisitor::visit_Unit(Unit* node) {
  for (int i = 0; i < node->declarations().length(); i++) {
    node->declarations()[i]->accept(this);
  }
}

void TraversingVisitor::visit_Import(Import* node) {
}

void TraversingVisitor::visit_Export(Export* node) {
}

void TraversingVisitor::visit_Class(Class* node) {
  node->name()->accept(this);
  if (node->has_super()) node->super()->accept(this);
  for (int i = 0; i < node->members().length(); i++) {
    node->members()[i]->accept(this);
  }
}

void TraversingVisitor::visit_Declaration(Declaration* node) {
  node->name_or_dot()->accept(this);
}

void TraversingVisitor::visit_Field(Field* node) {
  visit_Declaration(node);
  if (node->initializer() != null) node->initializer()->accept(this);
}

void TraversingVisitor::visit_Method(Method* node) {
  visit_Declaration(node);
  if (node->return_type() != null) node->return_type()->accept(this);
  for (int i = 0; i < node->parameters().length(); i++) {
    node->parameters()[i]->accept(this);
  }
  if (node->body() != null) {
    node->body()->accept(this);
  }
}

void TraversingVisitor::visit_Expression(Expression* node) {
}

void TraversingVisitor::visit_Error(Error* node) {
}

void TraversingVisitor::visit_NamedArgument(NamedArgument* node) {
  node->name()->accept(this);
  if (node->expression() != null) node->expression()->accept(this);
}

void TraversingVisitor::visit_BreakContinue(BreakContinue* node) {
  if (node->label() != null) {
    node->label()->accept(this);
  }
  if (node->value() != null) {
    node->value()->accept(this);
  }
}

void TraversingVisitor::visit_Parenthesis(Parenthesis* node) {
  node->expression()->accept(this);
}

void TraversingVisitor::visit_Block(Block* node) {
  for (int i = 0; i < node->parameters().length(); i++) {
    node->parameters()[i]->accept(this);
  }
  visit(node->body());
}

void TraversingVisitor::visit_Lambda(Lambda* node) {
  for (int i = 0; i < node->parameters().length(); i++) {
    node->parameters()[i]->accept(this);
  }
  visit(node->body());
}

void TraversingVisitor::visit_Sequence(Sequence* node) {
  for (int i = 0; i < node->expressions().length(); i++) {
    node->expressions()[i]->accept(this);
  }
}

void TraversingVisitor::visit_DeclarationLocal(DeclarationLocal* node) {
  visit(node->name());
  visit(node->value());
}

void TraversingVisitor::visit_If(If* node) {
  node->expression()->accept(this);
  node->yes()->accept(this);
  if (node->no() != null) node->no()->accept(this);
}

void TraversingVisitor::visit_While(While* node) {
  node->condition()->accept(this);
  node->body()->accept(this);
}

void TraversingVisitor::visit_For(For* node) {
  if (node->initializer() != null) node->initializer()->accept(this);
  if (node->condition() != null) node->condition()->accept(this);
  if (node->update() != null) node->update()->accept(this);
  node->body()->accept(this);
}

void TraversingVisitor::visit_TryFinally(TryFinally* node) {
  node->body()->accept(this);
  node->handler()->accept(this);
  for (auto parameter : node->handler_parameters()) {
    parameter->accept(this);
  }
}

void TraversingVisitor::visit_Return(Return* node) {
  if (node->value() != null) {
    node->value()->accept(this);
  }
}

void TraversingVisitor::visit_Unary(Unary* node) {
  node->expression()->accept(this);
}

void TraversingVisitor::visit_Binary(Binary* node) {
  node->left()->accept(this);
  node->right()->accept(this);
}

void TraversingVisitor::visit_Call(Call* node) {
  node->target()->accept(this);
  for (int i = 0; i < node->arguments().length(); i++) {
    node->arguments()[i]->accept(this);
  }
}

void TraversingVisitor::visit_Dot(Dot* node) {
  node->receiver()->accept(this);
  node->name()->accept(this);
}

void TraversingVisitor::visit_Index(Index* node) {
  node->receiver()->accept(this);
  for (int i = 0; i < node->arguments().length(); i++) {
    node->arguments()[i]->accept(this);
  }
}

void TraversingVisitor::visit_IndexSlice(IndexSlice* node) {
  node->receiver()->accept(this);
  if (node->from() != null) node->from()->accept(this);
  if (node->to() != null) node->to()->accept(this);
}

void TraversingVisitor::visit_Identifier(Identifier* node) {
}

void TraversingVisitor::visit_Nullable(Nullable* node) {
  node->type()->accept(this);
}

void TraversingVisitor::visit_LspSelection(LspSelection* node) {
}

void TraversingVisitor::visit_Parameter(Parameter* node) {
  node->name()->accept(this);
  if (node->type() != null) node->type()->accept(this);
  if (node->default_value() != null) {
    node->default_value()->accept(this);
  }
}

void TraversingVisitor::visit_LiteralNull(LiteralNull* node) {
}

void TraversingVisitor::visit_LiteralUndefined(LiteralUndefined* node) {
}

void TraversingVisitor::visit_LiteralBoolean(LiteralBoolean* node) {
}

void TraversingVisitor::visit_LiteralInteger(LiteralInteger* node) {
}

void TraversingVisitor::visit_LiteralCharacter(LiteralCharacter* node) {
}

void TraversingVisitor::visit_LiteralString(LiteralString* node) {
}

void TraversingVisitor::visit_LiteralStringInterpolation(LiteralStringInterpolation* node) {
  for (int i = 0; i < node->parts().length(); i++) {
    if (i != 0) {
      node->expressions()[i - 1]->accept(this);
      if (node->formats()[i - 1] != null) {
        node->formats()[i - 1]->accept(this);
      }
    }
    node->parts()[i]->accept(this);
  }
}

void TraversingVisitor::visit_LiteralFloat(LiteralFloat* node) {
}

void TraversingVisitor::visit_LiteralArray(LiteralArray* node) {
  for (int i = 0; i < node->elements().length(); i++) {
    node->elements()[i]->accept(this);
  }
}

void TraversingVisitor::visit_LiteralList(LiteralList* node) {
  for (int i = 0; i < node->elements().length(); i++) {
    node->elements()[i]->accept(this);
  }
}

void TraversingVisitor::visit_LiteralByteArray(LiteralByteArray* node) {
  for (int i = 0; i < node->elements().length(); i++) {
    node->elements()[i]->accept(this);
  }
}

void TraversingVisitor::visit_LiteralSet(LiteralSet* node) {
  for (int i = 0; i < node->elements().length(); i++) {
    node->elements()[i]->accept(this);
  }
}

void TraversingVisitor::visit_LiteralMap(LiteralMap* node) {
  for (int i = 0; i < node->keys().length(); i++) {
    node->keys()[i]->accept(this);
    node->values()[i]->accept(this);
  }
}

void TraversingVisitor::visit_ToitdocReference(ToitdocReference* node) {
  node->target()->accept(this);
  for (auto parameter : node->parameters()) {
    parameter->accept(this);
  }
}

class AstPrinter : public Visitor {
 public:
  AstPrinter()
      : indentation_(0) { }

  void indent() {
    for (int i = 0; i < indentation_; i++) {
      printf("  ");
    }
  }

  void visit_Unit(Unit* node) {
    for (int i = 0; i < node->imports().length(); i++) {
      node->imports()[i]->accept(this);
    }
    for (int i = 0; i < node->declarations().length(); i++) {
      if (i == 0) printf("\n");
      node->declarations()[i]->accept(this);
    }
  }

  void visit_Import(Import* node) {
    printf("import ");
    bool is_first = true;
    for (auto segment : node->segments()) {
      if (is_first) {
        is_first = false;
      } else {
        printf(".");
      }
      visit(segment);
    }
    printf("\n");
  }

  void visit_Export(Export* node) { UNREACHABLE(); }

  void visit_Class(Class* node) {
    printf("class ");
    node->name()->accept(this);
    if (node->has_super()) {
      printf(" ");
      node->super()->accept(this);
    }
    printf(":\n");
    indentation_++;
    for (int i = 0; i < node->members().length(); i++) {
      indent();
      node->members()[i]->accept(this);
    }
    indentation_--;
  }

  void visit_Field(Field* node) {
    if (node->is_static()) printf("static ");
    node->name()->accept(this);
    printf(" := ");
    if (node->initializer() == null) {
      printf("?");
    } else {
      node->initializer()->accept(this);
    }
    printf("\n");
  }

  void visit_Method(Method* node) {
    if (node->is_static()) printf("static ");
    node->name_or_dot()->accept(this);
    if (!node->parameters().is_empty()) {
      for (int i = 0; i < node->parameters().length(); i++) {
        printf(" ");
        node->parameters()[i]->accept(this);
      }
    }
    if (node->body() != null) {
      node->body()->accept(this);
    }
    printf("\n");
  }

  void visit_Error(Error* node) {
    printf("<ERROR>");
  }

  void visit_Unary(Unary* node) {
    printf("(");
    printf("%s", Token::symbol(node->kind()).c_str());
    node->expression()->accept(this);
    printf(")");
  }

  void visit_Binary(Binary* node) {
    printf("(");
    node->left()->accept(this);
    printf(" %s ", Token::symbol(node->kind()).c_str());
    node->right()->accept(this);
    printf(")");
  }

  void visit_Dot(Dot* node) {
    node->receiver()->accept(this);
    printf(".");
    node->name()->accept(this);
  }

  void visit_Index(Index* node) {
    node->receiver()->accept(this);
    printf("[");
    for (int i = 0; i < node->arguments().length(); i++) {
      if (i != 0) printf(", ");
      node->arguments()[i]->accept(this);
    }
    printf("]");
  }

  void visit_IndexSlice(IndexSlice* node) {
    node->receiver()->accept(this);
    printf("[");
    if (node->from() != null) node->from()->accept(this);
    printf("..");
    if (node->to() != null) node->to()->accept(this);
    printf("]");
  }

  void visit_Call(Call* node) {
    node->target()->accept(this);
    for (int i = 0; i < node->arguments().length(); i++) {
      printf(" ");
      node->arguments()[i]->accept(this);
    }
  }

  void visit_If(If* node) {
    printf("if ");
    node->expression()->accept(this);
    printf(":");
    node->yes()->accept(this);
    if (node->no() != null) {
      indent();
      printf("else:");
      node->no()->accept(this);
    }
  }

  void visit_While(While* node) {
    printf("while ");
    node->condition()->accept(this);
    printf(":");
    node->body()->accept(this);
  }

  void visit_For(For* node) {
    printf("for ");
    if (node->initializer() != null) node->initializer()->accept(this);
    printf("; ");
    if (node->condition() != null) node->condition()->accept(this);
    printf("; ");
    if (node->update() != null) node->update()->accept(this);
    printf(":");
    node->body()->accept(this);
  }

  void visit_TryFinally(TryFinally* node) {
    printf("try:");
    node->body()->accept(this);
    printf("finally:");
    if (!node->handler_parameters().is_empty()) {
      printf("|");
      for (auto parameter : node->handler_parameters()) {
        visit(parameter);
      }
      printf(" | ");
    }
    node->handler()->accept(this);
  }

  void visit_Return(Return* node) {
    if (node->value() == null) {
      printf("return");
    } else {
      printf("return ");
      node->value()->accept(this);
    }
  }

  void visit_Block(Block* node) {
    printf(": ");
    if (!node->parameters().is_empty()) {
      printf("|");
      for (auto parameter : node->parameters()) {
        visit(parameter);
      }
      printf(" | ");
    }
    visit_Sequence(node->body());
  }

  void visit_Lambda(Lambda* node) {
    printf(":: ");
    if (!node->parameters().is_empty()) {
      printf("|");
      for (auto parameter : node->parameters()) {
        visit(parameter);
      }
      printf(" | ");
    }
    visit_Sequence(node->body());
  }

  void visit_Sequence(Sequence* node) {
    printf("\n");
    indentation_++;
    for (int i = 0; i < node->expressions().length(); i++) {
      Expression* expression = node->expressions()[i];
      indent();
      expression->accept(this);
      printf("\n");
    }
    indentation_--;
  }

  void visit_Identifier(Identifier* node) {
    printf("%s", node->data().c_str());
  }

  void visit_Nullable(Nullable* node) {
    visit(node->type());
    printf("?");
  }

  void visit_LspSelection(LspSelection* node) {
    printf("<target> %s", node->data().c_str());
  }

  void visit_BreakContinue(BreakContinue* node) {
    const char* kind = node->is_break() ? "break" : "continue";
    if (node->label() != null) {
      if (node->value() == null) {
        printf("%s.%s", kind, node->label()->data().c_str());
      } else {
        printf("%s.%s ", kind, node->label()->data().c_str());
        node->value()->accept(this);
      }
    } else {
      if (node->value() == null) {
        printf("%s", kind);
      } else {
        printf("%s ", kind);
        node->value()->accept(this);
      }
    }
  }

  void visit_Parenthesis(Parenthesis* node) {
    printf("(");
    node->expression()->accept(this);
    printf(")");
  }

  void visit_Parameter(Parameter* node) {
    printf("<parameter:");
    if (node->is_field_storing()) printf("this.");
    if (node->default_value() != null) {
      printf("=(");
      visit(node->default_value());
      printf(")");
    }
    visit(node->name());
  }

  void visit_LiteralNull(LiteralNull* node) {
    printf("null");
  }

  void visit_LiteralUndefined(LiteralUndefined* node) {
    printf("?");
  }

  void visit_LiteralBoolean(LiteralBoolean* node) {
    printf("%s", node->value() ? "true" : "false");
  }

  void visit_LiteralInteger(LiteralInteger* node) {
    printf("%s", node->data().c_str());
  }

  void visit_LiteralCharacter(LiteralCharacter* node) {
    printf("'%s'", node->data().c_str());
  }

  void visit_LiteralString(LiteralString* node) {
    printf("\"%s\"", node->data().c_str());
  }

  void visit_LiteralStringInterpolation(LiteralStringInterpolation* node) {
    printf("\"");
    for (int i = 0; i < node->parts().length(); i++) {
      if (i != 0) {
        printf("$(");
        node->expressions()[i - 1]->accept(this);
        printf(")");
      }
      printf("%s", node->parts()[i]->data().c_str());
    }
    printf("\"");
  }

  void visit_LiteralFloat(LiteralFloat* node) {
    printf("%s", node->data().c_str());
  }

  void visit_LiteralArray(LiteralArray* node) {
    printf("<array>[");
    for (int i = 0; i < node->elements().length(); i++) {
      if (i != 0) printf(", ");
      node->elements()[i]->accept(this);
    }
    printf("]");
  }

  void visit_LiteralList(LiteralList* node) {
    printf("[");
    for (int i = 0; i < node->elements().length(); i++) {
      if (i != 0) printf(", ");
      node->elements()[i]->accept(this);
    }
    printf("]");
  }

  void visit_LiteralSet(LiteralSet* node) {
    printf("{");
    for (int i = 0; i < node->elements().length(); i++) {
      if (i != 0) printf(", ");
      node->elements()[i]->accept(this);
    }
    printf("}");
  }

  void visit_LiteralMap(LiteralMap* node) {
    if (node->keys().is_empty()) {
      printf("{:}");
    } else {
      printf("{");
      for (int i = 0; i < node->keys().length(); i++) {
        if (i != 0) printf(", ");
        node->keys()[i]->accept(this);
        printf(": ");
        node->values()[i]->accept(this);
      }
      printf("}");
    }
  }

  void visit_ToitdocReference(ToitdocReference* node) {
    printf("$");
    if (node->is_signature_reference()) printf("(");
    node->target()->accept(this);
    if (node->is_setter()) printf("=");
    for (auto parameter : node->parameters()) {
      printf(" ");
      parameter->accept(this);
    }
    if (node->is_signature_reference()) printf(")");
  }

 private:
  int indentation_;
};

void Node::print() {
  AstPrinter printer;
  this->accept(&printer);
}

} // namespace toit::compiler::ast
} // namespace toit::compiler
} // namespace toit
