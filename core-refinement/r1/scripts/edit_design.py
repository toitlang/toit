import sys
p = sys.argv[1] + '/verified/core/DESIGN.md'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""- On entry the current task's Stack object holds the task state (object
  stack, frame records, top, frame top, bci); on return it holds the""",
"""- On entry the current task's Stack object holds the task state (object
  stack, frame and finally records, top, record top, bci and the number
  of finally records); on return it holds the""")
rep("""```
array index:  0 .............. ftop        top ................. len-1
              [ frame records ][   free   ][ object stack, top first ]
```
""", """```
array index:  0 ........... ftop ........ rtop        top ............. len-1
              [ frame records ][ finally rec. ][  free  ][ object stack, top first ]
```
""")
rep("""- Frame records: `array[0..ftop)`, growing up, 4 words each (method
  index, return bci, base = object-stack position of the first argument,
  handler = 0 or `height | bci << 32` of the frame's TRY). No object
  references, so the GC never looks at them. The Stack header's try-top
  word holds `ftop`, the pending-stack-check word the bci.
- Room: before every call the core requires
  `FRAME_WORDS + global_max_height + STACK_RESERVE` free words between the
  two stacks and otherwise grows the stack (`toit_v2_grow_stack`: a new,
  larger Stack, frames copied to the bottom and the object stack to the
  top). Growth past `Stack::max_length()` throws `STACK_OVERFLOW`.
- Shrinking (GC, `Stack::roots_do`) moves the object stack down and keeps
  the frame records and the reserve.""", """- Frame records: `array[0..ftop)`, growing up, 4 words each (method
  index, return bci, base = object-stack position of the first argument,
  handler = 0 or `height | bci << 32` of the frame's TRY), frame `fi` at
  `4 * fi` (block references and C++ rely on that).
- Finally records (format note 17, `State2.fins`): `array[ftop..rtop)`,
  right after the frame records, 4 words each: the frame running the
  finally code, the height of its three slots, the resumed unwinding
  (`kind + 4 * frame`: kind 0 throw, 1 return, 2 branch) and the branch
  target (`bci | height << 32`, else 0). The token slot of the finally code
  holds the smi index of its record. Entering finally code with an
  unwinding writes a record at `rtop` (the handler word is cleared as for a
  normal completion); UNWIND checks record `k` (`fin_matches`) and sets
  `rtop` to it; TRY drops the frame's stale records (`cut_fins`). A call
  moves the records up by one frame record (`memmove`, only when there are
  records: during an unwinding's finally code); a return, an unwinding
  that pops a frame and a tail call drop the popped frame's records (they
  are last, `fins_popped`) and a return or pop moves the rest down by one
  frame record. Records are 4 words although three would do (frame and
  height fit one word): the same size as a frame record keeps a call's
  move and every index computation a shift, and the records are rare.
- Records hold no object references (the value of a pending exception or
  non-local return is the finally code's first slot), so the GC never
  looks at them. The Stack header's try-top word holds the record top
  `rtop`, the pending-stack-check word `bci | fins << 32` (`fins`: the
  number of finally records, `ftop = rtop - 4 * fins`). Holding the record
  top (not the frame top) in the header lets every C++ path that copies or
  shrinks a stack keep `[0, try-top)` without knowing about finally
  records; C++ reads the frame top through `Stack::v2_frame_top()`.
  Alternatives: a separate header word (changes format 1's Stack layout
  and every stack's size), the count in the high half of the try-top word
  (same packing, but `try_top()` is shared with format 1's code), records
  in the frame records themselves (one per frame: unsound for try/finally
  inside finally code, note 17).
- Room: before every call the core requires
  `FRAME_WORDS + global_max_height + STACK_RESERVE` free words between the
  records and the object stack and otherwise grows the stack
  (`toit_v2_grow_stack`: a new, larger Stack, records copied to the bottom
  and the object stack to the top). Growth past `Stack::max_length()`
  throws `STACK_OVERFLOW`. Entering finally code with an unwinding needs
  the record and three slots; the popped try-block frame freed its frame
  record and argument, and the reserve covers the rest (the run-time check
  stops with `LIMIT` otherwise).
- Shrinking (GC, `Stack::roots_do`) moves the object stack down and keeps
  the records and the reserve.
- Task switches: a suspended task's records stay in its Stack object (the
  core saves `rtop` and the count before the `task_transfer` primitive and
  reloads them from the new current task); a new task starts with none.""")
rep("""bci into the Stack object (`Machine::save`), after each it re-derives all
cached state from the current task's stack (`Machine::reload`, which also
re-checks top, frame top and length).""", """bci with the number of finally records into the Stack object
(`Machine::save`), after each it re-derives all cached state from the
current task's stack (`Machine::reload`, which also re-checks top, record
top, the finally-record count and length).""")
rep("""| `toit_v2_grow_stack(process, needed)` | yes | state saved | OK, STACK_OVERFLOW or OUT_OF_MEMORY; on OK the task has a new stack with `needed` free words |""",
"""| `toit_v2_grow_stack(process, needed)` | yes | state saved (record top and finally-record count included) | OK, STACK_OVERFLOW or OUT_OF_MEMORY; on OK the task has a new stack with the frame and finally records copied and `needed` free words above them |""")
rep("""| `toit_v2_call_primitive(process, entry, arity, first, &result)` | yes, may switch task | `entry` came from lookup; `arity` equals the primitive's arity and the method's; the arguments are object-stack positions `first..first+arity` of the current frame; state saved | SUCCESS (result), FAILURE (error value, pushed) or THROW (raise it) |""",
"""| `toit_v2_call_primitive(process, entry, arity, first, &result)` | yes, may switch task | `entry` came from lookup; `arity` equals the primitive's arity and the method's; the arguments are object-stack positions `first..first+arity` of the current frame; state saved | SUCCESS (result), FAILURE (error value, pushed) or THROW (raise it); after a task switch the new task's Stack holds its records (none for a new task) |""")
open(p, 'w').write(s)
