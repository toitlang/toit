package com.mycompany;

/*
 * CL_SUN_COPYRIGHT_JVM_BEGIN
 *   If you or the company you represent has a separate agreement with both
 *   CableLabs and Sun concerning the use of this code, your rights and
 *   obligations with respect to this code shall be as set forth therein. No
 *   license is granted hereunder for any other purpose.
 * CL_SUN_COPYRIGHT_JVM_END
*/

/*
 * @(#)DeltaBlue.java	1.6 06/10/10
 *
 * Copyright  1990-2006 Sun Microsystems, Inc. All Rights Reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License version
 * 2 only, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License version 2 for more details (a copy is
 * included at /legal/license.txt).
 *
 * You should have received a copy of the GNU General Public License
 * version 2 along with this work; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
 * 02110-1301 USA
 *
 * Please contact Sun Microsystems, Inc., 4150 Network Circle, Santa
 * Clara, CA 95054 or visit www.sun.com if you need additional
 * information or have any questions.
 *
 */
/*

  This is a Java implemention of the DeltaBlue algorithm described in:
    "The DeltaBlue Algorithm: An Incremental Constraint Hierarchy Solver"
    by Bjorn N. Freeman-Benson and John Maloney
    January 1990 Communications of the ACM,
    also available as University of Washington TR 89-08-06.

  This implementation by Mario Wolczko, Sun Microsystems, Sep 1996,
  based on the Smalltalk implementation by John Maloney.

*/

import java.util.ArrayList;

//import Benchmark;

/*
Strengths are used to measure the relative importance of constraints.
New strengths may be inserted in the strength hierarchy without
disrupting current constraints.  Strengths cannot be created outside
this class, so pointer comparison can be used for value comparison.
*/

class Strength {

	private final int strengthValue;
	private final String name;

	private Strength(int strengthValue, String name) {
		this.strengthValue = strengthValue;
		this.name = name;
	}

	public static boolean stronger(Strength s1, Strength s2) {
		return s1.strengthValue < s2.strengthValue;
	}

	public static boolean weaker(Strength s1, Strength s2) {
		return s1.strengthValue > s2.strengthValue;
	}

	public static Strength weakestOf(Strength s1, Strength s2) {
		return weaker(s1, s2) ? s1 : s2;
	}

	public static Strength strongest(Strength s1, Strength s2) {
		return stronger(s1, s2) ? s1 : s2;
	}

	// for iteration
	public Strength nextWeaker() {
		switch (this.strengthValue) {
		case 0:
			return weakest;
		case 1:
			return weakDefault;
		case 2:
			return normal;
		case 3:
			return strongDefault;
		case 4:
			return preferred;
		case 5:
			return strongPreferred;

		case 6:
		default:
			System.err.println("Invalid call to nextStrength()!");
			System.exit(1);
			return null;
		}
	}

	// Strength constants
	public final static Strength required = new Strength(0, "required");
	public final static Strength strongPreferred = new Strength(1, "strongPreferred");
	public final static Strength preferred = new Strength(2, "preferred");
	public final static Strength strongDefault = new Strength(3, "strongDefault");
	public final static Strength normal = new Strength(4, "normal");
	public final static Strength weakDefault = new Strength(5, "weakDefault");
	public final static Strength weakest = new Strength(6, "weakest");

	public void print() {
		System.out.print("strength[" + Integer.toString(this.strengthValue) + "]");
	}
}

// ------------------------------ variables ------------------------------

// I represent a constrained variable. In addition to my value, I
// maintain the structure of the constraint graph, the current
// dataflow graph, and various parameters of interest to the DeltaBlue
// incremental constraint solver.

class Variable {

	public int value; // my value; changed by constraints
	public ArrayList<Constraint> constraints; // normal constraints that reference me
	public Constraint determinedBy; // the constraint that currently determines
									// my value (or null if there isn't one)
	public int mark; // used by the planner to mark constraints
	public Strength walkStrength; // my walkabout strength
	public boolean stay; // true if I am a planning-time constant
	public String name; // a symbolic name for reporting purposes

	private Variable(String name, int initialValue, Strength walkStrength, int nconstraints) {
		this.value = initialValue;
		this.constraints = new ArrayList<Constraint>(nconstraints);
		this.determinedBy = null;
		this.mark = 0;
		this.walkStrength = walkStrength;
		this.stay = true;
		this.name = name;
	}

	public Variable(String name, int value) {
		this(name, value, Strength.weakest, 2);
	}

	public Variable(String name) {
		this(name, 0, Strength.weakest, 2);
	}

	public void print() {
		System.out.print(this.name + "(");
		this.walkStrength.print();
		System.out.print("," + this.value + ")");
	}

	// Add the given constraint to the set of all constraints that refer to me.
	public void addConstraint(Constraint c) {
		this.constraints.add(c);
	}

	// Remove all traces of c from this variable.
	public void removeConstraint(Constraint c) {
		this.constraints.remove(c);
		if (this.determinedBy == c) {
			this.determinedBy = null;
		}
	}

	// Attempt to assign the given value to me using the given strength.
	public void setValue(int value, Strength strength) {
		EditConstraint e = new EditConstraint(this, strength);
		if (e.isSatisfied()) {
			this.value = value;
			DeltaBlue.planner.propagateFrom(this);
		}
		e.destroyConstraint();
	}

}

// ------------------------ constraints ------------------------------------

// I am an abstract class representing a system-maintainable
// relationship (or "constraint") between a set of variables. I supply
// a strength instance variable; concrete subclasses provide a means
// of storing the constrained variables and other information required
// to represent a constraint.

abstract class Constraint {

	public Strength strength; // the strength of this constraint

	protected Constraint() {
	} // this has to be here because of
		// Java's constructor idiocy.

	protected Constraint(Strength strength) {
		this.strength = strength;
	}

	// Answer true if this constraint is satisfied in the current solution.
	public abstract boolean isSatisfied();

	// Record the fact that I am unsatisfied.
	public abstract void markUnsatisfied();

	// Normal constraints are not input constraints. An input constraint
	// is one that depends on external state, such as the mouse, the
	// keyboard, a clock, or some arbitrary piece of imperative code.
	public boolean isInput() {
		return false;
	}

	// Activate this constraint and attempt to satisfy it.
	protected void addConstraint() {
		addToGraph();
		DeltaBlue.planner.incrementalAdd(this);
	}

	// Deactivate this constraint, remove it from the constraint graph,
	// possibly causing other constraints to be satisfied, and destroy
	// it.
	public void destroyConstraint() {
		if (isSatisfied()) {
			DeltaBlue.planner.incrementalRemove(this);
		}
		removeFromGraph();
	}

	// Add myself to the constraint graph.
	public abstract void addToGraph();

	// Remove myself from the constraint graph.
	public abstract void removeFromGraph();

	// Decide if I can be satisfied and record that decision. The output
	// of the choosen method must not have the given mark and must have
	// a walkabout strength less than that of this constraint.
	protected abstract void chooseMethod(int mark);

	// Set the mark of all input from the given mark.
	protected abstract void markInputs(int mark);

	// Assume that I am satisfied. Answer true if all my current inputs
	// are known. A variable is known if either a) it is 'stay' (i.e. it
	// is a constant at plan execution time), b) it has the given mark
	// (indicating that it has been computed by a constraint appearing
	// earlier in the plan), or c) it is not determined by any
	// constraint.
	public abstract boolean inputsKnown(int mark);

	// Answer my current output variable. Raise an error if I am not
	// currently satisfied.
	public abstract Variable output();

	// Attempt to find a way to enforce this constraint. If successful,
	// record the solution, perhaps modifying the current dataflow
	// graph. Answer the constraint that this constraint overrides, if
	// there is one, or nil, if there isn't.
	// Assume: I am not already satisfied.
	//
	public Constraint satisfy(int mark) {
		chooseMethod(mark);
		if (!isSatisfied()) {
			if (this.strength == Strength.required) {
				DeltaBlue.error("Could not satisfy a required constraint");
			}
			return null;
		}
		// constraint can be satisfied
		// mark inputs to allow cycle detection in addPropagate
		markInputs(mark);
		Variable out = output();
		Constraint overridden = out.determinedBy;
		if (overridden != null) {
			overridden.markUnsatisfied();
		}
		out.determinedBy = this;
		if (!DeltaBlue.planner.addPropagate(this, mark)) {
			System.out.println("Cycle encountered");
			return null;
		}
		out.mark = mark;
		return overridden;
	}

	// Enforce this constraint. Assume that it is satisfied.
	public abstract void execute();

	// Calculate the walkabout strength, the stay flag, and, if it is
	// 'stay', the value for the current output of this
	// constraint. Assume this constraint is satisfied.
	public abstract void recalculate();

	protected abstract void printInputs();

	protected void printOutput() {
		output().print();
	}

	public void print() {
		int i, outIndex;

		if (!isSatisfied()) {
			System.out.print("Unsatisfied");
		} else {
			System.out.print("Satisfied(");
			printInputs();
			System.out.print(" -> ");
			printOutput();
			System.out.print(")");
		}
		System.out.print("\n");
	}

}

// -------------unary constraints-------------------------------------------

// I am an abstract superclass for constraints having a single
// possible output variable.
//
abstract class UnaryConstraint extends Constraint {

	protected Variable myOutput; // possible output variable
	protected boolean satisfied; // true if I am currently satisfied

	protected UnaryConstraint(Variable v, Strength strength) {
		super(strength);
		this.myOutput = v;
		this.satisfied = false;
		addConstraint();
	}

	// Answer true if this constraint is satisfied in the current solution.
	@Override
	public boolean isSatisfied() {
		return this.satisfied;
	}

	// Record the fact that I am unsatisfied.
	@Override
	public void markUnsatisfied() {
		this.satisfied = false;
	}

	// Answer my current output variable.
	@Override
	public Variable output() {
		return this.myOutput;
	}

	// Add myself to the constraint graph.
	@Override
	public void addToGraph() {
		this.myOutput.addConstraint(this);
		this.satisfied = false;
	}

	// Remove myself from the constraint graph.
	@Override
	public void removeFromGraph() {
		if (this.myOutput != null) {
			this.myOutput.removeConstraint(this);
		}
		this.satisfied = false;
	}

	// Decide if I can be satisfied and record that decision.
	@Override
	protected void chooseMethod(int mark) {
		this.satisfied = this.myOutput.mark != mark && Strength.stronger(this.strength, this.myOutput.walkStrength);
	}

	@Override
	protected void markInputs(int mark) {
	} // I have no inputs

	@Override
	public boolean inputsKnown(int mark) {
		return true;
	}

	// Calculate the walkabout strength, the stay flag, and, if it is
	// 'stay', the value for the current output of this
	// constraint. Assume this constraint is satisfied."
	@Override
	public void recalculate() {
		this.myOutput.walkStrength = this.strength;
		this.myOutput.stay = !isInput();
		if (this.myOutput.stay) {
			execute(); // stay optimization
		}
	}

	@Override
	protected void printInputs() {
	} // I have no inputs

}

// I am a unary input constraint used to mark a variable that the
// client wishes to change.
//
class EditConstraint extends UnaryConstraint {

	public EditConstraint(Variable v, Strength str) {
		super(v, str);
	}

	// I indicate that a variable is to be changed by imperative code.
	@Override
	public boolean isInput() {
		return true;
	}

	@Override
	public void execute() {
	} // Edit constraints do nothing.

}

// I mark variables that should, with some level of preference, stay
// the same. I have one method with zero inputs and one output, which
// does nothing. Planners may exploit the fact that, if I am
// satisfied, my output will not change during plan execution. This is
// called "stay optimization".
//
class StayConstraint extends UnaryConstraint {

	// Install a stay constraint with the given strength on the given variable.
	public StayConstraint(Variable v, Strength str) {
		super(v, str);
	}

	@Override
	public void execute() {
	} // Stay constraints do nothing.

}

// -------------binary constraints-------------------------------------------

// I am an abstract superclass for constraints having two possible
// output variables.
//
abstract class BinaryConstraint extends Constraint {

	protected Variable v1, v2; // possible output variables
	protected byte direction; // one of the following...
	protected static byte backward = -1; // v1 is output
	protected static byte nodirection = 0; // not satisfied
	protected static byte forward = 1; // v2 is output

	protected BinaryConstraint() {
	} // this has to be here because of
		// Java's constructor idiocy.

	protected BinaryConstraint(Variable var1, Variable var2, Strength strength) {
		super(strength);
		this.v1 = var1;
		this.v2 = var2;
		this.direction = nodirection;
		addConstraint();
	}

	// Answer true if this constraint is satisfied in the current solution.
	@Override
	public boolean isSatisfied() {
		return this.direction != nodirection;
	}

	// Add myself to the constraint graph.
	@Override
	public void addToGraph() {
		this.v1.addConstraint(this);
		this.v2.addConstraint(this);
		this.direction = nodirection;
	}

	// Remove myself from the constraint graph.
	@Override
	public void removeFromGraph() {
		if (this.v1 != null) {
			this.v1.removeConstraint(this);
		}
		if (this.v2 != null) {
			this.v2.removeConstraint(this);
		}
		this.direction = nodirection;
	}

	// Decide if I can be satisfied and which way I should flow based on
	// the relative strength of the variables I relate, and record that
	// decision.
	//
	@Override
	protected void chooseMethod(int mark) {
		if (this.v1.mark == mark) {
			this.direction = this.v2.mark != mark && Strength.stronger(this.strength, this.v2.walkStrength) ? forward
					: nodirection;
		}

		if (this.v2.mark == mark) {
			this.direction = this.v1.mark != mark && Strength.stronger(this.strength, this.v1.walkStrength) ? backward
					: nodirection;
		}

		// If we get here, neither variable is marked, so we have a choice.
		if (Strength.weaker(this.v1.walkStrength, this.v2.walkStrength)) {
			this.direction = Strength.stronger(this.strength, this.v1.walkStrength) ? backward : nodirection;
		} else {
			this.direction = Strength.stronger(this.strength, this.v2.walkStrength) ? forward : nodirection;
		}
	}

	// Record the fact that I am unsatisfied.
	@Override
	public void markUnsatisfied() {
		this.direction = nodirection;
	}

	// Mark the input variable with the given mark.
	@Override
	protected void markInputs(int mark) {
		input().mark = mark;
	}

	@Override
	public boolean inputsKnown(int mark) {
		Variable i = input();
		return i.mark == mark || i.stay || i.determinedBy == null;
	}

	// Answer my current output variable.
	@Override
	public Variable output() {
		return this.direction == forward ? this.v2 : this.v1;
	}

	// Answer my current input variable
	public Variable input() {
		return this.direction == forward ? this.v1 : this.v2;
	}

	// Calculate the walkabout strength, the stay flag, and, if it is
	// 'stay', the value for the current output of this
	// constraint. Assume this constraint is satisfied.
	//
	@Override
	public void recalculate() {
		Variable in = input(), out = output();
		out.walkStrength = Strength.weakestOf(this.strength, in.walkStrength);
		out.stay = in.stay;
		if (out.stay) {
			execute();
		}
	}

	@Override
	protected void printInputs() {
		input().print();
	}

}

// I constrain two variables to have the same value: "v1 = v2".
//
class EqualityConstraint extends BinaryConstraint {

	// Install a constraint with the given strength equating the given variables.
	public EqualityConstraint(Variable var1, Variable var2, Strength strength) {
		super(var1, var2, strength);
	}

	// Enforce this constraint. Assume that it is satisfied.
	@Override
	public void execute() {
		output().value = input().value;
	}

}

// I relate two variables by the linear scaling relationship: "v2 =
// (v1 * scale) + offset". Either v1 or v2 may be changed to maintain
// this relationship but the scale factor and offset are considered
// read-only.
//
class ScaleConstraint extends BinaryConstraint {

	protected Variable scale; // scale factor input variable
	protected Variable offset; // offset input variable

	// Install a scale constraint with the given strength on the given variables.
	public ScaleConstraint(Variable src, Variable scale, Variable offset, Variable dest, Strength strength) {
		// Curse this wretched language for insisting that constructor invocation
		// must be the first thing in a method...
		// ..because of that, we must copy the code from the inherited
		// constructors.
		this.strength = strength;
		this.v1 = src;
		this.v2 = dest;
		this.direction = nodirection;
		this.scale = scale;
		this.offset = offset;
		addConstraint();
	}

	// Add myself to the constraint graph.
	@Override
	public void addToGraph() {
		super.addToGraph();
		this.scale.addConstraint(this);
		this.offset.addConstraint(this);
	}

	// Remove myself from the constraint graph.
	@Override
	public void removeFromGraph() {
		super.removeFromGraph();
		if (this.scale != null) {
			this.scale.removeConstraint(this);
		}
		if (this.offset != null) {
			this.offset.removeConstraint(this);
		}
	}

	// Mark the inputs from the given mark.
	@Override
	protected void markInputs(int mark) {
		super.markInputs(mark);
		this.scale.mark = this.offset.mark = mark;
	}

	// Enforce this constraint. Assume that it is satisfied.
	@Override
	public void execute() {
		if (this.direction == forward) {
			this.v2.value = this.v1.value * this.scale.value + this.offset.value;
		} else {
			this.v1.value = (this.v2.value - this.offset.value) / this.scale.value;
		}
	}

	// Calculate the walkabout strength, the stay flag, and, if it is
	// 'stay', the value for the current output of this
	// constraint. Assume this constraint is satisfied.
	@Override
	public void recalculate() {
		Variable in = input(), out = output();
		out.walkStrength = Strength.weakestOf(this.strength, in.walkStrength);
		out.stay = in.stay && this.scale.stay && this.offset.stay;
		if (out.stay) {
			execute(); // stay optimization
		}
	}
}

// ------------------------------------------------------------

// A Plan is an ordered list of constraints to be executed in sequence
// to resatisfy all currently satisfiable constraints in the face of
// one or more changing inputs.

class Plan {

	private final ArrayList<Constraint> v;

	public Plan() {
		this.v = new ArrayList<Constraint>();
	}

	public void addConstraint(Constraint c) {
		this.v.add(c);
	}

	public int size() {
		return this.v.size();
	}

	public Constraint constraintAt(int index) {
		return this.v.get(index);
	}

	public void execute() {
		for (int i = 0; i < size(); ++i) {
			Constraint c = constraintAt(i);
			c.execute();
		}
	}

}

// ------------------------------------------------------------

// The DeltaBlue planner

class Planner {

	int currentMark = 0;

	// Select a previously unused mark value.
	private int newMark() {
		return ++this.currentMark;
	}

	public Planner() {
		this.currentMark = 0;
	}

	// Attempt to satisfy the given constraint and, if successful,
	// incrementally update the dataflow graph. Details: If satifying
	// the constraint is successful, it may override a weaker constraint
	// on its output. The algorithm attempts to resatisfy that
	// constraint using some other method. This process is repeated
	// until either a) it reaches a variable that was not previously
	// determined by any constraint or b) it reaches a constraint that
	// is too weak to be satisfied using any of its methods. The
	// variables of constraints that have been processed are marked with
	// a unique mark value so that we know where we've been. This allows
	// the algorithm to avoid getting into an infinite loop even if the
	// constraint graph has an inadvertent cycle.
	//
	public void incrementalAdd(Constraint c) {
		int mark = newMark();
		Constraint overridden = c.satisfy(mark);
		while (overridden != null) {
			overridden = overridden.satisfy(mark);
		}
	}

	// Entry point for retracting a constraint. Remove the given
	// constraint and incrementally update the dataflow graph.
	// Details: Retracting the given constraint may allow some currently
	// unsatisfiable downstream constraint to be satisfied. We therefore collect
	// a list of unsatisfied downstream constraints and attempt to
	// satisfy each one in turn. This list is traversed by constraint
	// strength, strongest first, as a heuristic for avoiding
	// unnecessarily adding and then overriding weak constraints.
	// Assume: c is satisfied.
	//
	public void incrementalRemove(Constraint c) {
		Variable out = c.output();
		c.markUnsatisfied();
		c.removeFromGraph();
		ArrayList<Constraint> unsatisfied = removePropagateFrom(out);
		Strength strength = Strength.required;
		do {
			for (int i = 0; i < unsatisfied.size(); ++i) {
				Constraint u = unsatisfied.get(i);
				if (u.strength == strength) {
					incrementalAdd(u);
				}
			}
			strength = strength.nextWeaker();
		} while (strength != Strength.weakest);
	}

	// Recompute the walkabout strengths and stay flags of all variables
	// downstream of the given constraint and recompute the actual
	// values of all variables whose stay flag is true. If a cycle is
	// detected, remove the given constraint and answer
	// false. Otherwise, answer true.
	// Details: Cycles are detected when a marked variable is
	// encountered downstream of the given constraint. The sender is
	// assumed to have marked the inputs of the given constraint with
	// the given mark. Thus, encountering a marked node downstream of
	// the output constraint means that there is a path from the
	// constraint's output to one of its inputs.
	//
	public boolean addPropagate(Constraint c, int mark) {
		ArrayList<Constraint> todo = new ArrayList<Constraint>();
		todo.add(c);
		while (!todo.isEmpty()) {
			Constraint d = todo.get(0);
			todo.remove(0);
			if (d.output().mark == mark) {
				incrementalRemove(c);
				return false;
			}
			d.recalculate();
			addConstraintsConsumingTo(d.output(), todo);
		}
		return true;
	}

	// The given variable has changed. Propagate new values downstream.
	public void propagateFrom(Variable v) {
		ArrayList<Constraint> todo = new ArrayList<Constraint>();
		addConstraintsConsumingTo(v, todo);
		while (!todo.isEmpty()) {
			Constraint c = todo.get(0);
			todo.remove(0);
			c.execute();
			addConstraintsConsumingTo(c.output(), todo);
		}
	}

	// Update the walkabout strengths and stay flags of all variables
	// downstream of the given constraint. Answer a collection of
	// unsatisfied constraints sorted in order of decreasing strength.
	//
	protected ArrayList<Constraint> removePropagateFrom(Variable out) {
		out.determinedBy = null;
		out.walkStrength = Strength.weakest;
		out.stay = true;
		ArrayList<Constraint> unsatisfied = new ArrayList<Constraint>();
		ArrayList<Variable> todo = new ArrayList<Variable>();
		todo.add(out);
		while (!todo.isEmpty()) {
			Variable v = todo.get(0);
			todo.remove(0);
			for (int i = 0; i < v.constraints.size(); ++i) {
				Constraint c = v.constraints.get(i);
				if (!c.isSatisfied()) {
					unsatisfied.add(c);
				}
			}
			Constraint determiningC = v.determinedBy;
			for (int i = 0; i < v.constraints.size(); ++i) {
				Constraint nextC = v.constraints.get(i);
				if (nextC != determiningC && nextC.isSatisfied()) {
					nextC.recalculate();
					todo.add(nextC.output());
				}
			}
		}
		return unsatisfied;
	}

	// Extract a plan for resatisfaction starting from the outputs of
	// the given constraints, usually a set of input constraints.
	//
	protected Plan extractPlanFromConstraints(ArrayList<Constraint> constraints) {
		ArrayList<Constraint> sources = new ArrayList<Constraint>();
		for (int i = 0; i < constraints.size(); ++i) {
			Constraint c = constraints.get(i);
			if (c.isInput() && c.isSatisfied()) {
				sources.add(c);
			}
		}
		return makePlan(sources);
	}

	// Extract a plan for resatisfaction starting from the given source
	// constraints, usually a set of input constraints. This method
	// assumes that stay optimization is desired; the plan will contain
	// only constraints whose output variables are not stay. Constraints
	// that do no computation, such as stay and edit constraints, are
	// not included in the plan.
	// Details: The outputs of a constraint are marked when it is added
	// to the plan under construction. A constraint may be appended to
	// the plan when all its input variables are known. A variable is
	// known if either a) the variable is marked (indicating that has
	// been computed by a constraint appearing earlier in the plan), b)
	// the variable is 'stay' (i.e. it is a constant at plan execution
	// time), or c) the variable is not determined by any
	// constraint. The last provision is for past states of history
	// variables, which are not stay but which are also not computed by
	// any constraint.
	// Assume: sources are all satisfied.
	//
	protected Plan makePlan(ArrayList<Constraint> sources) {
		int mark = newMark();
		Plan plan = new Plan();
		ArrayList<Constraint> todo = sources;
		while (!todo.isEmpty()) {
			Constraint c = todo.get(0);
			todo.remove(0);
			if (c.output().mark != mark && c.inputsKnown(mark)) {
				// not in plan already and eligible for inclusion
				plan.addConstraint(c);
				c.output().mark = mark;
				addConstraintsConsumingTo(c.output(), todo);
			}
		}
		return plan;
	}

	protected void addConstraintsConsumingTo(Variable v, ArrayList<Constraint> coll) {
		Constraint determiningC = v.determinedBy;
		ArrayList<Constraint> cc = v.constraints;
		for (int i = 0; i < cc.size(); ++i) {
			Constraint c = cc.get(i);
			if (c != determiningC && c.isSatisfied()) {
				coll.add(c);
			}
		}
	}

}

// ------------------------------------------------------------

public class DeltaBlue /* implements Benchmark */ {

	private long total_ms;

	public long getRunTime() {
		return this.total_ms;
	}

	public static Planner planner;

	public static void main(String[] args) {
		(new DeltaBlue()).inst_main(args);
	}

	public void inst_main(String args[]) {
		int iterations = 10;
		String options = "";

		if (args != null && args.length > 0) {
			iterations = Integer.parseInt(args[0]);
		}

		if (args != null && args.length > 1) {
			options = args[1];
		}

		long startTime = System.currentTimeMillis();
		for (int j = 0; j < iterations; ++j) {
			for (int i = 0; i < 10; i++) {
				chainTest(50);
				projectionTest(50);
			}
		}
		long endTime = System.currentTimeMillis();
		this.total_ms = endTime - startTime;
		System.out.println("DeltaBlue\tJava\t" + options + "\t" + iterations + "x\t"
				+ ((double) this.total_ms / iterations) + " ms");
	}

	// This is the standard DeltaBlue benchmark. A long chain of
	// equality constraints is constructed with a stay constraint on
	// one end. An edit constraint is then added to the opposite end
	// and the time is measured for adding and removing this
	// constraint, and extracting and executing a constraint
	// satisfaction plan. There are two cases. In case 1, the added
	// constraint is stronger than the stay constraint and values must
	// propagate down the entire length of the chain. In case 2, the
	// added constraint is weaker than the stay constraint so it cannot
	// be accomodated. The cost in this case is, of course, very
	// low. Typical situations lie somewhere between these two
	// extremes.
	//
	private void chainTest(int n) {
		planner = new Planner();

		Variable prev = null, first = null, last = null;

		// Build chain of n equality constraints
		for (int i = 0; i <= n; i++) {
			String name = "v" + Integer.toString(i);
			Variable v = new Variable(name);
			if (prev != null) {
				new EqualityConstraint(prev, v, Strength.required);
			}
			if (i == 0) {
				first = v;
			}
			if (i == n) {
				last = v;
			}
			prev = v;
		}

		new StayConstraint(last, Strength.strongDefault);
		Constraint editC = new EditConstraint(first, Strength.preferred);
		ArrayList<Constraint> editV = new ArrayList<Constraint>();
		editV.add(editC);
		Plan plan = planner.extractPlanFromConstraints(editV);
		for (int i = 0; i < 100; i++) {
			first.value = i;
			plan.execute();
			if (last.value != i) {
				error("Chain test failed!");
			}
		}
		editC.destroyConstraint();
	}

	// This test constructs a two sets of variables related to each
	// other by a simple linear transformation (scale and offset). The
	// time is measured to change a variable on either side of the
	// mapping and to change the scale and offset factors.
	//
	private void projectionTest(int n) {
		planner = new Planner();

		Variable scale = new Variable("scale", 10);
		Variable offset = new Variable("offset", 1000);
		Variable src = null, dst = null;

		ArrayList<Variable> dests = new ArrayList<Variable>();

		for (int i = 0; i < n; ++i) {
			src = new Variable("src" + Integer.toString(i), i);
			dst = new Variable("dst" + Integer.toString(i), i);
			dests.add(dst);
			new StayConstraint(src, Strength.normal);
			new ScaleConstraint(src, scale, offset, dst, Strength.required);
		}

		change(src, 17);
		if (dst.value != 1170) {
			error("Projection test 1 failed!");
		}

		change(dst, 1050);
		if (src.value != 5) {
			error("Projection test 2 failed!");
		}

		change(scale, 5);
		for (int i = 0; i < n - 1; ++i) {
			if ((dests.get(i)).value != i * 5 + 1000) {
				error("Projection test 3 failed!");
			}
		}

		change(offset, 2000);
		for (int i = 0; i < n - 1; ++i) {
			if ((dests.get(i)).value != i * 5 + 2000) {
				error("Projection test 4 failed!");
			}
		}
	}

	private void change(Variable var, int newValue) {
		EditConstraint editC = new EditConstraint(var, Strength.preferred);
		ArrayList<Constraint> editV = new ArrayList<Constraint>();
		editV.add(editC);
		Plan plan = planner.extractPlanFromConstraints(editV);
		for (int i = 0; i < 10; i++) {
			var.value = newValue;
			plan.execute();
		}
		editC.destroyConstraint();
	}

	public static void error(String s) {
		System.err.println(s);
		System.exit(1);
	}

}
