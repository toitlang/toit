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
  log_execution_time "Deltablue" --iterations=10:
    10.repeat:
      chain_test 50
      projection_test 50

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

  next_weaker -> Strength:
    if value == 0: return WEAKEST
    if value == 1: return WEAK_DEFAULT
    if value == 2: return NORMAL
    if value == 3: return STRONG_DEFAULT
    if value == 4: return PREFERRED
    if value == 5: return STRONG_REFERRED
    unreachable


REQUIRED        ::= Strength 0 "required"
STRONG_REFERRED ::= Strength 1 "strongPreferred"
PREFERRED       ::= Strength 2 "preferred"
STRONG_DEFAULT  ::= Strength 3 "strongDefault"
NORMAL          ::= Strength 4 "normal"
WEAK_DEFAULT    ::= Strength 5 "weakDefault"
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
  abstract mark_unsatisfied  -> none
  abstract add_to_graph      -> none
  abstract remove_from_graph -> none
  abstract is_satisfied      -> bool
  abstract execute           -> none
  abstract choose_method mark/int -> none
  abstract mark_inputs   mark/int -> none

  strength /Strength := ?

  constructor .strength:

  /** Activate this constraint and attempt to satisfy it. */
  add_constraint:
    add_to_graph
    planner.incremental_add this

  /**
  Attempts to find a way to enforce this constraint. If successful,
    records the solution, perhaps modifying the current dataflow
    graph. Answer the constraint that this constraint overrides, if
    there is one, or null, if there isn't.
  Assume: I am not already satisfied.
  */
  satisfy -> Constraint?
      mark /int:
    choose_method mark
    if not is_satisfied:
      if strength == REQUIRED: throw "Could not satisfy a required constraint!"
      return null
    mark_inputs mark
    out := output
    overridden := out.determined_by
    if overridden: overridden.mark_unsatisfied
    out.determined_by = this
    if not planner.add_propagate this mark: throw "Cycle encountered"
    out.mark = mark
    return overridden

  destroy_constraint -> none:
    if is_satisfied: planner.incremental_remove this
    remove_from_graph

  /**
  Normal constraints are not input constraints.  An input constraint
    is one that depends on external state, such as the mouse, the
    keyboard, a clock, or some arbitrary piece of imperative code.
  */
  is_input -> bool:
    return false

/** Abstract superclass for constraints having a single possible output variable. */
abstract class UnaryConstraint extends Constraint:

  my_output    /Variable := ?
  is_satisfied /bool     := false

  constructor
      strength /Strength
      .my_output:
    super strength
    add_constraint

  /// Adds this constraint to the constraint graph
  add_to_graph -> none:
    my_output.add_constraint this
    is_satisfied = false

  /// Decides if this constraint can be satisfied and records that decision.
  choose_method mark/int -> none:
    is_satisfied = my_output.mark != mark and stronger strength my_output.walk_strength

  mark_inputs mark/int -> none:
    // has no inputs.

  /// Returns the current output variable.
  output -> Variable:
    return my_output

  /**
  Calculates the walkabout strength, the stay flag, and, if it is
    "stay", the value for the current output of this constraint. Assumes
    this constraint is satisfied.
  */
  recalculate -> none:
    my_output.walk_strength = strength
    my_output.stay = not is_input
    if my_output.stay: execute // Stay optimization.

  /// Records that this constraint is unsatisfied.
  mark_unsatisfied -> none:
    is_satisfied = false

  inputs_known -> bool
      mark /int:
    return true

  remove_from_graph -> none:
    my_output.remove_constraint this
    is_satisfied = false


/**
Variables that should, with some level of preference, stay the same.
Planners may exploit the fact that instances, if satisfied, will not
  change their output during plan execution.  This is called "stay optimization".
*/
class StayConstraint extends UnaryConstraint:

  constructor strength/Strength my_output/Variable:
    super strength my_output

  execute -> none:
    // Stay constraints do nothing.

/**
A unary input constraint used to mark a variable that the client
  wishes to change.
*/
class EditConstraint extends UnaryConstraint:

  constructor
      strength  /Strength
      my_output /Variable:
    super strength my_output

  /// Edits indicate that a variable is to be changed by imperative code.
  is_input -> bool:
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
    add_constraint

  /**
  Decides if this constraint can be satisfied and which way it
    should flow based on the relative strength of the variables related,
    and record that decision.
  */
  choose_method mark/int -> none:
    if v1.mark == mark:
      direction = (v2.mark != mark and stronger strength v2.walk_strength) ? FORWARD : NONE
    else if v2.mark == mark:
      direction = (v1.mark != mark and stronger strength v1.walk_strength) ? BACKWARD : NONE
    else if weaker v1.walk_strength v2.walk_strength:
      direction = (stronger strength v1.walk_strength) ? BACKWARD : NONE
    else:
      direction = (stronger strength v2.walk_strength) ? FORWARD : BACKWARD

  /// Adds this constraint to the constraint graph.
  add_to_graph -> none:
    v1.add_constraint this
    v2.add_constraint this
    direction = NONE

  /// Whether this constraint is satisfied in the current solution.
  is_satisfied -> bool:
    return direction != NONE

  /// Marks the input variable with the given mark.
  mark_inputs mark/int -> none:
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
    out.walk_strength = weakest strength in.walk_strength
    out.stay = in.stay
    if out.stay: execute

  /// Records the fact that this constraint is unsatisfied.
  mark_unsatisfied -> none:
    direction = NONE

  inputs_known mark/int -> bool:
    i := input
    return i.mark == mark or i.stay or i.determined_by

  remove_from_graph -> none:
    v1.remove_constraint this
    v2.remove_constraint this
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
  add_to_graph -> none:
    super
    scale.add_constraint this
    offset.add_constraint this

  remove_from_graph -> none:
    super
    scale.remove_constraint this
    offset.remove_constraint this

  mark_inputs mark/int -> none:
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
    out.walk_strength = weakest strength in.walk_strength
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

  determined_by := null
  mark := 0
  walk_strength := WEAKEST
  stay := true
  constraints := []

  /**
  Adds the given constraint to the set of all constraints that refer this variable.
  */
  add_constraint c/Constraint -> none:
    constraints.add c

  /// Removes all traces of c from this variable.
  remove_constraint c/Constraint -> none:
    constraints.filter --in_place: it != c
    if determined_by == c: determined_by = null

class Planner:
  current_mark := 0

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
  incremental_add c/Constraint -> none:
    mark := new_mark
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
  incremental_remove c/Constraint -> none:
    out := c.output
    c.mark_unsatisfied
    c.remove_from_graph
    unsatisfied := remove_propagate_from out
    strength := REQUIRED
    while true:
      unsatisfied.do: if it.strength == strength: incremental_add it
      strength = strength.next_weaker
      if strength == WEAKEST: break

  /// Selects a previously unused mark value.
  new_mark -> int:
    return ++current_mark

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
  make_plan sources/List -> Plan:
    mark := new_mark
    plan := Plan
    todo := sources
    while not todo.is_empty:
      c := todo.remove_last
      if c.output.mark != mark and c.inputs_known mark:
        plan.add_constraint c
        c.output.mark = mark
        add_constraints_consuming_to c.output todo
    return plan

  /**
  Extracts a plan for resatisfying starting from the output of the
    given $constraints, usually a set of input constraints.
  */
  extract_plan_from_constraints constraints/List -> Plan:
    sources := []
    constraints.do:
      // if not in plan already and eligible for inclusion.
      if it.is_input and it.is_satisfied: sources.add it
    return make_plan sources

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
  add_propagate -> bool
      c    /Constraint
      mark /int:
    todo := [c]
    while not todo.is_empty:
      d := todo.remove_last
      if d.output.mark == mark:
        incremental_remove c
        return false
      d.recalculate
      add_constraints_consuming_to d.output todo
    return true

  /**
  Updates the walkabout strengths and stay flags of all variables
    downstream of the given constraint. Answers a collection of
    unsatisfied constraints sorted in order of decreasing strength.
  */
  remove_propagate_from out/Variable -> List:
    out.determined_by = null
    out.walk_strength = WEAKEST
    out.stay = true
    unsatisfied := []
    todo := [out]
    while not todo.is_empty:
      v := todo.remove_last
      v.constraints.do: if not it.is_satisfied: unsatisfied.add it
      determining := v.determined_by
      v.constraints.do:
        if it != determining and it.is_satisfied:
          it.recalculate
          todo.add it.output
    return unsatisfied

  add_constraints_consuming_to v/Variable coll/List -> none:
    determining := v.determined_by
    v.constraints.do: if it != determining and it.is_satisfied: coll.add it


/**
A $Plan is an ordered list of constraints to be executed in sequence
  to resatisfy all currently satisfiable constraints in the face of
  one or more changing inputs.
*/
class Plan:
  list_ /List := []

  add_constraint c/Constraint -> none:
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
chain_test n/int -> none:
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
  StayConstraint STRONG_DEFAULT last
  edit := EditConstraint PREFERRED first
  plan := planner.extract_plan_from_constraints [edit]
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
projection_test n/int -> none:
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

change v/Variable new_value/int -> none:
  edit := EditConstraint PREFERRED v
  plan := planner.extract_plan_from_constraints [edit]
  10.repeat:
    v.value = new_value
    plan.execute
  edit.destroy_constraint
