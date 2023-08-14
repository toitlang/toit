// Copyright 2011 Google Inc. All Rights Reserved.
// Copyright 1996 John Maloney and Mario Wolczko
//
// This file is part of GNU Smalltalk.
//
// GNU Smalltalk is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2, or (at your option) any later version.
//
// GNU Smalltalk is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
// details.
//
// You should have received a copy of the GNU General Public License along with
// GNU Smalltalk; see the file COPYING.  If not, write to the Free Software
// Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
//
// Translated first from Smalltalk to JavaScript, and finally to
// Dart by Google 2008-2010.

/**
A Toit implementation of the DeltaBlue constraint-solving
  algorithm, as described in:

```
"The DeltaBlue Algorithm: An Incremental Constraint Hierarchy Solver"
  Bjorn N. Freeman-Benson and John Maloney
  January 1990 Communications of the ACM,
  also available as University of Washington TR 89-08-06.
```

Beware: this benchmark is written in a grotesque style where
  the constraint model is built by side-effects from constructors.
I've kept it this way to avoid deviating too much from the original implementation.
*/

import .benchmark

main -> none:
  log-execution-time "Deltablue" --iterations=10:
    10.repeat:
      chain-test 50
      projection-test 50

/**
Strengths are used to measure the relative importance of constraints.
New strengths may be inserted in the strength hierarchy without
  disrupting current constraints.  Strengths cannot be created outside
  this class, so `==` can be used for value comparison.
*/
class Strength:

  constructor .value .name:

  value /int    := ?
  name  /string := ?

  next-weaker -> Strength:
    if value == 0: return WEAKEST
    if value == 1: return WEAK-DEFAULT
    if value == 2: return NORMAL
    if value == 3: return STRONG-DEFAULT
    if value == 4: return PREFERRED
    if value == 5: return STRONG-REFERRED
    unreachable


REQUIRED        ::= Strength 0 "required"
STRONG-REFERRED ::= Strength 1 "strongPreferred"
PREFERRED       ::= Strength 2 "preferred"
STRONG-DEFAULT  ::= Strength 3 "strongDefault"
NORMAL          ::= Strength 4 "normal"
WEAK-DEFAULT    ::= Strength 5 "weakDefault"
WEAKEST         ::= Strength 6 "weakest"

stronger s1/Strength s2/Strength -> bool:
  return s1.value < s2.value

weaker -> bool
    s1 /Strength
    s2 /Strength:
  return s1.value > s2.value

weakest s1/Strength s2/Strength -> Strength:
  return (weaker s1 s2) ? s1 : s2

strongest -> Strength
    s1 /Strength
    s2 /Strength:
  return (stronger s1 s2) ? s1 : s2

abstract class Constraint:

  abstract output            -> Variable
  abstract mark-unsatisfied  -> none
  abstract add-to-graph      -> none
  abstract remove-from-graph -> none
  abstract is-satisfied      -> bool
  abstract execute           -> none
  abstract choose-method mark/int -> none
  abstract mark-inputs   mark/int -> none

  strength /Strength := ?

  constructor .strength:

  /** Activate this constraint and attempt to satisfy it. */
  add-constraint:
    add-to-graph
    planner.incremental-add this

  /**
  Attempts to find a way to enforce this constraint. If successful,
    records the solution, perhaps modifying the current dataflow
    graph. Answer the constraint that this constraint overrides, if
    there is one, or null, if there isn't.
  Assume: I am not already satisfied.
  */
  satisfy -> Constraint?
      mark /int:
    choose-method mark
    if not is-satisfied:
      if strength == REQUIRED: throw "Could not satisfy a required constraint!"
      return null
    mark-inputs mark
    out := output
    overridden := out.determined-by
    if overridden: overridden.mark-unsatisfied
    out.determined-by = this
    if not planner.add-propagate this mark: throw "Cycle encountered"
    out.mark = mark
    return overridden

  destroy-constraint -> none:
    if is-satisfied: planner.incremental-remove this
    remove-from-graph

  /**
  Normal constraints are not input constraints.  An input constraint
    is one that depends on external state, such as the mouse, the
    keyboard, a clock, or some arbitrary piece of imperative code.
  */
  is-input -> bool:
    return false

/** Abstract superclass for constraints having a single possible output variable. */
abstract class UnaryConstraint extends Constraint:

  my-output    /Variable := ?
  is-satisfied /bool     := false

  constructor
      strength /Strength
      .my-output:
    super strength
    add-constraint

  /// Adds this constraint to the constraint graph
  add-to-graph -> none:
    my-output.add-constraint this
    is-satisfied = false

  /// Decides if this constraint can be satisfied and records that decision.
  choose-method mark/int -> none:
    is-satisfied = my-output.mark != mark and stronger strength my-output.walk-strength

  mark-inputs mark/int -> none:
    // has no inputs.

  /// Returns the current output variable.
  output -> Variable:
    return my-output

  /**
  Calculates the walkabout strength, the stay flag, and, if it is
    "stay", the value for the current output of this constraint. Assumes
    this constraint is satisfied.
  */
  recalculate -> none:
    my-output.walk-strength = strength
    my-output.stay = not is-input
    if my-output.stay: execute // Stay optimization.

  /// Records that this constraint is unsatisfied.
  mark-unsatisfied -> none:
    is-satisfied = false

  inputs-known -> bool
      mark /int:
    return true

  remove-from-graph -> none:
    my-output.remove-constraint this
    is-satisfied = false


/**
Variables that should, with some level of preference, stay the same.
Planners may exploit the fact that instances, if satisfied, will not
  change their output during plan execution.  This is called "stay optimization".
*/
class StayConstraint extends UnaryConstraint:

  constructor strength/Strength my-output/Variable:
    super strength my-output

  execute -> none:
    // Stay constraints do nothing.

/**
A unary input constraint used to mark a variable that the client
  wishes to change.
*/
class EditConstraint extends UnaryConstraint:

  constructor
      strength  /Strength
      my-output /Variable:
    super strength my-output

  /// Edits indicate that a variable is to be changed by imperative code.
  is-input -> bool:
    return true

  execute -> none:
    // Edit constraints do nothing.

// Directions.
NONE ::= 1
FORWARD ::= 2
BACKWARD ::= 0

/** Abstract superclass for constraints having two possible output variables. */
abstract class BinaryConstraint extends Constraint:

  v1 /Variable := ?
  v2 /Variable := ?
  direction /int := NONE

  constructor
      strength /Strength
      .v1
      .v2:
    super strength
    add-constraint

  /**
  Decides if this constraint can be satisfied and which way it
    should flow based on the relative strength of the variables related,
    and record that decision.
  */
  choose-method mark/int -> none:
    if v1.mark == mark:
      direction = (v2.mark != mark and stronger strength v2.walk-strength) ? FORWARD : NONE
    else if v2.mark == mark:
      direction = (v1.mark != mark and stronger strength v1.walk-strength) ? BACKWARD : NONE
    else if weaker v1.walk-strength v2.walk-strength:
      direction = (stronger strength v1.walk-strength) ? BACKWARD : NONE
    else:
      direction = (stronger strength v2.walk-strength) ? FORWARD : BACKWARD

  /// Adds this constraint to the constraint graph.
  add-to-graph -> none:
    v1.add-constraint this
    v2.add-constraint this
    direction = NONE

  /// Whether this constraint is satisfied in the current solution.
  is-satisfied -> bool:
    return direction != NONE

  /// Marks the input variable with the given mark.
  mark-inputs mark/int -> none:
    input.mark = mark

  /// Returns the current input variable
  input -> Variable:
    return direction == FORWARD ? v1 : v2

  /// Returns the current output variable.
  output -> Variable:
    return direction == FORWARD ? v2 : v1

  /**
  Calculates the walkabout strength, the stay flag, and, if it is
    "stay", the value for the current output of this
    constraint. Assumes this constraint is satisfied.
  */
  recalculate -> none:
    in := input
    out := output
    out.walk-strength = weakest strength in.walk-strength
    out.stay = in.stay
    if out.stay: execute

  /// Records the fact that this constraint is unsatisfied.
  mark-unsatisfied -> none:
    direction = NONE

  inputs-known mark/int -> bool:
    i := input
    return i.mark == mark or i.stay or i.determined-by

  remove-from-graph -> none:
    v1.remove-constraint this
    v2.remove-constraint this
    direction = NONE


/**
Relates two variables by the linear scaling relationship: `v2 = (v1 * scale) + offset`.
  Either v1 or v2 may be changed to maintain this relationship but the scale
  factor and offset are considered read-only.
*/
class ScaleConstraint extends BinaryConstraint:

  scale  /Variable := ?
  offset /Variable := ?

  constructor
      strength /Strength
      v1       /Variable
      v2       /Variable
      .scale
      .offset:
    super strength v1 v2

  /// Adds this constraint to the constraint graph.
  add-to-graph -> none:
    super
    scale.add-constraint this
    offset.add-constraint this

  remove-from-graph -> none:
    super
    scale.remove-constraint this
    offset.remove-constraint this

  mark-inputs mark/int -> none:
    super mark
    scale.mark = offset.mark = mark

  /// Enforces this constraint. Assumes that it is satisfied.
  execute -> none:
    if direction == FORWARD: v2.value = v1.value * scale.value + offset.value
    else: v1.value = (v2.value - offset.value) / scale.value

  /**
  Calculates the walkabout strength, the stay flag, and, if it is
    "stay", the value for the current output of this constraint. Assumes
    this constraint is satisfied.
  */
  recalculate -> none:
    in := input
    out := output
    out.walk-strength = weakest strength in.walk-strength
    out.stay = in.stay and scale.stay and offset.stay
    if out.stay: execute

/** Constrains two variables to have the same value. */
class EqualityConstraint extends BinaryConstraint:

  constructor strength/Strength v1/Variable v2/Variable:
    super strength v1 v2

  /// Enforces this constraint. Assume that it is satisfied.
  execute -> none:
    output.value = input.value


/**
A constrained variable. In addition to its value, it maintains the
  structure of the constraint graph, the current dataflow graph, and
  various parameters of interest to the DeltaBlue incremental
  constraint solver.
**/
class Variable:

  constructor .name .value:

  name  /string := ?
  value /int    := ?

  determined-by := null
  mark := 0
  walk-strength := WEAKEST
  stay := true
  constraints := []

  /**
  Adds the given constraint to the set of all constraints that refer this variable.
  */
  add-constraint c/Constraint -> none:
    constraints.add c

  /// Removes all traces of c from this variable.
  remove-constraint c/Constraint -> none:
    constraints.filter --in-place: it != c
    if determined-by == c: determined-by = null

class Planner:
  current-mark := 0

  /**
  Attempts to satisfy the given constraint and, if successful,
    incrementally updates the dataflow graph.

  # Details
  If satisfying the constraint is successful, it may override a weaker constraint
    on its output. The algorithm attempts to resatisfy that
    constraint using some other method. This process is repeated
    until either a) it reaches a variable that was not previously
    determined by any constraint or b) it reaches a constraint that
    is too weak to be satisfied using any of its methods. The
    variables of constraints that have been processed are marked with
    a unique mark value so that we know where we've been. This allows
    the algorithm to avoid getting into an infinite loop even if the
    constraint graph has an inadvertent cycle.
  */
  incremental-add c/Constraint -> none:
    mark := new-mark
    for overridden := c.satisfy mark;
        overridden;
        overridden = overridden.satisfy mark:
      // Nothing to do

  /**
  Entry point for retracting a constraint. Removes the given
    constraint and incrementally updates the dataflow graph.

  #Details
  Retracting the given constraint may allow some currently
    unsatisfiable downstream constraint to be satisfied. We therefore collect
    a list of unsatisfied downstream constraints and attempt to
    satisfy each one in turn. This list is traversed by constraint
    strength, strongest first, as a heuristic for avoiding
    unnecessarily adding and then overriding weak constraints.

  Assumes: $c is satisfied.
  */
  incremental-remove c/Constraint -> none:
    out := c.output
    c.mark-unsatisfied
    c.remove-from-graph
    unsatisfied := remove-propagate-from out
    strength := REQUIRED
    while true:
      unsatisfied.do: if it.strength == strength: incremental-add it
      strength = strength.next-weaker
      if strength == WEAKEST: break

  /// Selects a previously unused mark value.
  new-mark -> int:
    return ++current-mark

  /**
  Extracts a plan for resatisfaction starting from the given source
    constraints, usually a set of input constraints. This method
    assumes that stay optimization is desired; the plan will contain
    only constraints whose output variables are not stay. Constraints
    that do no computation, such as stay and edit constraints, are
    not included in the plan.

  #Details
  The outputs of a constraint are marked when it is added
    to the plan under construction. A constraint may be appended to
    the plan when all its input variables are known. A variable is
    known if either a) the variable is marked (indicating that has
    been computed by a constraint appearing earlier in the plan), b)
    the variable is "stay" (i.e. it is a constant at plan execution
    time), or c) the variable is not determined by any
    constraint. The last provision is for past states of history
    variables, which are not stay but which are also not computed by
    any constraint.

  Assumes: $sources are all satisfied.
  */
  make-plan sources/List -> Plan:
    mark := new-mark
    plan := Plan
    todo := sources
    while not todo.is-empty:
      c := todo.remove-last
      if c.output.mark != mark and c.inputs-known mark:
        plan.add-constraint c
        c.output.mark = mark
        add-constraints-consuming-to c.output todo
    return plan

  /**
  Extracts a plan for resatisfying starting from the output of the
    given $constraints, usually a set of input constraints.
  */
  extract-plan-from-constraints constraints/List -> Plan:
    sources := []
    constraints.do:
      // if not in plan already and eligible for inclusion.
      if it.is-input and it.is-satisfied: sources.add it
    return make-plan sources

  /**
  Recomputes the walkabout strengths and stay flags of all variables
    downstream of the given constraint and recomputes the actual
    values of all variables whose stay flag is true. If a cycle is
    detected, removes the given constraint and answer
    false. Otherwise, answers true.

  #Details
  Cycles are detected when a marked variable is
    encountered downstream of the given constraint. The sender is
    assumed to have marked the inputs of the given constraint with
    the given mark. Thus, encountering a marked node downstream of
    the output constraint means that there is a path from the
    constraint's output to one of its inputs.
  */
  add-propagate -> bool
      c    /Constraint
      mark /int:
    todo := [c]
    while not todo.is-empty:
      d := todo.remove-last
      if d.output.mark == mark:
        incremental-remove c
        return false
      d.recalculate
      add-constraints-consuming-to d.output todo
    return true

  /**
  Updates the walkabout strengths and stay flags of all variables
    downstream of the given constraint. Answers a collection of
    unsatisfied constraints sorted in order of decreasing strength.
  */
  remove-propagate-from out/Variable -> List:
    out.determined-by = null
    out.walk-strength = WEAKEST
    out.stay = true
    unsatisfied := []
    todo := [out]
    while not todo.is-empty:
      v := todo.remove-last
      v.constraints.do: if not it.is-satisfied: unsatisfied.add it
      determining := v.determined-by
      v.constraints.do:
        if it != determining and it.is-satisfied:
          it.recalculate
          todo.add it.output
    return unsatisfied

  add-constraints-consuming-to v/Variable coll/List -> none:
    determining := v.determined-by
    v.constraints.do: if it != determining and it.is-satisfied: coll.add it


/**
A $Plan is an ordered list of constraints to be executed in sequence
  to resatisfy all currently satisfiable constraints in the face of
  one or more changing inputs.
*/
class Plan:
  list_ /List := []

  add-constraint c/Constraint -> none:
    list_.add c

  execute -> none:
    list_.do: it.execute


planner /Planner? := null

/**
This is the standard DeltaBlue benchmark.

A long chain of equality
  constraints is constructed with a stay constraint on one end. An
  edit constraint is then added to the opposite end and the time is
  measured for adding and removing this constraint, and extracting
  and executing a constraint satisfaction plan. There are two cases.
  In case 1, the added constraint is stronger than the stay
  constraint and values must propagate down the entire length of the
  chain. In case 2, the added constraint is weaker than the stay
  constraint so it cannot be accommodated. The cost in this case is,
  of course, very low. Typical situations lie somewhere between these
  two extremes.
*/
chain-test n/int -> none:
  planner = Planner
  prev := null
  first := null
  last := null
  // Build chain of n equality constraints.
  for i := 0; i <= n; i++:
    v := Variable "v$i" 0
    if prev: EqualityConstraint REQUIRED prev v
    if i == 0: first = v
    if i == n: last = v
    prev = v
  StayConstraint STRONG-DEFAULT last
  edit := EditConstraint PREFERRED first
  plan := planner.extract-plan-from-constraints [edit]
  for i := 0; i < 100; i++:
    first.value = i
    plan.execute
    if last.value != i:
      throw "Chain test failed: $last.value != $i"

/**
This test constructs a two sets of variables related to each
  other by a simple linear transformation (scale and offset). The
  time is measured to change a variable on either side of the
  mapping and to change the scale and offset factors.
*/
projection-test n/int -> none:
  planner = Planner
  scale := Variable "scale" 10
  offset := Variable "offset" 1000
  src := null
  dst := null

  dests := []
  for i := 0; i < n; i++:
    src = Variable "src$i" i
    dst = Variable "dst$i" i
    dests.add dst
    StayConstraint NORMAL src
    ScaleConstraint REQUIRED src dst scale offset
  change src 17
  if dst.value != 1170: throw "Projection 1 failed"
  change dst 1050
  if src.value != 5: throw "Projection 2 failed"
  change scale 5
  for i := 0; i < n - 1; i++:
    if dests[i].value != i * 5 + 1000: throw "Projection 3 failed"
  change offset 2000
  for i := 0; i < n - 1; i++:
    if dests[i].value != i * 5 + 2000: throw "Projection 4 failed"

change v/Variable new-value/int -> none:
  edit := EditConstraint PREFERRED v
  plan := planner.extract-plan-from-constraints [edit]
  10.repeat:
    v.value = new-value
    plan.execute
  edit.destroy-constraint
