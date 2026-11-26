import sys
root = sys.argv[1]
p = root + '/verified/core/src/unwind.rs'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""            if handler != 0 {
                return self.enter_finally_unwind(env, handler, u, Ghost(gu));
            }""", """            if handler != 0 {
                proof {
                    assert(self.refines(p));
                    assert(self.g@ == g);
                    assert(o == sp::enter_finally(ap, g, g.tries.last(), Some(gu)));
                }
                return self.enter_finally_unwind(env, handler, u, Ghost(gu));
            }""")
rep("""        if fi == n - 1 {
            assert(t2[tries.len() as int] == h);
        } else {""", """        if fi == n - 1 {
            let x = tries.len() as int;
            assert(t2[x] == h);
            assert(0 <= x < t2.len() && t2[x].frame == fi);
        } else {""")
open(p, 'w').write(s)
p = root + '/verified/core/src/exec.rs'
s = open(p).read()
rep("""        ensures
            r ==> final(self).refines(p) && final(self).g@ == sp::push(old(self).g@, v),
            !r ==> *final(self) == *old(self),""", """        ensures
            r ==> final(self).refines(p) && final(self).g@ == sp::push(old(self).g@, v),
            r ==> final(self).top == old(self).top - 1 && final(self).addr() == old(self).addr(),
            !r ==> *final(self) == *old(self),""")
open(p, 'w').write(s)
p = root + '/verified/core/src/blocks.rs'
s = open(p).read()
rep("""            final(self).g@ == sp::drop(old(self).g@, n as int),
            final(self).top == old(self).top + n,
            final(self).ftop == old(self).ftop,""", """            final(self).g@ == sp::drop(old(self).g@, n as int),
            final(self).top == old(self).top + n,
            final(self).ftop == old(self).ftop,
            final(self).rtop == old(self).rtop,
            final(self).mem@ == old(self).mem@,
            final(self).addr() == old(self).addr(),""")
open(p, 'w').write(s)
