main elements:
  size := (elements.reduce --initial=0: | a b | a + b.size) + elements.size - 1 + 1
  print size
