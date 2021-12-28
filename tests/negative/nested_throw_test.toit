// Tests the entire process exits with exit value 1.
main:
  task::
    task::
      task:: throw "oops"
