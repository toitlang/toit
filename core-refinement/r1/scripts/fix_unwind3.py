import sys
root = sys.argv[1]
p = root + '/verified/core/src/unwind.rs'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""                    assert(self.refines(p));
                    assert(self.refines(env.p));
                    assert(sp::has_handler(g));
                    assert(handler == handler_word(g.tries.last()));
                    assert(tries_ok(g));
                    assert(unw_rel(self.addr(), u, gu));
                    assert(resume_ok(sp::resume_of(gu)));
                    assert(self.g@ == g);""", """                    assert(self.g@ == g);""")
rep("""                !(o is Stuck),
                ap == p.ap@,""", """                !(o is Stuck),
                p == env.p,
                ap == p.ap@,""")
open(p, 'w').write(s)
