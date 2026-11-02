// Provenance: Written for this project.

main:
  total := 0
  60.repeat: | r |
    map := {:}
    20000.repeat: map[it * 7 + r] = it
    20000.repeat: total += map.get (it * 7 + r) --if-absent=(: 0)
    set := {}
    20000.repeat: set.add it % 1000
    total += set.size
    list := List 20000: (it * 2654435761) & 0xffff
    list.sort --in-place
    total += list[100]
  print total
