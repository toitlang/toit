foo x:
  #primitive.core.string-length
main:
  print (catch: foo 3)
  print (foo "abc")
