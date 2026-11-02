import random,sys
VALUES=['1','"s"','3.5','true','null']
class G:
  def __init__(s,seed):
    s.r=random.Random(seed); s.n=0; s.methods=[]
  def val(s):
    c=s.r.random()
    if c<.65: return s.r.choice(VALUES)
    return s.r.choice(['x','y'])
  def tag(s):
    s.n+=1; return s.n
  def stmt(s,d,loop,labels,fin):
    i='  '*d; r=s.r
    opts=['store']*5+['trace']*3+['cond']*2
    if d<8:
      opts+=['if','if','try','try','tryp','run','runtry','two','twofin','stop','catch','while','while','block']
    if loop: opts+=['break','continue','continue']
    if labels: opts+=['label']*2
    opts+=['return','throw']
    k=r.choice(opts)
    B=lambda dd,l=loop,lb=labels,f=fin: s.body(dd,l,lb,f)
    if k=='store': return [f"{i}{r.choice('xy')} = {s.val()}"]
    if k=='trace': return [f"{i}trace {s.tag()} {r.choice('xy')}"]
    if k=='cond': v=r.choice('xy'); ty=r.choice(['string','int','float','bool']); return [f"{i}if {v} is {ty}: trace {s.tag()} {v}",f"{i}else: trace {s.tag()} {v}"]
    if k=='if': return [f"{i}if pick:"]+B(d+1)+[f"{i}else:"]+B(d+1)
    if k=='try': return [f"{i}try:"]+B(d+1)+[f"{i}finally:"]+B(d+1,f=True)
    if k=='tryp': return [f"{i}try:"]+B(d+1)+[f"{i}finally: | t e |",f"{i}  trace {s.tag()} t"]+B(d+1,f=True)
    if k=='run': return [f"{i}run:"]+B(d+1,lb=labels+['run'])
    if k=='runtry': return [f"{i}run-try:"]+B(d+1,lb=labels+['run-try'])
    if k=='stop': return [f"{i}stop:"]+B(d+1,lb=labels+['stop'])
    if k=='catch': return [f"{i}catch:"]+B(d+1,lb=labels)
    if k=='two': return [f"{i}two"]+[f"{i}  : {''}"[:0]] if False else s.two('two',d,loop,labels)
    if k=='twofin': return s.two('two-fin',d,loop,labels)
    if k=='block': return [f"{i}blk{(t:=s.tag())} := :"]+B(d+1,l=loop,lb=[])+[f"{i}if pick: blk{t}.call"]+[f"{i}trace {s.tag()} x"]
    if k=='while': return [f"{i}while budget:"]+B(d+1,l=True)
    if k=='break': return [f"{i}if pick: break"]
    if k=='continue': return [f"{i}if pick: continue"]
    if k=='label': return [f"{i}if pick: continue.{r.choice(labels)}"]
    if k=='return': return [f"{i}if pick: return"]
    if k=='throw': return [f"{i}if pick: throw \"t\""]
  def two(s,name,d,loop,labels):
    i='  '*d; t=[f"{i}{name}"]
    def inline(body):
      return [f"{i}  --a=(:" ] 
    # Use local blocks so both can hold statements.
    a=s.tag(); b=s.tag()
    out=[f"{i}a{a} := :"]+s.body(d+1,loop,[],False)+[f"{i}b{b} := :"]+s.body(d+1,loop,[],False)
    out+=[f"{i}{name} a{a} b{b}"]
    return out
  def body(s,d,loop,labels,fin):
    out=[]
    n=s.r.randint(1,3) if d>2 else s.r.randint(2,5)
    for _ in range(n): out+=s.stmt(d,loop,labels,fin)
    return out
  def program(s,count):
    p=['''import expect show *
tick_ := 0
rnd_ := %d
budget_ := 40
pick:
  rnd_ = (rnd_ * 1103515245 + 12345) & 0x7fffffff
  return (rnd_ >> 16) & 3 != 0
budget:
  budget_--
  return budget_ > 0
trace tag v:
  name := v is string ? "s" : v is int ? "i" : v is float ? "f" : v == null ? "n" : v == true ? "t" : v == false ? "F" : "?"
  print "$tag:$name"
run [b]: b.call
run-try [b]:
  try:
    b.call
  finally:
    tick_++
stop [b]:
  try:
    b.call
  finally:
    if pick: return
two [a] [b]:
  try:
    a.call
    b.call
  finally:
    tick_++
two-fin [a] [b]:
  try:
    a.call
  finally:
    b.call
''' % s.r.randint(1,1<<30)]
    for m in range(count):
      x,y=s.r.choice(VALUES),s.r.choice(VALUES)
      p.append(f"m{m}:\n  x/any := {x}\n  y/any := {y}")
      p+=s.body(1,False,[],False)
      p.append(f"  trace {s.tag()} x\n  trace {s.tag()} y\n")
    p.append("main:")
    for m in range(count):
      p.append(f"  catch: m{m}\n  budget_ = 40")
    return "\n".join(p)+"\n"
if __name__=="__main__":
  open(sys.argv[2],'w').write(G(int(sys.argv[1])).program(4))
