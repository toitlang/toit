main:
  // Multi-line source with two or more NamedArguments stays broken even
  // when it would fit flat — authors format these per-line for
  // readability.
  service
      --handler=this
      --priority=PRIORITY-PREFERRED

  // Same rule applies when the Call is wrapped in a DeclarationLocal
  // (goes through emit_stmt_flat instead of the bare-Call flat path).
  result := service
      --handler=this
      --priority=PRIORITY-PREFERRED

  // Single named arg: still collapses when it fits.
  service
      --handler=this

  // No named args: collapses when it fits (normal flat-if-fits).
  service
      arg_one
      arg_two

service --handler --priority=null -> any:
  return null

service --handler arg_one arg_two:
  return null

PRIORITY-PREFERRED := 0
