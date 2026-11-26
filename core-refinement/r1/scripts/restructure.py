import sys, re
root = sys.argv[1]
p = root + '/verified/core/src/unwind.rs'
s = open(p).read()
def rep(old, new, cnt=1):
    global s
    assert s.count(old) == cnt, (old, s.count(old))
    s = s.replace(old, new)

# Header of the handler section: the shared machinery.
rep("""// ---------------------------------------------------------------------------
// Handlers.

/// THROW: unwinds with the top value.
#[inline(always)]
pub fn op_throw(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::has_slot(old(m).g@, 0),
        sp::step(env.p.ap@, old(m).g@) == sp::unwind(env.p.ap@, old(m).g@, Unwind::Throw(sp::at(old(m).g@, 0))),
    ensures step_post(env.p, *old(m), *final(m), r),
{""", """// ---------------------------------------------------------------------------
// Handlers. THROW, UNWIND, NON_LOCAL_RETURN and NON_LOCAL_BRANCH each
// prepare an unwinding (`prep_*`); `op_unwinding` runs the one unwinding
// loop for all of them, so that the loop is inlined into the run loop once
// (four copies cost about 5 percent of the instructions of richards in the
// loop head, `step.rs`).

/// What a `prep_*` function leaves: the instruction completed (`Done`), or
/// the machine is ready for `do_unwind(u)` from a state whose unwinding is
/// the spec's step.
pub enum Prep {
    Done(Ctl),
    Unwind(Unw),
}

/// `m1` is ready to run the unwinding `u` (`gu`) that is the spec's step
/// from `m0`.
pub open spec fn unwind_ready(p: &Program, m0: Machine, m1: Machine, u: Unw, gu: Unwind) -> bool {
    &&& m0.inv(p)
    &&& step_ok(p.ap@, p.cert@, m0.g@)
    &&& m1.refines(p)
    &&& shape_ok(p, m1.g@)
    &&& unw_rel(m1.addr(), u, gu)
    &&& resume_ok(sp::resume_of(gu))
    &&& sp::step(p.ap@, m0.g@) == sp::unwind(p.ap@, m1.g@, gu)
    &&& !(sp::unwind(p.ap@, m1.g@, gu) is Stuck)
}

pub open spec fn prep_post(p: &Program, m0: Machine, m1: Machine, r: (Prep, Ghost<Unwind>)) -> bool {
    match r.0 {
        Prep::Done(c) => step_post(p, m0, m1, c),
        Prep::Unwind(u) => unwind_ready(p, m0, m1, u, r.1@),
    }
}

/// THROW, NON_LOCAL_RETURN, NON_LOCAL_BRANCH hd off and UNWIND.
#[inline(always)]
pub fn op_unwinding(m: &mut Machine, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        opcode == 90 || opcode == 93 || opcode == 95 || opcode == 99,
        opcode == 90 ==> sp::has_slot(old(m).g@, 0)
            && sp::step(env.p.ap@, old(m).g@) == sp::unwind(env.p.ap@, old(m).g@, Unwind::Throw(sp::at(old(m).g@, 0))),
        opcode == 93 ==> sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
        opcode == 95 ==> off < 0x1_0000_0000
            && sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
        opcode == 99 ==> bci + 1 < 0x1000_0000
            && sp::step(env.p.ap@, old(m).g@) == sp::op_unwind(env.p.ap@, old(m).g@),
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let ghost m0 = *m;
    let (pr, gu) = if opcode == 90 {
        prep_throw(m, env, bci, opcode)
    } else if opcode == 93 {
        prep_non_local_return(m, env, bci, opcode)
    } else if opcode == 95 {
        prep_non_local_branch(m, env, bci, opcode, hd, off)
    } else {
        prep_unwind(m, env, bci, opcode)
    };
    match pr {
        Prep::Done(c) => c,
        Prep::Unwind(u) => {
            let r = m.do_unwind(env, u, gu);
            proof { lemma_matches(env.p, m0, *m, r); }
            r
        },
    }
}

/// THROW: unwinds with the top value.
#[inline(always)]
pub fn prep_throw(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::has_slot(old(m).g@, 0),
        sp::step(env.p.ap@, old(m).g@) == sp::unwind(env.p.ap@, old(m).g@, Unwind::Throw(sp::at(old(m).g@, 0))),
    ensures prep_post(env.p, *old(m), *final(m), r),
{""")
rep("""    let w = m.at(0);
    let r = m.do_unwind(env, Unw::Throw(w), Ghost(Unwind::Throw(sp::at(g, 0))));
    proof { lemma_matches(p, m0, *m, r); }
    r
}""", """    let w = m.at(0);
    (Prep::Unwind(Unw::Throw(w)), Ghost(Unwind::Throw(sp::at(g, 0))))
}""")
rep("""#[inline(always)]
pub fn op_unwind(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_unwind(env.p.ap@, old(m).g@),
        bci + 1 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),""", """#[inline(always)]
pub fn prep_unwind(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_unwind(env.p.ap@, old(m).g@),
        bci + 1 < 0x1000_0000,
    ensures prep_post(env.p, *old(m), *final(m), r),""")
rep("""        let r = m.op_pop(p, 3, 1);
        proof { lemma_matches(p, m0, *m, r); }
        return r;""", """        let r = m.op_pop(p, 3, 1);
        proof { lemma_matches(p, m0, *m, r); }
        return (Prep::Done(r), Ghost(Unwind::Throw(tv)));""")
rep("""        assert(shape_ok(p, g2));
    }
    let r = m.do_unwind(env, u, Ghost(gu));
    proof { lemma_matches(p, m0, *m, r); }
    r
}""", """        assert(shape_ok(p, g2));
    }
    (Prep::Unwind(u), Ghost(gu))
}""")
rep("""#[inline(always)]
pub fn op_non_local_return(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
    ensures step_post(env.p, *old(m), *final(m), r),""", """#[inline(always)]
pub fn prep_non_local_return(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
    ensures prep_post(env.p, *old(m), *final(m), r),""")
rep("""    let r = m.do_unwind(env, Unw::Return(f, x), Ghost(gu));
    proof { lemma_matches(p, m0, *m, r); }
    r
}""", """    (Prep::Unwind(Unw::Return(f, x)), Ghost(gu))
}""")
rep("""#[inline(always)]
pub fn op_non_local_branch(m: &mut Machine, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
        off < 0x1_0000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),""", """#[inline(always)]
pub fn prep_non_local_branch(m: &mut Machine, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
        off < 0x1_0000_0000,
    ensures prep_post(env.p, *old(m), *final(m), r),""")
rep("""    let r = m.do_unwind(env, Unw::Branch(f, target, h), Ghost(gu));
    proof { lemma_matches(p, m0, *m, r); }
    r
}""", """    (Prep::Unwind(Unw::Branch(f, target, h)), Ghost(gu))
}""")
open(p, 'w').write(s)

p = root + '/verified/core/src/step.rs'
s = open(p).read()
start = s.index("        90 => {")
end = s.index("        97 => {")
s = s[:start] + """        90 | 93 | 95 | 99 => {
            // One call site: the unwinding loop is inlined once.
            let (hd, off) = if opcode == 95 { (p.code.at(bci + 1) as usize, code_u32(p, bci + 2)) } else { (0, 0) };
            proof {
                if opcode == 90 {
                    assert(sp::step(ap, g) == (if !sp::has_slot(g, 0) { sp::stuck(toit_spec::types::Stuck::StackRange) }
                        else { sp::unwind(ap, g, Unwind::Throw(sp::at(g, 0))) })) by { reveal(sp::step); }
                    assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
                } else if opcode == 93 {
                    assert(sp::step(ap, g) == sp::op_non_local_return(ap, g)) by { reveal(sp::step); }
                } else if opcode == 95 {
                    assert(sp::step(ap, g) == sp::op_non_local_branch(ap, g, hd as int, off as int)) by { reveal(sp::step); }
                } else {
                    assert(sp::step(ap, g) == sp::op_unwind(ap, g)) by { reveal(sp::step); }
                }
            }
            return crate::unwind::op_unwinding(m, env, bci, opcode, hd, off);
        },
""" + s[end:]
start = s.index("        99 => {")
end = s.index("        _ => {\n            return step_unverified")
s = s[:start] + s[end:]
open(p, 'w').write(s)
