// Copyright line.
main:
    // Before the value.
    value := 1  // Keep   every byte.
    /* Opaque
       alignment. */
    return value
    // First group.



    // Second group.


    grouped := 2
    if value:
      first
    else:  // Keep the else header.
      second

class C:
    abstract read -> List  // Keep abstract header.
    configure
        --x/int
        -> bool:  // Keep header placement.
      return true
