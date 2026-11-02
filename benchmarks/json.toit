// Provenance: Written for this project.

import encoding.json

main:
  entry := {"id": 12345, "name": "something", "tags": ["a", "b", "c"], "score": 12.5, "ok": true, "nested": {"x": 1, "y": [1, 2, 3, 4]}}
  items := List 300: entry
  total := 0
  30.repeat:
    bytes := json.encode items
    decoded := json.decode bytes
    total += bytes.size + decoded.size
  print total
