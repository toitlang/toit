encode-error_ type message:
  #primitive.core.encode-error

encode-object_ o:
  #primitive.core.encode-object

main args:
  a := Array_ 1
  a[0] = a
  if args.is-empty: encode-error_ "X" a
  else: encode-object_ a
  print "survived"
