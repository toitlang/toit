import .named-arg-rename-test-dep

main:
  foo --named_arg=42
  foo --named_arg=7 --other_arg="hello"
  bar --flag
  obj := MyClass --value=42 --scale=2
