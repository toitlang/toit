---
name: toit-conventions
description: Guidance on how to write Toit code. Use whenever editing Toit code.
applyTo: '**/*.toit'
---
# Toit conventions

## Comments
- Comments should start with a capital letter and end with a period.
- Also remember that Toitdocs for methods start with a 3rd person verb.
- Toitdocs use a variant of markdown, where subsequent lines of a paragraph are indented. They use `$` to refer to code elements including parameters.
  When writing Toitdocs for parameters, use them inside sentences that describe the parameter, and not as a list of parameters.
  For example:
  ```
  /**
  Does something.

  Returns something based on the $parameter.
  Another paragraph over
    multiple lines referencing a $parameter.
  */
  foo parameter -> none:
  ```
- End-of-line comments should be separated from the code by at least two spaces, and start with a capital letter.
  ```
  foo := 42  // This is an end-of-line comment.
  ```

## Naming
- Use `kebab-case` for variables and functions.
- Use `PascalCase` for classes.
- Use `KEBAB-CASE` for constants.

## Common types
Some of the common types in Toit include `int`, `float`, `bool`, `string`, `List`,
`Map`, `Set`, `Lambda`, `ByteArray`.

## Indentation
- Use 2 spaces for indentation.
- Use spaces, not tabs.
- Use 4 spaces for indentation of parameters.

## Literals
- `{:}` is an empty map; `{"foo": "bar"}` a map with an entry.
- `[]` is an empty list;  `[1, 2, 3]` is a list with three entries.
- `{}` is an empty set; `{1, 2, 3}` is a set with three entries.
- `#[]` is an empty byte array, `#[1, 2, 3]` is a byte array with three entries.

If a literal is not on one line, add a trailing comma and indent as follows:
```
foo := [
  "foo",
  "bar",
  "baz",
]
```

## Types
- Types are declared with a `/` suffix.
- Return types are declared with a `->` suffix, on the same line as the function name.
  Parameters may be declared on later lines, indented by 4 spaces.

```
  my-function -> int
      param1
      param2/string
      [block-param]:
    return in-body param1...
```
- Use `?` to indicate that a type can be `null`.
```
  my-variable_/string?
  foo my-parameter/int? -> int:
```

## Blocks
Blocks are lambdas that cannot be stored in a field or global. They are
a cheaper but more limited alternative to lambdas.
- Use `:` to start a block.
- Use [block] to indicate a parameter that is a block.
- To "return" from a block, use `continue.xyz` to continue to "xyz".
```
  list.map: |item/string|
    if item == "foo": continue.map 499
    42
```
- Calling `return` inside a block will return from the enclosing function, not the block. (non-local return).

## Loops
- Prefer `x.repeat: ...` over `for i := 0; i < x; i++: ...` for loops, if the
body of the loop doesn't break.
- Use `collection.do: ...` to iterate over a collection.
- Use `it` as implicit parameter in a block, if the block is short and no type is needed:
  ```
  collection.do: print it
  ```
  Use a block parameter otherwise:
  ```
  collection.do: |item/string|
    print item
  ```
- Use `continue.do` or `continue.repeat`, ... to start the next iteration of a loop in
  a block:
  ```
  collection.do: |item/string|
    if item == "foo": continue.do
    print item
  ```

## Named parameters
- Toit uses '--' to indicate named parameters at the call and declaration site.
- Use named parameters for parameters that are not self-explanatory, or when multiple parameters have the same type.
- At the call-site, avoid `=true` and `=false` for boolean named parameter. If `=xyz` is missing, it is assumed to be `=true`. Use `--no-xyz` to set it to `false`.
  ```
  my-function --some-flag
  my-function --no-some-flag
  ```

## Variable/Field declaration
- Use `=` for assignment.
- Use `:=` to introduce a mutable variable or field. Inside functions prefer mutable variables over immutable variables.
- Use `::=` to introduce an immutable variable or field.
- Use a `_` suffix to indicate that field or function is private.
  ```
  my-private-field_/string
  ```
- Introduce an immutable field by declaring it with its type, which must be initialized in the constructor.
  ```
  class MyClass:
    my-field_/string
  ```
- Use `.field` in constructors to initialize fields, if the parameter is just assigned to the field, and
  the parameter is not named. In that case the parameter does not need a type.
  ```
  class MyClass:
    my-field_/string
    my-field2_/int

    constructor .my-field_ .my-field2_:
  ```
- Use `:= ?` to indicate that a mutable field must be initialized in the constructor.
  ```
  class MyClass:
    my-field_/string := ?

    constructor .my-field_:
  ```
- Use `this.field_ = parameter` if the constructor uses a named parameter that doesn't match the field name, or if the parameter has a different name.
  ```
  class MyClass:
    my-field_/string
    my-field2_/int := ?

    constructor unnamed/int --some-name/string:
      this.my-field_ = some-name
      this.my-field2_ = unnamed
  ```
- Use `?` suffix on types to indicate that the variable/field can be `null`.
  ```
  class MyClass:
    my-field/string? := null
  ```

## Exceptions
- Use `throw` to throw an exception. Most of Toit uses strings as exceptions, but you can throw any value.
  ```
  throw "error"
  throw MyException "something went wrong"
  ```
- Consider exception objects for libraries where the caller needs to distinguish between different exceptions, and a string doesn't provide enough information.
- Use `catch` with a block to catch exceptions.
  ```
  e := catch: throw "error"
  if e != null:
    print "Caught error: " + e
  ```
- Use `try: ... finally: ...` to run finally code.
  ```
  try:
    throw "error"
  finally:
    print "This will always be printed."
  ```
- If code should be run only if an exception was thrown prefer to set a flag in the catch block and check it in the finally block:
  ```
  succeeded := false
  try:
    some-dangerous-operation
    succeeded := true
  finally:
    if not succeeded:
      do-something-if-it-failed
  ```
- Toit does *not* support `try` with a `catch` block.

## super calls
In non-constructors 'super' calls the same-named function as the current one.

```
class A:
  foo x: return 40 + x

class B extends:
  foo: return super 2  // Returns `A.foo 2`.
```

Calling `super.foo` would be a mistake trying to call `foo` on 42.
