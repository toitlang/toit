main condition values:
  result := condition
      ? values.map: it.trim
      : []
  print result
