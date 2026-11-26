import sys
root = sys.argv[1]
p = root + '/verified/core/src/calls.rs'
s = open(p).read()


def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)


start = s.index("    /// `spec::return_from(g, v)` for the result word")
end = s.index("    /// `spec::enter_finally(g, g.tries.last(), None)`")
s = s[:start] + open(root + '/../../../../opentoit-sandbox-artifacts/core-refinement/r1/scripts/do_return.rs.txt').read() + s[end:]

rep("""/// In a well-formed state the handlers belong to frames below the top,
/// in increasing order.""", """/// The handlers belong to frames up to the top one, in increasing order.
pub open spec fn tries_ok(g: State2) -> bool {
    &&& forall|x: int| 0 <= x < g.tries.len() ==> (#[trigger] g.tries[x]).frame + 1 <= g.frames.len()
    &&& forall|x: int, y: int| 0 <= x < y < g.tries.len() ==> (#[trigger] g.tries[x]).frame < (#[trigger] g.tries[y]).frame
}

/// The shape of the frames a return and an unwinding rely on (implied by
/// `wf`, kept while frames are popped): frames with valid methods and
/// ordered bases, handlers of frames up to the top.
pub open spec fn shape_ok(p: &Program, g: State2) -> bool {
    &&& g.frames.len() > 0
    &&& bases_ok(g)
    &&& tries_ok(g)
    &&& forall|fi: int| 0 <= fi < g.frames.len() ==> sp::valid_method(p.ap@, (#[trigger] g.frames[fi]).method as int)
}

/// Without a handler of the top frame, the handlers belong to frames below it.
pub proof fn lemma_no_handler(g: State2)
    requires tries_ok(g), g.frames.len() > 0, !sp::has_handler(g),
    ensures forall|x: int| 0 <= x < g.tries.len() ==> (#[trigger] g.tries[x]).frame + 1 < g.frames.len(),
{
    assert forall|x: int| 0 <= x < g.tries.len() implies (#[trigger] g.tries[x]).frame + 1 < g.frames.len() by {
        let l = g.tries.len() - 1;
        assert(g.tries[l] == g.tries.last());
        if x < l {
            assert(g.tries[x].frame < g.tries[l].frame);
        }
    }
}

/// A well-formed state has the shape.
pub proof fn lemma_shape(p: &Program, g: State2)
    requires accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
    ensures shape_ok(p, g),
{
    lemma_tries(p, g);
    assert forall|fi: int| 0 <= fi < g.frames.len() implies sp::valid_method(p.ap@, (#[trigger] g.frames[fi]).method as int) by {
        reveal(wf);
        reveal(toit_spec::v2::sound::wf_task);
        reveal(toit_spec::v2::sound::frame_ok);
        assert(toit_spec::v2::sound::frame_ok(p.ap@, p.cert@, g, fi));
    }
}

/// In a well-formed state the handlers belong to frames below the top,
/// in increasing order.""")
rep("""    let ghost m0 = *m;
    proof { assert(outcome_ok(env.p.ap@, env.p.cert@, sp::step(env.p.ap@, m.g@))); }
    let r = m.do_return(env, w, Ghost(v));""", """    let ghost m0 = *m;
    proof {
        assert(outcome_ok(env.p.ap@, env.p.cert@, sp::step(env.p.ap@, m.g@)));
        lemma_shape(env.p, m.g@);
    }
    let r = m.do_return(env, w, Ghost(v));""")
rep("use toit_spec::types::{Value, Frame, Handler};", "use toit_spec::types::{Value, Frame, Handler, Fin};")
open(p, 'w').write(s)
