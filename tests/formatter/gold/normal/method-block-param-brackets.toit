// Block-parameter brackets (`[...]`) sit outside Parameter's full_range.
// The method-signature-with-return-type rewrite must still preserve them
// when moving `-> Type` to the first line.

pod-for_ -> bool
    --local/string?
    --remote/string?
    --fleet/int
    [--on-absent]:
  return true

// Block param without a return type: falls through to the original
// rewrite path (no `-> Type` to move). Still needs brackets preserved.
each
    items/List
    [--handler]:
  items.do: | x | handler.call x
