main:
  // Bare Call far over the width budget: each positional arg breaks
  // onto its own line at indent + 4. Source was one line; the
  // formatter synthesises the breaks because the flat form doesn't
  // fit even with the slack allowance.
  register_event_handler_with_a_very_long_name aaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccc dddddddddddddddddddddd
  // Slightly over the nominal 100 columns but within the slack
  // allowance for indented code: stays flat.
  register_event_handler_with_a_very_long_name aaaaaaaaaaa bbbbbbbbbbb ccccccccccc ddddddddddd eeeeee

  // Return(Call) — wrapper stays on the first line with the target.
  return register_event_handler_with_a_very_long_name aaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccc dddddddddddddddddddddd

  // DeclarationLocal(Call).
  r := register_event_handler_with_a_very_long_name aaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccc dddddddddddddddddddddd

  // Assignment Binary whose RHS is a Call.
  r = register_event_handler_with_a_very_long_name aaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccc dddddddddddddddddddddd

  // Fits under the threshold: stays flat.
  short_call a b c

register_event_handler_with_a_very_long_name a b c d -> any:
  return null

short_call a b c -> any:
  return null

r := 0
aaaaaaaaaaa := 0
bbbbbbbbbbb := 0
ccccccccccc := 0
ddddddddddd := 0
eeeeee := 0
aaaaaaaaaaaaaaaaaaaaaa := 0
bbbbbbbbbbbbbbbbbbbbbb := 0
cccccccccccccccccccccc := 0
dddddddddddddddddddddd := 0
