main:
  local := 3
  local = local
  unresolved

class A:
  field := 499

  constructor field:
    field = field

  method field:
    field = field

  static static_method field:
    field = field
