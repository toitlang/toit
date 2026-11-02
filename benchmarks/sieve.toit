// Provenance: Written for this project.

main:
  count := 0
  300.repeat:
    flags := List 20000 --initial=true
    c := 0
    i := 2
    while i < 20000:
      if flags[i]:
        c++
        j := i * 2
        while j < 20000:
          flags[j] = false
          j += i
      i++
    count += c
  print count
