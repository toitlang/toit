import sys
p = sys.argv[1] + '/verified/core/src/unwind.rs'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""        tries_ok(State2 { frames: frames, tries: tries, ..arbitrary_state() }),
        mem2.len() == mem.len(),""", """        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
        mem2.len() == mem.len(),""")
rep("""    let t2 = tries.drop_last();
    let g = State2 { frames: frames, tries: tries, ..arbitrary_state() };
""", """    let t2 = tries.drop_last();
""")
rep("""        assert(g.tries[x].frame < g.tries[tries.len() - 1].frame);""", """        assert(tries[x].frame < tries[tries.len() - 1].frame);""")
rep("""/// Any state (for the parts a lemma ignores).
pub open spec fn arbitrary_state() -> State2 {
    arbitrary()
}

""", "")
open(p, 'w').write(s)
p = sys.argv[1] + '/verified/core/src/lib.rs'
s = open(p).read()
rep("pub mod ops;\n", "pub mod ops;\npub mod unwind;\n")
open(p, 'w').write(s)
p = sys.argv[1] + '/verified/core/src/step.rs'
s = open(p).read()
rep("""    ||| op == 96         // IDENTICAL
}""", """    ||| op == 96         // IDENTICAL
    ||| op == 90 || op == 97 || op == 99  // THROW, TRY, UNWIND
}""")
rep("""        _ => {
            return step_unverified(m, env, bci, opcode);
        },
    };""", """        90 => {
            proof {
                assert(sp::step(ap, g) == (if !sp::has_slot(g, 0) { sp::stuck(toit_spec::types::Stuck::StackRange) }
                    else { sp::unwind(ap, g, Unwind::Throw(sp::at(g, 0))) })) by { reveal(sp::step); }
                assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
            }
            return crate::unwind::op_throw(m, env, bci, opcode);
        },
        97 => {
            proof { assert(sp::step(ap, g) == sp::op_try(ap, g)) by { reveal(sp::step); } }
            return crate::unwind::op_try(m, env, bci, opcode);
        },
        99 => {
            proof { assert(sp::step(ap, g) == sp::op_unwind(ap, g)) by { reveal(sp::step); } }
            return crate::unwind::op_unwind(m, env, bci, opcode);
        },
        _ => {
            return step_unverified(m, env, bci, opcode);
        },
    };""")
open(p, 'w').write(s)
