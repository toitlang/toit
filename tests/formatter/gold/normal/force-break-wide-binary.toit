main:
  // Too-wide Binary chain: break between operands at indent + 4, the
  // operator leading each continuation line (trailing operators would
  // right-nest the re-parsed chain). The wrapper prefix (`x :=`) stays
  // with the first operand on the first line.
  x := long_addend_alpha + long_addend_beta + long_addend_gamma + long_addend_delta + long_addend_epsilon + long_addend_zeta
  return long_addend_alpha + long_addend_beta + long_addend_gamma + long_addend_delta + long_addend_epsilon + long_addend_zeta
  long_addend_alpha + long_addend_beta + long_addend_gamma + long_addend_delta + long_addend_epsilon + long_addend_zeta

  // Slightly over 100 columns but within the slack allowance: flat.
  y := long_addend_alpha + long_addend_beta + long_addend_gamma + long_addend_delta + long_addend_eps

  // Short chain that fits: stays flat.
  short := 1 + 2 + 3

long_addend_alpha := 0
long_addend_beta := 0
long_addend_gamma := 0
long_addend_delta := 0
long_addend_eps := 0
long_addend_epsilon := 0
long_addend_zeta := 0
