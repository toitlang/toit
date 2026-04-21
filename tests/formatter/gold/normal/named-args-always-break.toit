main:
  // 4+ NamedArguments: always broken, even when the flat form fits.
  service --a=1 --b=2 --c=3 --d=4

  // 3 NamedArguments: still flat when fits.
  service --a=1 --b=2 --c=3

  // Wrapper: same threshold applies via emit_stmt_flat's walk.
  r := service --a=1 --b=2 --c=3 --d=4

service --a --b --c --d=0:
  return null

r := 0
