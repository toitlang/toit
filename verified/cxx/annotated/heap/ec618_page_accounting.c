// Copyright (C) 2026 Toit contributors.

// Checked in the same translation unit as the board's page status constants.
// The sentinel is excluded from the sequence of usable pages.
/*@
fixpoint int free_page_count(list<int> xs) {
    switch (xs) {
        case nil: return 0;
        case cons(x, rest): return (x == PAGE_FREE ? 1 : 0) + free_page_count(rest);
    }
}

fixpoint int free_page_runs(list<int> xs, bool previous_free) {
    switch (xs) {
        case nil: return 0;
        case cons(x, rest): return (x == PAGE_FREE && !previous_free ? 1 : 0) + free_page_runs(rest, x == PAGE_FREE);
    }
}

fixpoint bool last_page_free(list<int> xs, bool previous_free) {
    switch (xs) {
        case nil: return previous_free;
        case cons(x, rest): return last_page_free(rest, x == PAGE_FREE);
    }
}

fixpoint bool starts_free(list<int> xs) {
    switch (xs) {
        case nil: return false;
        case cons(x, rest): return x == PAGE_FREE;
    }
}

fixpoint bool all_pages_have_availability(list<int> xs, bool available) {
    switch (xs) {
        case nil: return true;
        case cons(x, rest): return (x == PAGE_FREE) == available && all_pages_have_availability(rest, available);
    }
}

lemma void count_concatenated_pages(list<int> prefix, list<int> suffix, bool prev)
    requires true;
    ensures free_page_count(append(prefix, suffix)) == free_page_count(prefix) + free_page_count(suffix) &*&
            free_page_runs(append(prefix, suffix), prev) ==
                free_page_runs(prefix, prev) + free_page_runs(suffix, last_page_free(prefix, prev));
{
    switch (prefix) {
        case nil:
        case cons(x, rest): count_concatenated_pages(rest, suffix, x == PAGE_FREE);
    }
}

lemma void count_uniform_pages(list<int> xs, bool available, bool prev)
    requires all_pages_have_availability(xs, available) == true;
    ensures free_page_count(xs) == (available ? length(xs) : 0) &*&
            free_page_runs(xs, prev) == (xs != nil && available && !prev ? 1 : 0) &*&
            last_page_free(xs, prev) == (xs == nil ? prev : available);
{
    switch (xs) {
        case nil:
        case cons(x, rest): count_uniform_pages(rest, available, available);
    }
}

predicate initial_page_tags(Page *table, int count) =
    count == 0 ? emp : table[count - 1].tag |-> 0 &*& initial_page_tags(table, count - 1);

lemma void uniform_append(list<int> xs, list<int> ys, bool available)
    requires all_pages_have_availability(xs, available) == true &*& all_pages_have_availability(ys, available) == true;
    ensures all_pages_have_availability(append(xs, ys), available) == true;
{
    switch (xs) { case nil: case cons(x, rest): uniform_append(rest, ys, available); }
}

// Convert the production initializer's reverse-indexed ownership into the
// forward status sequence used to count runs. The sentinel stays framed.
lemma void initialized_page_counts(Page *table, int n)
    requires 0 <= n &*& free_pages_prefix(table, n);
    ensures page_statuses(table, 0, n, ?xs) &*& initial_page_tags(table, n) &*&
            length(xs) == n &*& all_pages_have_availability(xs, true) == true &*&
            free_page_count(xs) == n &*& free_page_runs(xs, false) == (n == 0 ? 0 : 1);
{
    open free_pages_prefix(table, n);
    if (n == 0) {
        close page_statuses(table, 0, n, nil);
    } else {
        initialized_page_counts(table, n - 1);
        assert page_statuses(table, 0, n - 1, ?prefix);
        close page_statuses(table, n, n, nil);
        close page_statuses(table, n - 1, n, cons(PAGE_FREE, nil));
        join_statuses(table, 0, n - 1, n);
        uniform_append(prefix, cons(PAGE_FREE, nil), true);
    }
    close initial_page_tags(table, n);
    assert page_statuses(table, 0, n, ?values);
    status_count(table, 0, n);
    count_uniform_pages(values, true, false);
    switch (values) { case nil: case cons(h, t): }
}

// One registration followed by any finite sequence of allocations and frees.
// The status values of occupied heads and continuations may differ. Only their
// availability matters for these two counters.
inductive page_edit = page_edit(list<int> prefix, list<int> before, list<int> after, list<int> suffix, bool release);

fixpoint list<int> old_table(page_edit edit) {
    switch (edit) { case page_edit(prefix, before, after, suffix, release): return append(prefix, append(before, suffix)); }
}

fixpoint list<int> new_table(page_edit edit) {
    switch (edit) { case page_edit(prefix, before, after, suffix, release): return append(prefix, append(after, suffix)); }
}

fixpoint bool valid_page_edit(page_edit edit) {
    switch (edit) {
        case page_edit(prefix, before, after, suffix, release):
            return before != nil && length(before) == length(after) &&
                   all_pages_have_availability(before, !release) && all_pages_have_availability(after, release);
    }
}

fixpoint int page_byte_change(page_edit edit) {
    switch (edit) {
        case page_edit(prefix, before, after, suffix, release): return (release ? 1 : -1) * length(before) * PAGE_SIZE;
    }
}

fixpoint int page_run_change(page_edit edit) {
    switch (edit) {
        case page_edit(prefix, before, after, suffix, release):
            return (release ? 1 : -1) * (1 - (last_page_free(prefix, false) ? 1 : 0) - (starts_free(suffix) ? 1 : 0));
    }
}

lemma void count_page_edit(page_edit edit)
    requires valid_page_edit(edit) == true;
    ensures length(new_table(edit)) == length(old_table(edit)) &*&
            free_page_count(new_table(edit)) * PAGE_SIZE ==
                free_page_count(old_table(edit)) * PAGE_SIZE + page_byte_change(edit) &*&
            free_page_runs(new_table(edit), false) == free_page_runs(old_table(edit), false) + page_run_change(edit);
{
    switch (edit) {
        case page_edit(prefix, before, after, suffix, release):
            count_concatenated_pages(prefix, append(before, suffix), false);
            count_concatenated_pages(prefix, append(after, suffix), false);
            bool prev = last_page_free(prefix, false);
            count_concatenated_pages(before, suffix, prev);
            count_concatenated_pages(after, suffix, prev);
            count_uniform_pages(before, !release, prev);
            count_uniform_pages(after, release, prev);
            switch (before) { case nil: case cons(b, bs): }
            switch (after) { case nil: case cons(a, as0): }
            switch (suffix) { case nil: case cons(s, rest): }
    }
}

fixpoint bool valid_page_history(list<int> table, list<page_edit> edits) {
    switch (edits) {
        case nil: return true;
        case cons(e, es): return valid_page_edit(e) && old_table(e) == table && valid_page_history(new_table(e), es);
    }
}

fixpoint list<int> final_page_table(list<int> table, list<page_edit> edits) {
    switch (edits) {
        case nil: return table;
        case cons(e, es): return final_page_table(new_table(e), es);
    }
}

fixpoint int history_byte_change(list<page_edit> edits) {
    switch (edits) {
        case nil: return 0;
        case cons(e, es): return page_byte_change(e) + history_byte_change(es);
    }
}

fixpoint int history_run_change(list<page_edit> edits) {
    switch (edits) {
        case nil: return 0;
        case cons(e, es): return page_run_change(e) + history_run_change(es);
    }
}

lemma void count_page_history(list<int> table, list<page_edit> edits)
    requires valid_page_history(table, edits) == true;
    ensures length(final_page_table(table, edits)) == length(table) &*&
            free_page_count(final_page_table(table, edits)) * PAGE_SIZE ==
                free_page_count(table) * PAGE_SIZE + history_byte_change(edits) &*&
            free_page_runs(final_page_table(table, edits), false) == free_page_runs(table, false) + history_run_change(edits);
{
    switch (edits) {
        case nil:
        case cons(e, es):
            count_page_edit(e);
            count_page_history(new_table(e), es);
    }
}

lemma void page_count_bounds(list<int> xs, bool prev)
    requires true;
    ensures 0 <= free_page_runs(xs, prev) &*& free_page_runs(xs, prev) <= free_page_count(xs) &*&
            free_page_count(xs) <= length(xs);
{
    switch (xs) {
        case nil:
        case cons(x, rest): page_count_bounds(rest, x == PAGE_FREE);
    }
}

// In a registered region the page contribution itself always fits a word.
// Small-block capacity and counts are separate contributions to the same
// native counters and must have room alongside these values.
lemma void registered_page_history(list<int> initial, list<page_edit> edits)
    requires all_pages_have_availability(initial, true) == true &*& length(initial) <= SIZE_MAX / PAGE_SIZE &*&
             valid_page_history(initial, edits) == true;
    ensures length(initial) * PAGE_SIZE + history_byte_change(edits) ==
                free_page_count(final_page_table(initial, edits)) * PAGE_SIZE &*&
            (initial == nil ? 0 : 1) + history_run_change(edits) == free_page_runs(final_page_table(initial, edits), false) &*&
            0 <= free_page_runs(final_page_table(initial, edits), false) &*&
            free_page_runs(final_page_table(initial, edits), false) <= length(initial) &*&
            0 <= free_page_count(final_page_table(initial, edits)) * PAGE_SIZE &*&
            free_page_count(final_page_table(initial, edits)) * PAGE_SIZE <= SIZE_MAX;
{
    count_uniform_pages(initial, true, false);
    count_page_history(initial, edits);
    page_count_bounds(final_page_table(initial, edits), false);
}
@*/
