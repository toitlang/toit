// Copyright (C) 2026 Toit contributors.

// Model a page resize under the heap lock. The intermediate all-free
// interval is a proof device; the native path publishes only the final view.
/*@
lemma void equal_free_extents(list<int> xs, list<int> ys)
    requires all_status(xs, PAGE_FREE) == true &*& all_status(ys, PAGE_FREE) == true &*& length(xs) == length(ys);
    ensures xs == ys;
{
    switch (xs) {
        case nil: switch (ys) { case nil: case cons(y, yt): }
        case cons(x, xt):
            switch (ys) { case nil: case cons(y, yt): equal_free_extents(xt, yt); }
    }
}

lemma void concatenate_free_extents(list<int> xs, list<int> ys)
    requires all_status(xs, PAGE_FREE) == true &*& all_status(ys, PAGE_FREE) == true;
    ensures all_status(append(xs, ys), PAGE_FREE) == true;
{
    switch (xs) { case nil: case cons(x, rest): concatenate_free_extents(rest, ys); }
}

lemma void decode_complete_extent(list<int> continuations, list<int> suffix)
    requires all_status(continuations, PAGE_CONTINUED) == true &*& continuation_count(suffix) == 0;
    ensures continuation_prefix(append(continuations, suffix)) == continuations &*&
            following_pages(append(continuations, suffix)) == suffix;
{
    switch (continuations) {
        case nil:
            switch (suffix) { case nil: case cons(x, rest): continuation_bounds(rest); }
        case cons(x, rest): decode_complete_extent(rest, suffix);
    }
}

fixpoint list<page_operation> resize_operations(list<int> prefix, list<int> left, list<int> tail, list<int> right,
                                               list<int> suffix, list<int> new_left, list<int> new_run, list<int> new_right) {
    return cons(return_extent(append(prefix, left), PAGE_IN_USE, append(tail, append(right, suffix))),
                cons(reserve_extent(append(prefix, new_left), new_run, append(new_right, suffix), PAGE_IN_USE), nil));
}

// A direct run surrounded by available pages can be placed anywhere within
// their union that the selector permits. The free padding on either side of
// the new run may be empty. No other live allocation uses these pages.
lemma void admit_page_resize(list<int> prefix, list<int> left, list<int> tail, list<int> right, list<int> suffix,
                             list<int> new_left, list<int> new_run, list<int> new_right, int probe)
    requires all_status(left, PAGE_FREE) == true &*& all_status(tail, PAGE_CONTINUED) == true &*&
             all_status(right, PAGE_FREE) == true &*& continuation_count(append(right, suffix)) == 0 &*&
             all_status(new_left, PAGE_FREE) == true &*& all_status(new_run, PAGE_FREE) == true &*&
             all_status(new_right, PAGE_FREE) == true &*& new_run != nil &*&
             length(left) + 1 + length(tail) + length(right) == length(new_left) + length(new_run) + length(new_right) &*&
             well_formed_pages(append(append(prefix, left), cons(PAGE_IN_USE, append(tail, append(right, suffix)))), false) == true &*&
             0 <= probe;
    ensures admitted_operations(append(append(prefix, left), cons(PAGE_IN_USE, append(tail, append(right, suffix)))),
                                resize_operations(prefix, left, tail, right, suffix, new_left, new_run, new_right)) == true &*&
            well_formed_pages(append(append(prefix, new_left), cons(PAGE_IN_USE,
                                  append(filled_statuses(tail(new_run), PAGE_CONTINUED), append(new_right, suffix)))), false) == true &*&
            allocation_at(append(append(prefix, new_left), cons(PAGE_IN_USE, append(filled_statuses(tail(new_run), PAGE_CONTINUED),
                          append(new_right, suffix)))), probe) ==
                (probe == length(prefix) + length(new_left) ? allocated_pages(PAGE_IN_USE, length(new_run)) :
                 probe == length(prefix) + length(left) ? absent_page_head :
                 allocation_at(append(append(prefix, left), cons(PAGE_IN_USE, append(tail, append(right, suffix)))), probe));
{
    list<int> beyond = append(right, suffix);
    decode_complete_extent(tail, beyond);
    list<int> cleared = cons(PAGE_FREE, filled_statuses(tail, PAGE_FREE));
    status_fill_shape(tail, PAGE_FREE);
    concatenate_free_extents(cleared, right);
    concatenate_free_extents(left, append(cleared, right));
    concatenate_free_extents(new_run, new_right);
    concatenate_free_extents(new_left, append(new_run, new_right));
    equal_free_extents(append(left, append(cleared, right)), append(new_left, append(new_run, new_right)));
    append_assoc(cleared, right, suffix);
    append_assoc(left, append(cleared, right), suffix);
    append_assoc(prefix, left, append(cleared, beyond));
    append_assoc(new_run, new_right, suffix);
    append_assoc(new_left, append(new_run, new_right), suffix);
    append_assoc(prefix, new_left, append(new_run, append(new_right, suffix)));
    list<int> table = append(append(prefix, left), cons(PAGE_IN_USE, append(tail, beyond)));
    extent_history(table, resize_operations(prefix, left, tail, right, suffix, new_left, new_run, new_right), probe);
}

lemma void last_free_after_append(list<int> prefix, list<int> suffix, bool prev)
    requires true;
    ensures last_page_free(append(prefix, suffix), prev) == last_page_free(suffix, last_page_free(prefix, prev));
{
    switch (prefix) { case nil: case cons(x, rest): last_free_after_append(rest, suffix, x == PAGE_FREE); }
}

lemma void adjacent_free_runs(list<int> prefix, list<int> left, list<int> right, list<int> suffix)
    requires last_page_free(prefix, false) == false &*& starts_free(suffix) == false &*&
             all_status(left, PAGE_FREE) == true &*& all_status(right, PAGE_FREE) == true;
    ensures last_page_free(append(prefix, left), false) == (left != nil) &*& starts_free(append(right, suffix)) == (right != nil);
{
    last_free_after_append(prefix, left, false);
    uniform_status_availability(left, PAGE_FREE);
    count_uniform_pages(left, true, false);
    switch (right) { case nil: case cons(x, rest): }
}

// With maximal neighboring free extents, these are the same two residual
// lengths used to check the native byte and run counters.
lemma void resize_counter_deltas(list<int> prefix, list<int> left, list<int> tail, list<int> right, list<int> suffix,
                                 list<int> new_left, list<int> new_run, list<int> new_right)
    requires last_page_free(prefix, false) == false &*& starts_free(suffix) == false &*&
             all_status(left, PAGE_FREE) == true &*& all_status(right, PAGE_FREE) == true &*&
             all_status(new_left, PAGE_FREE) == true &*& all_status(new_right, PAGE_FREE) == true &*&
             all_status(tail, PAGE_CONTINUED) == true &*& continuation_count(append(right, suffix)) == 0 &*&
             length(left) + 1 + length(tail) + length(right) == length(new_left) + length(new_run) + length(new_right);
    ensures history_byte_change(extent_edits(resize_operations(prefix, left, tail, right, suffix, new_left, new_run, new_right))) ==
                (length(new_left) + length(new_right) - length(left) - length(right)) * PAGE_SIZE &*&
            history_run_change(extent_edits(resize_operations(prefix, left, tail, right, suffix, new_left, new_run, new_right))) ==
                (new_left != nil ? 1 : 0) + (new_right != nil ? 1 : 0) - (left != nil ? 1 : 0) - (right != nil ? 1 : 0);
{
    decode_complete_extent(tail, append(right, suffix));
    adjacent_free_runs(prefix, left, right, suffix);
    adjacent_free_runs(prefix, new_left, new_right, suffix);
}

// Append the resize's two logical events to an admitted history. The
// concrete heap remains locked throughout the native transition.
lemma void append_extent_operations(list<int> table, list<page_operation> history, list<page_operation> next)
    requires admitted_operations(table, history) == true &*&
             admitted_operations(final_page_table(table, extent_edits(history)), next) == true;
    ensures admitted_operations(table, append(history, next)) == true &*&
            final_page_table(table, extent_edits(append(history, next))) ==
                final_page_table(final_page_table(table, extent_edits(history)), extent_edits(next));
{
    switch (history) {
        case nil:
        case cons(op, rest): append_extent_operations(new_table(extent_edit(op)), rest, next);
    }
}
@*/
