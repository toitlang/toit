import expect show *
import ...tools.pkg.registry
import ...tools.pkg.registry.git

test-git:
  registry := GitRegistry "toit" "github.com/toitware/registry" "1f76f33242ddcb7e71ff72be57c541d969aabfb2"



main:
  test-git