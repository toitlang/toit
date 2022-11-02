# Toit C++ style guide

When contributing code to Toit, please follow the style of the
existing C++ code as much as possible.  This makes code easier
to read and update for other project members.

Here we mention some of the style rules that we try to follow.
In general it is more important to follow the
style of the code already in Toit than to adhere to the style
guide.

## Language features

For performance reasons, we compile with `-fno-exceptions` and so C++ exception
handling is not available.

We also compile with `-fno-rtti`, though this might change at some point.

We do not allow use of the C++ standard library on the device, for reasons of
code size and because out-of-memory is generally not handled.
In particular this means no use of `std::string`.

We make very sparing use of C++ references.  If used for function arguments
they should be const references.  Use pointers for passing an object that
can be modified.

## Classes and structs.

We prefer simple classes to structs, because that means we can make
a constructor that initializes the fields.  Constructors should normally
initialize all fields.

If external code provides a struct that we use it is not necessary to
use the `struct` keyword with the type.

For very simple classes that almost could have been structs it is OK
to have public fields without getters and setters.  This might be
the case if the class is only used in one file.

## Casts

We don't use old-style C casts because they are hard to search for and have no
checking or warnings from the compiler.  `utils.h` has some useful casts:

- `unsigned_cast(foo)` will cast a type to the equivalent unsigned type.
- `signed_cast(foo)` will cast a type to the equivalent signed type.
- `char_cast(foo)` will cast a pointer to anything char-sized to a `char` pointer.
- `unvoid_cast<my_type*>(foo)` will only cast from `void*` to another pointer type.
- `void_cast(foo)` will only cast to `void*` from another pointer type.

If none of these are applicable then replace the C-style cast with `const_cast`,
`reinterpret_cast`, or `static_cast`.

## Syntax

### Operators

Place asterisks and ampersands by the type, not by the variable:

```
  char *p;  // No.
  char* q;  // Better.
```

Put spaces on both sides of binary operators:

```
  foo(a+b);    // No.
  foo(a + b);  // Better.
```

Prefer postfix increments.
```
  i++;    // Yes.
  ++i;    // No.
  i--;    // Yes.
  --i;    // No.
```

When using C++ iterators there may be an efficiency reason to use prefix
iterators instead.

It is good to use parentheses to disambiguate precedence, but the reader
is expected to know some common ones.

```
  x = a + b * c;               // OK, we all know that * and / bind stronger than + and -.
  x = a * b + c;               // OK.
  x = (a * b) + c;             // No, too many parentheses.
  flag = (a && b) || c;        // OK, not everyone can remember that && binds stronger than ||.
  flag = a && b || c;          // No, causes a warning from the compiler.
  if (a == 0 && b >= 0) {      // OK, we all know that comparisons bind stronger than && and ||.
  if ((a == 0) && (b == 0)) {  // No, too many parentheses.
```

### Spacing

Put a space between the keyword and the parenthesis of `if`, `while`, and `for`.
Also put a space after the closing parenthesis.  No spaces are needed inside the
parentheses.

```
  if(x == 0) foo();     // No: Missing space.
  if (x == 0)foo();     // No: Missing space.
  if ( x == 0 ) foo();  // No: Too much space.
  if( x == 0 )foo();    // No: Spaces in wrong places.
  if (x == 0) foo();    // Good.
  while (true){         // No: Missing space.
    do_work();          // Note, no spaces before '(' in calls.
  }
  while(true) {         // No: Missing space.
  }
  while (true) {        // Good.
  }
  for (int i = 0; i < size; i++) {  // Correct spacing for 'for'.
    foo(i);
  }
  if (x < 0) return;    // Single-line if's are allowed.
  if (x > 100)
    return;             // No. Use curly braces for multi-line 'if's and loops.
```

### Indentation and line length

We use two-space indentation for grouping compound statements.  Never tabs.

When breaking a line that is too long, we use four-space indentation.

```
int foo(int a, int b) {  // Curly open-braces on the same line.
  b *= 2;                // Two-space indentation.
  a +=                   // Imagine that this line is very long and we had to break it.
      b;                 // 4-space indentation due to long line 
  return a;
}
```

Visibility modifiers (`private`, `public`, `protected`) are indented by only
one character (see below for an example).

If an entire `.h` file is in a namespace that namespace can be used without
indentation:

```
namespace "toit" {

int my_function();   // Yes, not indented.

}
```

We are not strict about long lines, but consider breaking if you exceed 120
characters.  Block comments are easy to reformat and are easier to read when
kept under 80 characters in width.

### Comments.

Comments should normally be full English sentences or at least a noun phrase,
starting with a capital letter and ending with a full stop.

```
int bar() {
  foo(56, 612);  // bad
  foo(42, 103);  // This is a sentence.
  return 89;
}
```

For line comments (`//`) leave at least two spaces between the code and the comment.
If there are not alignment issues, leave exactly two spaces.  After the double
slash, leave one space.

```
void baz() {
  my_function(56, 612);//Too cramped.
  foo(42, 103);  // That's more like it.
  f(87);         // Can leave more space for alignment.
}
```

## Naming

Classes have an initial capital letter and camel case.  Abbreviations are treated as normal words with an initial capital letter.

```
class foo;             // No.
class Bar;             // Yes.
class FooBar;          // Yes, camel.
class HttpConnection;  // Yes, capitalize HTTP like it was a regular word.
```

Methods and functions are written with lower case and underscores.

```
class Foo {
 public:
  int method_a();  // Yes.
  int MethodB();   // No, use lower case.
  int methodC();   // No, use underscores.
};
```

Local variables and arguments can be short, but not too short.  Avoid needless
abbreviations.  For example, `address` is usually better than `addr`.
Single-letter loop variables like `i` and `j` are OK if all uses are within 2-3
lines of each other.  Otherwise it probably makes sense to give a better name
to the loop variable.

Top-level constants are named with `ALL_CAPS_AND_UNDERSCORES`.

Private member variables (fields) are named with lower case and underscores,
and a trailing underscore.  (This matches the naming in Google's C++ style and
also the naming in Toit.)

```
class Pair {
 public:
  Pair(uint16 x, uint16 y)
      : value_((static_cast<uint32>(x) << 16) | y) {}

 private:
  uint32 value_;
};
```

## Readability

Try to avoid unnamed bool arguments if it's not clear at the call site what
their meaning is.

```
  my_function(42, true);                 // What does this mean?

  bool force = true;
  my_function(42, force);                // More readable.

  bool override;
  my_other_function(42, override=true);  // Also readable.
```

## Toit-specific

### Compiler

The Toit compiler is not run on the memory-constrained devices, so it may
use standard C++ library features, like std::string.  But don't go mad
(no Boost, please).

The Toit compiler is designed to run for a short time and restart frequently.
Therefore it does not normally free memory.  This simplifies C++ a lot.
Thus there is no need for 'smart pointers'.

It is not neccessary to check the return value of `malloc` and `new` in
the compiler code.

### VM/OS

On the device memory is very restricted.  Therefore any `malloc` may fail
at any time, except perhaps at system startup.  The code should cope with
a failed `malloc` by triggering a GC.

Do not use plain `new`, but instead use `_new`.  If you are integrating
third party code that uses `new` you will hit a fatal assertion.  This
is because such code generally cannot cope with memory exhaustion without
crashing.

Some uses of C++ closures will cause the compiler to generate
calls to `new` that will crash on memory shortage.  Avoid capturing
too many variables to avoid this.  Otherwise you will hit an assert.

Always check the return value of `_new` for a null pointer.  In this
case the constructor has not been called.  If the code only runs on
non-embedded ports of the VM (Posix, Windows) then you can assume
that `malloc` and `_new` always succeed.

Within primitives and any code called by primtives you need to be
able to restart the entire primitive if you encounter an allocation
error.  In this case it is critical to clean up and not leak memory.
Any allocations on the Toit heap can be ignored for these
purposes since it will be collected at the next GC.

It is usually best to allocate Toit objects at the top of the
primitive.  Since they don't need cleanup/freeing on failure
this minimizes the amount of cleanup code needed.

Consider freeing memory in destructors of local stack-allocated
C++ objects (using the RAII C++ pattern).
