class Device:
  // Source has `-> Type` on the last line after all params — formatter
  // moves it up next to the method name. (When a header actually
  // wraps, the `:` goes to its own line; see method-header-wrap-colon.)
  configure
      --cs/int?=null
      --dc/int?=null
      --frequency/int
      --mode/int=0
      -> int:
    return cs or 0

  // Source has `-> Type` already on the first line — preserved as-is.
  other x/int y/int -> int
      --extra/int=0:
    return x + y + extra

  // No return type: header fits flat.
  no-return-type
      --a/int
      --b/int=0:
    return 0
