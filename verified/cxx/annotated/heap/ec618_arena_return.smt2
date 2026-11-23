; Widened integers for addresses and wraparound of Thumb arithmetic.
(set-logic QF_LIA)
(define-fun word ((v Int)) Int (mod v 4294967296))
(declare-const base Int)
(declare-const pages Int)
(assert (and (> base 0) (= (mod base 4096) 0) (> pages 0)
             (< (+ base (* pages 4096)) 4294967296)))
(define-fun limit () Int (+ base (* pages 4096)))
(define-fun left () Int (+ base 8))
(define-fun right () Int (- limit 8))
(define-fun merged () Int (- right (+ left 8)))
; free_memory passes the free block size plus the left and right headers.
(define-fun arg () Int (word (+ merged 8 8)))
; LSLS #20; CMN #0x800000 tests whether adding the 8-byte ring
; descriptor gives a whole number of pages.
(push)
(assert (or (distinct (word (+ (* arg 1048576) 8388608)) 0)
            (distinct (word (- left 8)) base)
            (distinct (+ arg 8) (* pages 4096))
            (distinct (- (* pages 4096) merged) 24)
            ; growth subtracts all page bytes; add_to_heap credits the
            ; usable part; returning the arena credits the 24-byte overhead.
            (distinct (word (+ (- (* pages 4096)) merged 24)) 0)))
(check-sat)
(pop)
; Circular arena list with a permanent root at rank 0. Each live address
; has a distinct rank. Remove arena c and keep all remaining ranks in order.
(declare-const n Int)
(declare-const c Int)
(declare-const i Int)
(assert (and (>= n 2) (<= 1 c) (< c n) (<= 0 i) (< i (- n 1))))
(define-fun pred ((j Int)) Int (ite (= j 0) (- n 1) (- j 1)))
(define-fun succ ((j Int)) Int (ite (= (+ j 1) n) 0 (+ j 1)))
(define-fun keep ((k Int)) Int (ite (< k c) k (+ k 1)))
(define-fun prevAfter ((j Int)) Int (ite (= j (succ c)) (pred c) (pred j)))
(define-fun nextAfter ((j Int)) Int (ite (= j (pred c)) (succ c) (succ j)))
(push)
(assert (or (distinct (prevAfter (keep i)) (keep (ite (= i 0) (- n 2) (- i 1))))
            (distinct (nextAfter (keep i)) (keep (ite (= (+ i 2) n) 0 (+ i 1))))))
(check-sat)
(pop)
; Allocation payloads in registered edge fragments lie strictly inside a
; sub-page interval that ends or starts on a page boundary.
(declare-const ptr Int)
(push)
(assert (and (or (< (- base 4096) ptr base) (< limit ptr (+ limit 4096)))
             (= (mod ptr 4096) 0)))
(check-sat)
(pop)
; A page-aligned payload strictly inside a page-backed small-block arena
; can only be on a continuation page. The ordinary page head is distinct.
(declare-const pageBase Int)
(assert (and (<= 0 pageBase base) (= (mod pageBase 4096) 0)))
(define-fun headIndex () Int (div (- base pageBase) 4096))
(define-fun index () Int (div (word (- ptr pageBase)) 4096))
(push)
(assert (and (< base ptr limit) (= (mod ptr 4096) 0)))
(assert (not (and (< headIndex index (+ headIndex pages))
                  (= index (+ headIndex (div (- ptr base) 4096))))))
(check-sat)
(pop)
; SUBS t,status,#1; NEGS r0,t; ADCS r0,t. ARM subtraction from zero sets
; carry exactly when t=0. Status zero branches away before these operations.
(declare-const status Int)
(assert (<= 1 status 4294967295))
(define-fun t () Int (word (- status 1)))
(define-fun ordinary () Int (word (+ (word (- t)) t (ite (= t 0) 1 0))))
(assert (distinct ordinary (ite (= status 1) 1 0)))
(check-sat)
