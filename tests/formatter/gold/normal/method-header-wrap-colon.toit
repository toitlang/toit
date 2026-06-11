class C:
  // A header too wide even with the slack allowance: the return type
  // moves next to the name, each parameter gets its own continuation
  // line, and the body-separator `:` goes on its own line at the
  // method's indent.
  configure-network-interface --organization-identifier/string --application-identifier/string --word-size/int contents/ByteArray --more-flags/int -> bool:
    return true

  // A wrapped header on an abstract-style signature keeps no colon.
  abstract handle-incoming-request --organization-identifier/string --application-identifier/string --request-payload/ByteArray --response-timeout/int -> none

// Fits flat: colon stays glued.
short-method x/int y/int -> int:
  return x + y
