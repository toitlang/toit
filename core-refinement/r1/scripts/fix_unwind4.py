import sys
root = sys.argv[1]
p = root + '/verified/core/src/unwind.rs'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""        forall|x: int| 0 <= x < tries.len() ==> (#[trigger] tries[x]).frame + 1 < frames.len(),
        h.frame == frames.len() - 1,""", """        forall|x: int| 0 <= x < tries.len() ==> (#[trigger] tries[x]).frame + 1 < frames.len(),
        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
        h.frame == frames.len() - 1,""")
rep("""    let n = frames.len() as int;
    let t2 = tries.push(h);
""", """    let n = frames.len() as int;
    let t2 = tries.push(h);
    lemma_tries_len(tries, n - 1);
""")
rep("""                !(o is Stuck),
                p == env.p,""", """                !(o is Stuck),
                o == sp::unwind(ap, old(self).g@, gu),
                p == env.p,""")
open(p, 'w').write(s)
