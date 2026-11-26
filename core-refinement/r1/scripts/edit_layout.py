import sys
p = sys.argv[1] + '/verified/layout_check.cc'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
rep("""  int stack_length_word, stack_top_word, stack_frame_top_word, stack_bci_word;
  { Fake f;
    Stack* s = static_cast<Stack*>(f.object());
    stack_length_word = marker_index(s->length());
    stack_top_word = marker_index(s->top());
    stack_frame_top_word = marker_index(s->v2_frame_top());
    stack_bci_word = marker_index(s->v2_bci());
  }
""", """  int stack_length_word, stack_top_word, stack_record_top_word, stack_bci_word;
  bool stack_records_ok;
  { Fake f;
    Stack* s = static_cast<Stack*>(f.object());
    stack_length_word = marker_index(s->length());
    stack_top_word = marker_index(s->top());
    stack_record_top_word = marker_index(s->v2_record_top());
    stack_bci_word = marker_index(s->v2_bci_word());
    // The core writes the record top and `bci | fins << STACK_FIN_COUNT_SHIFT`
    // (Machine::save); C++ must read them back the same way.
    f.words[stack_record_top_word] = 13 * Stack::V2_FRAME_WORDS + 3 * Stack::V2_FIN_WORDS;
    f.words[stack_bci_word] = 0x7654321 | (static_cast<uword>(3) << 32);
    stack_records_ok = s->v2_bci() == 0x7654321 && s->v2_fin_count() == 3 &&
        s->v2_frame_top() == 13 * Stack::V2_FRAME_WORDS &&
        s->v2_record_top() == 13 * Stack::V2_FRAME_WORDS + 3 * Stack::V2_FIN_WORDS;
    s->v2_set_records(5 * Stack::V2_FRAME_WORDS, 2, 77);
    stack_records_ok = stack_records_ok &&
        f.words[stack_record_top_word] == 5 * Stack::V2_FRAME_WORDS + 2 * Stack::V2_FIN_WORDS &&
        f.words[stack_bci_word] == (77 | (static_cast<uword>(2) << 32));
  }
""")
rep("""    { "STACK_FRAME_TOP_WORD", static_cast<uword>(stack_frame_top_word), false },
    { "STACK_BCI_WORD", static_cast<uword>(stack_bci_word), false },""", """    { "STACK_RECORD_TOP_WORD", static_cast<uword>(stack_record_top_word), false },
    { "STACK_BCI_WORD", static_cast<uword>(stack_bci_word), false },
    { "STACK_FIN_COUNT_SHIFT", static_cast<uword>(Stack::V2_FIN_COUNT_SHIFT), false },""")
rep("""    { "STACK_RESERVE", static_cast<uword>(Stack::V2_STACK_RESERVE), false },""", """    { "STACK_RESERVE", static_cast<uword>(Stack::V2_STACK_RESERVE), false },
    { "FIN_WORDS", static_cast<uword>(Stack::V2_FIN_WORDS), false },
    { "FIN_FRAME", static_cast<uword>(Stack::V2_FIN_FRAME), false },
    { "FIN_HEIGHT", static_cast<uword>(Stack::V2_FIN_HEIGHT), false },
    { "FIN_RESUME", static_cast<uword>(Stack::V2_FIN_RESUME), false },
    { "FIN_TARGET", static_cast<uword>(Stack::V2_FIN_TARGET), false },""")
rep("""  if (sizeof(std::atomic<Object**>) != sizeof(uword)) {""", """  if (!stack_records_ok) {
    printf("FAIL: Stack record top, finally-record count and bci encoding\\n");
    failures++;
  }
  if (sizeof(std::atomic<Object**>) != sizeof(uword)) {""")
open(p, 'w').write(s)
