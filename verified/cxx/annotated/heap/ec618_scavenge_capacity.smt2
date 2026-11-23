; Count the bytes of any subset of true source objects in address order.
; This logical ordering is independent of the order in which roots are seen.
(set-logic QF_LIA)
(declare-const start Int)
(declare-const top Int)
(declare-const limit Int)
(declare-const capacity Int)
(assert (and (<= 0 start top) (<= (+ top 4) limit)
             (= (- limit start) 4096) (= capacity 4096)))
(define-fun bounded ((cursor Int) (bytes Int)) Bool
  (and (<= start cursor top) (<= 0 bytes (- cursor start))))
(push)
(assert (not (bounded start 0)))
(check-sat)
(pop)
(declare-const cursor Int)
(declare-const bytes Int)
(declare-const obj Int)
(declare-const size Int)
(declare-const selected Bool)
(assert (bounded cursor bytes))
(push)
; The next object begins after the preceding extent and ends before the
; source sentinel. Holes and objects outside the chosen subset are fine.
(assert (and (<= cursor obj) (> size 0) (<= (+ obj size) top)))
(assert (not (bounded (+ obj size) (+ bytes (ite selected size 0)))))
(check-sat)
(pop)
; At any prefix (including the whole heap), an empty destination can hold
; the selected payload and its sentinel. Selecting all objects initializes
; the unforwarded-byte invariant in ec618_scavenge_copy.smt2.
(push)
(assert (> (+ bytes 4) capacity))
(check-sat)
(pop)
