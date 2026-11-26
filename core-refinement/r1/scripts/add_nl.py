import sys
root = sys.argv[1]
p = root + '/verified/core/src/unwind.rs'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""/// TRY: installs a handler of the top frame""", """/// The frame of the block reference word `w` of `BlockRef(f, s)`.
#[inline(always)]
pub fn ref_frame(w: usize, Ghost(f): Ghost<usize>, Ghost(s): Ghost<usize>) -> (r: usize)
    requires w == block_word(f, s), f < 0x100_0000_0000, s < 0x10_0000,
    ensures r == f,
{
    proof {
        crate::blocks::lemma_block_decode(f, s);
        assert(w == (f * 0x10_0000 + s) * 2);
        assert(w >> 21 == f) by (bit_vector)
            requires w == (f * 0x10_0000 + s) * 2, f < 0x100_0000_0000, s < 0x10_0000;
    }
    w >> 21
}

/// NON_LOCAL_RETURN: returns the value below the block reference from the
/// block's frame, running the finally code of the frames in between.
#[inline(always)]
pub fn op_non_local_return(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
        lemma_shape(p, g);
    }
    let ghost v = sp::at(g, 0);
    let w = m.at(0);
    let f = ref_frame(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let x = m.at(1);
    let ghost gu = Unwind::Return(f, sp::at(g, 1));
    proof {
        assert(sp::op_non_local_return(ap, g) == sp::unwind(ap, g, gu));
        assert(f < 0x1_0000_0000);
    }
    let r = m.do_unwind(env, Unw::Return(f, x), Ghost(gu));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// NON_LOCAL_BRANCH hd off: continues in the block's frame at `off` from
/// its method's entry, with the object stack cut to `hd` slots below the
/// end of the block's slot, running the finally code of the frames in
/// between.
#[inline(always)]
pub fn op_non_local_branch(m: &mut Machine, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
        off < 0x1_0000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        m.lemma_at(p, 0);
        lemma_shape(p, g);
    }
    let ghost v = sp::at(g, 0);
    let w = m.at(0);
    let f = ref_frame(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let slot = crate::blocks::ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    proof {
        assert(f < g.frames.len());
        assert(rec(m.mem@, f as int, FRAME_METHOD) == g.frames[f as int].method);
        lemma_rec_index(g.frames.len() as int, f as int, FRAME_METHOD);
    }
    let method = m.mem.read(f * FRAME_WORDS + FRAME_METHOD);
    proof {
        assert(sp::valid_method(ap, method as int));
        assert(ap.methods[method as int] == method_info(p.methods@[method as int], p.max_height));
    }
    let info = p.methods.at(method);
    let target = info.entry as usize + off;
    let h = slot + 1 - hd;
    let ghost gu = Unwind::Branch(f, target, h);
    proof {
        assert(sp::op_non_local_branch(ap, g, hd as int, off as int) == sp::unwind(ap, g, gu));
        assert(f < 0x1_0000_0000);
    }
    let r = m.do_unwind(env, Unw::Branch(f, target, h), Ghost(gu));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// TRY: installs a handler of the top frame""")
open(p, 'w').write(s)

p = root + '/verified/core/src/step.rs'
s = open(p).read()
rep("""    ||| op == 90 || op == 97 || op == 99  // THROW, TRY, UNWIND
}""", """    ||| op == 90 || op == 97 || op == 99  // THROW, TRY, UNWIND
    ||| op == 93 || op == 95  // NON_LOCAL_RETURN, NON_LOCAL_BRANCH
}""")
rep("""        97 => {
            proof { assert(sp::step(ap, g) == sp::op_try(ap, g)) by { reveal(sp::step); } }""", """        93 => {
            proof { assert(sp::step(ap, g) == sp::op_non_local_return(ap, g)) by { reveal(sp::step); } }
            return crate::unwind::op_non_local_return(m, env, bci, opcode);
        },
        95 => {
            let hd = p.code.at(bci + 1) as usize;
            let off = code_u32(p, bci + 2);
            proof {
                assert(sp::step(ap, g) == sp::op_non_local_branch(ap, g, hd as int, off as int)) by { reveal(sp::step); }
            }
            return crate::unwind::op_non_local_branch(m, env, bci, opcode, hd, off);
        },
        97 => {
            proof { assert(sp::step(ap, g) == sp::op_try(ap, g)) by { reveal(sp::step); } }""")
open(p, 'w').write(s)
