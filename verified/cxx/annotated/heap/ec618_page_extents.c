// Copyright (C) 2026 Toit contributors.

// Status words encode a head kind followed by zero or more continuations.
// The implicit terminating entry after the usable sequence is PAGE_IN_USE.
/*@
fixpoint bool page_is_head(int x) { return x == PAGE_IN_USE || x == PAGE_IN_USE_FOR_MALLOCS; }

fixpoint bool well_formed_pages(list<int> xs, bool follows_allocation) {
    switch (xs) {
        case nil: return true;
        case cons(x, rest): return (x == PAGE_FREE || page_is_head(x) || (x == PAGE_CONTINUED && follows_allocation)) &&
                                    well_formed_pages(rest, x != PAGE_FREE);
    }
}

fixpoint bool all_status(list<int> xs, int status) {
    switch (xs) { case nil: return true; case cons(x, t): return x == status && all_status(t, status); }
}

inductive page_allocation = absent_page_head | allocated_pages(int kind, int pages);
fixpoint page_allocation allocation_at(list<int> xs, int index) {
    switch (xs) {
        case nil: return absent_page_head;
        case cons(x, t): return index == 0 ?
            (page_is_head(x) ? allocated_pages(x, 1 + continuation_count(t)) : absent_page_head) :
            allocation_at(t, index - 1);
    }
}

lemma void count_contiguous_tail(list<int> run, list<int> rest)
    requires all_status(run, PAGE_CONTINUED) == true &*& continuation_count(rest) == 0;
    ensures continuation_count(append(run, rest)) == length(run);
{
    switch (run) { case nil: case cons(x, t): count_contiguous_tail(t, rest); }
}

lemma void no_heads_in_extent(list<int> run, list<int> rest, int index, int status)
    requires all_status(run, status) == true &*& page_is_head(status) == false &*& index >= 0;
    ensures allocation_at(append(run, rest), index) ==
        (index < length(run) ? absent_page_head : allocation_at(rest, index - length(run)));
{
    switch (run) { case nil: case cons(x, t): if (index != 0) no_heads_in_extent(t, rest, index - 1, status); }
}

lemma void same_continuations_after_prefix(list<int> prefix, list<int> a, list<int> b)
    requires continuation_count(a) == continuation_count(b);
    ensures continuation_count(append(prefix, a)) == continuation_count(append(prefix, b));
{
    switch (prefix) { case nil: case cons(x, t): same_continuations_after_prefix(t, a, b); }
}

lemma void head_before_edit(list<int> prefix, list<int> a, list<int> b, int index)
    requires 0 <= index &*& index < length(prefix) &*& continuation_count(a) == continuation_count(b);
    ensures allocation_at(append(prefix, a), index) == allocation_at(append(prefix, b), index);
{
    switch (prefix) {
        case nil:
        case cons(x, t):
            if (index == 0) same_continuations_after_prefix(t, a, b);
            else head_before_edit(t, a, b, index - 1);
    }
}

lemma void head_after_prefix(list<int> prefix, list<int> suffix, int index)
    requires length(prefix) <= index;
    ensures allocation_at(append(prefix, suffix), index) == allocation_at(suffix, index - length(prefix));
{
    switch (prefix) { case nil: case cons(x, t): head_after_prefix(t, suffix, index - 1); }
}

lemma void uniform_status_availability(list<int> xs, int status)
    requires all_status(xs, status) == true;
    ensures all_pages_have_availability(xs, status == PAGE_FREE) == true;
{
    switch (xs) { case nil: case cons(x, t): uniform_status_availability(t, status); }
}

// Both views contain the same neighboring descriptors. This relation is
// symmetric, so the same lemma describes publishing and releasing a head.
lemma void replace_page_head(list<int> prefix, list<int> vacant, int kind, list<int> tail, list<int> suffix, int probe)
    requires probe >= 0 &*& all_status(vacant, PAGE_FREE) == true &*& page_is_head(kind) == true &*&
             all_status(tail, PAGE_CONTINUED) == true &*& length(vacant) == 1 + length(tail) &*&
             continuation_count(suffix) == 0;
    ensures allocation_at(append(prefix, append(vacant, suffix)), length(prefix)) == absent_page_head &*&
            allocation_at(append(prefix, cons(kind, append(tail, suffix))), length(prefix)) == allocated_pages(kind, length(vacant)) &*&
            (probe == length(prefix) ? true :
                allocation_at(append(prefix, append(vacant, suffix)), probe) ==
                allocation_at(append(prefix, cons(kind, append(tail, suffix))), probe)) &*&
            valid_page_edit(page_edit(prefix, vacant, cons(kind, tail), suffix, false)) == true &*&
            valid_page_edit(page_edit(prefix, cons(kind, tail), vacant, suffix, true)) == true;
{
    switch (vacant) { case nil: case cons(x, t): }
    count_contiguous_tail(tail, suffix);
    uniform_status_availability(vacant, PAGE_FREE);
    uniform_status_availability(tail, PAGE_CONTINUED);
    head_after_prefix(prefix, append(vacant, suffix), length(prefix));
    head_after_prefix(prefix, cons(kind, append(tail, suffix)), length(prefix));
    if (probe < length(prefix)) {
        head_before_edit(prefix, append(vacant, suffix), cons(kind, append(tail, suffix)), probe);
    } else if (probe > length(prefix)) {
        head_after_prefix(prefix, append(vacant, suffix), probe);
        head_after_prefix(prefix, cons(kind, append(tail, suffix)), probe);
        no_heads_in_extent(vacant, suffix, probe - length(prefix), PAGE_FREE);
        no_heads_in_extent(tail, suffix, probe - length(prefix) - 1, PAGE_CONTINUED);
    }
}

lemma void formed_append(list<int> prefix, list<int> suffix, bool prev)
    requires true;
    ensures well_formed_pages(append(prefix, suffix), prev) ==
                (well_formed_pages(prefix, prev) && well_formed_pages(suffix, !last_page_free(prefix, !prev)));
{
    switch (prefix) { case nil: case cons(x, t): formed_append(t, suffix, x != PAGE_FREE); }
}

lemma void uniform_formed(list<int> run, int status, bool prev)
    requires all_status(run, status) == true &*& (status == PAGE_FREE || (status == PAGE_CONTINUED && prev));
    ensures well_formed_pages(run, prev) == true;
{
    switch (run) { case nil: case cons(x, t): uniform_formed(t, status, status != PAGE_FREE); }
}

lemma void free_table_is_formed(list<int> xs)
    requires all_pages_have_availability(xs, true) == true;
    ensures well_formed_pages(xs, false) == true;
{
    switch (xs) { case nil: case cons(x, t): free_table_is_formed(t); }
}

lemma void continuation_bounds(list<int> xs)
    requires true;
    ensures 0 <= continuation_count(xs) &*& continuation_count(xs) <= length(xs);
{
    switch (xs) { case nil: case cons(x, t): continuation_bounds(t); }
}

// A continuation cannot follow a vacant page in a well-formed input table.
// On release the scanner stops at a non-continuation or the table boundary.
lemma void extent_boundary(list<int> prefix, list<int> vacant, int kind, list<int> tail, list<int> suffix)
    requires all_status(vacant, PAGE_FREE) == true &*& vacant != nil &*& page_is_head(kind) == true &*&
             all_status(tail, PAGE_CONTINUED) == true;
    ensures (well_formed_pages(append(prefix, append(vacant, suffix)), false) ?
                continuation_count(suffix) == 0 : true) &*&
            (continuation_count(suffix) == 0 ?
                well_formed_pages(append(prefix, append(vacant, suffix)), false) ==
                well_formed_pages(append(prefix, cons(kind, append(tail, suffix))), false) : true);
{
    bool prev = !last_page_free(prefix, true);
    formed_append(prefix, append(vacant, suffix), false);
    formed_append(prefix, cons(kind, append(tail, suffix)), false);
    formed_append(vacant, suffix, prev);
    formed_append(tail, suffix, true);
    uniform_formed(vacant, PAGE_FREE, prev);
    uniform_formed(tail, PAGE_CONTINUED, true);
    uniform_status_availability(vacant, PAGE_FREE);
    uniform_status_availability(tail, PAGE_CONTINUED);
    count_uniform_pages(vacant, true, !prev);
    count_uniform_pages(tail, false, false);
    switch (suffix) { case nil: case cons(x, rest): continuation_bounds(rest); }
}

lemma void decode_tail(list<int> xs)
    requires true;
    ensures append(continuation_prefix(xs), following_pages(xs)) == xs &*&
            all_status(continuation_prefix(xs), PAGE_CONTINUED) == true &*&
            length(continuation_prefix(xs)) == continuation_count(xs) &*& continuation_count(following_pages(xs)) == 0;
{
    switch (xs) { case nil: case cons(x, t): if (x == PAGE_CONTINUED) decode_tail(t); }
}

// The input comes from a matching head and the descriptors following it.
// The release boundary and extent length are derived from those descriptors.
lemma void decoded_release(list<int> prefix, int kind, list<int> remaining, list<int> vacant, int probe)
    requires page_is_head(kind) == true &*& well_formed_pages(append(prefix, cons(kind, remaining)), false) == true &*&
             all_status(vacant, PAGE_FREE) == true &*& length(vacant) == 1 + continuation_count(remaining) &*& 0 <= probe;
    ensures well_formed_pages(append(prefix, append(vacant, following_pages(remaining))), false) == true &*&
            allocation_at(append(prefix, cons(kind, remaining)), length(prefix)) == allocated_pages(kind, length(vacant)) &*&
            allocation_at(append(prefix, append(vacant, following_pages(remaining))), length(prefix)) == absent_page_head &*&
            (probe == length(prefix) ? true :
                allocation_at(append(prefix, cons(kind, remaining)), probe) ==
                allocation_at(append(prefix, append(vacant, following_pages(remaining))), probe)) &*&
            valid_page_edit(page_edit(prefix, cons(kind, continuation_prefix(remaining)), vacant, following_pages(remaining), true)) == true;
{
    decode_tail(remaining);
    count_contiguous_tail(continuation_prefix(remaining), following_pages(remaining));
    switch (vacant) { case nil: case cons(x, t): }
    extent_boundary(prefix, vacant, kind, continuation_prefix(remaining), following_pages(remaining));
    replace_page_head(prefix, vacant, kind, continuation_prefix(remaining), following_pages(remaining), probe);
}

lemma void publish_page_head(list<int> prefix, list<int> vacant, int kind, list<int> tail, list<int> suffix, int probe)
    requires well_formed_pages(append(prefix, append(vacant, suffix)), false) == true &*& probe >= 0 &*&
             all_status(vacant, PAGE_FREE) == true &*& page_is_head(kind) == true &*&
             all_status(tail, PAGE_CONTINUED) == true &*& length(vacant) == 1 + length(tail);
    ensures well_formed_pages(append(prefix, cons(kind, append(tail, suffix))), false) == true &*&
            allocation_at(append(prefix, cons(kind, append(tail, suffix))), length(prefix)) == allocated_pages(kind, length(vacant)) &*&
            (probe == length(prefix) ? true :
                allocation_at(append(prefix, append(vacant, suffix)), probe) ==
                allocation_at(append(prefix, cons(kind, append(tail, suffix))), probe)) &*&
            valid_page_edit(page_edit(prefix, vacant, cons(kind, tail), suffix, false)) == true;
{
    switch (vacant) { case nil: case cons(x, t): }
    extent_boundary(prefix, vacant, kind, tail, suffix);
    replace_page_head(prefix, vacant, kind, tail, suffix, probe);
}

lemma void status_fill_shape(list<int> xs, int value)
    requires true;
    ensures all_status(filled_statuses(xs, value), value) == true &*& length(filled_statuses(xs, value)) == length(xs);
{
    switch (xs) { case nil: case cons(x, rest): status_fill_shape(rest, value); }
}

inductive page_operation =
    reserve_extent(list<int> prefix, list<int> vacant, list<int> suffix, int kind)
  | return_extent(list<int> prefix, int kind, list<int> remaining);

fixpoint page_edit extent_edit(page_operation op) {
    switch (op) {
        case reserve_extent(prefix, vacant, suffix, kind):
            return page_edit(prefix, vacant, cons(kind, filled_statuses(tail(vacant), PAGE_CONTINUED)), suffix, false);
        case return_extent(prefix, kind, remaining):
            return page_edit(prefix, cons(kind, continuation_prefix(remaining)),
                             cons(PAGE_FREE, filled_statuses(continuation_prefix(remaining), PAGE_FREE)), following_pages(remaining), true);
    }
}

// On release, the required input is a matching head. The caller supplies
// neither a run length nor an assumption about where the next head lies.
fixpoint bool admitted_extent(list<int> table, page_operation op) {
    switch (op) {
        case reserve_extent(prefix, vacant, suffix, kind):
            return table == append(prefix, append(vacant, suffix)) && page_is_head(kind) &&
                   vacant != nil && all_status(vacant, PAGE_FREE);
        case return_extent(prefix, kind, remaining):
            return page_is_head(kind) && table == append(prefix, cons(kind, remaining));
    }
}

fixpoint page_allocation updated_head(page_operation op, int probe, page_allocation old) {
    switch (op) {
        case reserve_extent(prefix, vacant, suffix, kind):
            return probe == length(prefix) ? allocated_pages(kind, length(vacant)) : old;
        case return_extent(prefix, kind, remaining):
            return probe == length(prefix) ? absent_page_head : old;
    }
}

lemma void extent_step(list<int> table, page_operation op, int probe)
    requires admitted_extent(table, op) == true &*& well_formed_pages(table, false) == true &*& probe >= 0;
    ensures old_table(extent_edit(op)) == table &*& valid_page_edit(extent_edit(op)) == true &*&
            well_formed_pages(new_table(extent_edit(op)), false) == true &*&
            allocation_at(new_table(extent_edit(op)), probe) == updated_head(op, probe, allocation_at(table, probe));
{
    switch (op) {
        case reserve_extent(prefix, vacant, suffix, kind):
            switch (vacant) {
                case nil:
                case cons(x, rest):
                    status_fill_shape(rest, PAGE_CONTINUED);
                    publish_page_head(prefix, vacant, kind, filled_statuses(rest, PAGE_CONTINUED), suffix, probe);
            }
        case return_extent(prefix, kind, remaining):
            decode_tail(remaining);
            list<int> tail = continuation_prefix(remaining);
            status_fill_shape(tail, PAGE_FREE);
            decoded_release(prefix, kind, remaining, cons(PAGE_FREE, filled_statuses(tail, PAGE_FREE)), probe);
    }
}

fixpoint list<page_edit> extent_edits(list<page_operation> ops) {
    switch (ops) { case nil: return nil; case cons(op, rest): return cons(extent_edit(op), extent_edits(rest)); }
}

fixpoint bool admitted_operations(list<int> table, list<page_operation> ops) {
    switch (ops) {
        case nil: return true;
        case cons(op, rest): return admitted_extent(table, op) && admitted_operations(new_table(extent_edit(op)), rest);
    }
}

fixpoint page_allocation replay_head(list<page_operation> ops, int probe, page_allocation initial) {
    switch (ops) {
        case nil: return initial;
        case cons(op, rest): return replay_head(rest, probe, updated_head(op, probe, initial));
    }
}

lemma void extent_history(list<int> table, list<page_operation> ops, int probe)
    requires well_formed_pages(table, false) == true &*& admitted_operations(table, ops) == true &*& probe >= 0;
    ensures valid_page_history(table, extent_edits(ops)) == true &*&
            well_formed_pages(final_page_table(table, extent_edits(ops)), false) == true &*&
            allocation_at(final_page_table(table, extent_edits(ops)), probe) == replay_head(ops, probe, allocation_at(table, probe));
{
    switch (ops) {
        case nil:
        case cons(op, rest):
            extent_step(table, op, probe);
            extent_history(new_table(extent_edit(op)), rest, probe);
    }
}

lemma void initial_heads_absent(list<int> xs, int probe)
    requires all_pages_have_availability(xs, true) == true &*& probe >= 0;
    ensures allocation_at(xs, probe) == absent_page_head;
{
    switch (xs) { case nil: case cons(x, rest): if (probe != 0) initial_heads_absent(rest, probe - 1); }
}

lemma void registered_extent_history(list<int> initial, list<page_operation> ops, int probe)
    requires all_pages_have_availability(initial, true) == true &*& length(initial) <= SIZE_MAX / PAGE_SIZE &*&
             admitted_operations(initial, ops) == true &*& probe >= 0;
    ensures allocation_at(final_page_table(initial, extent_edits(ops)), probe) == replay_head(ops, probe, absent_page_head) &*&
            well_formed_pages(final_page_table(initial, extent_edits(ops)), false) == true &*&
            length(initial) * PAGE_SIZE + history_byte_change(extent_edits(ops)) ==
                free_page_count(final_page_table(initial, extent_edits(ops))) * PAGE_SIZE &*&
            (initial == nil ? 0 : 1) + history_run_change(extent_edits(ops)) ==
                free_page_runs(final_page_table(initial, extent_edits(ops)), false);
{
    free_table_is_formed(initial);
    initial_heads_absent(initial, probe);
    extent_history(initial, ops, probe);
    registered_page_history(initial, extent_edits(ops));
}
@*/
