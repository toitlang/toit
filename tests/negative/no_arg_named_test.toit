main:
  must --no
  foo --foo
  fizz
  fish
  block_foo --foo=0
  non_block_foo --foo=(: 0)
  block_unnamed 0

must --have:

foo --bar=null:

fizz --bar=0 --baz:

fizz --bar=0 unnamed:

fish --hest:

fish --fisk:

block_foo [--foo]:

non_block_foo --foo:

block_unnamed [foo]:
