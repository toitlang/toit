import  ..foo.bar  as baz
import expect show *
export alpha beta

abstract class Device extends Base with Mix implements Interface:
    static VALUE /int ::= 1
    configure
        --organization/string
        --application/string
        value/int
        -> bool:
      if value: return true
      else: return false
    configure-network-interface --organization-identifier/string --application-identifier/string --word-size/int contents/ByteArray --more-flags/int -> bool:
      return true

main: return 0
