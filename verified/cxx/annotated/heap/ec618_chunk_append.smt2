; Rank -1 denotes the sentinel. Old nodes have ranks 0..n-1 and the
; disjoint detached node is named n. Addresses can be renamed this way
; because the linked splice compares only sentinel identity.
(set-logic QF_LIA)
(declare-const n Int)
(declare-const k Int)
(declare-const i Int)
(assert (and (<= 0 k n) (<= -1 i n)))
(define-fun pred ((j Int)) Int (ite (= j -1) (- n 1) (- j 1)))
(define-fun succ ((j Int)) Int (ite (= j (- n 1)) -1 (+ j 1)))
(define-fun left () Int (- k 1))
(define-fun right () Int (succ left))
; Four word stores in linked order. In the empty ring left==right==-1.
(define-fun nextAfter ((j Int)) Int (ite (= j n) right (ite (= j left) n (succ j))))
(define-fun prevAfter ((j Int)) Int (ite (= j n) left (ite (= j right) n (pred j))))
(define-fun name ((rank Int)) Int (ite (< rank k) rank (ite (= rank k) n (- rank 1))))
(define-fun nextRank ((rank Int)) Int (ite (= rank n) -1 (+ rank 1)))
(define-fun prevRank ((rank Int)) Int (ite (= rank -1) n (- rank 1)))
(push)
(assert (or (distinct (nextAfter (name i)) (name (nextRank i)))
            (distinct (prevAfter (name i)) (name (prevRank i)))))
(check-sat)
(pop)
; For valid non-wrapping chunks the Thumb SUBS yields the true size.
(declare-const start Int)
(declare-const end Int)
(declare-const candidate Int)
(declare-const limit Int)
(assert (and (<= 0 start) (< start end 4294967296)
             (<= 0 candidate) (< candidate limit 4294967296)))
(define-fun a () Int (mod (- end start) 4294967296))
(define-fun b () Int (mod (- limit candidate) 4294967296))
; Fall-through from first BLS inserts before a larger chunk. With equal
; sizes the second BLS and BEQ insert before a larger start address.
(define-fun take () Bool (ite (> a b) true (and (> start candidate) (= a b))))
(define-fun less ((x Int) (atX Int) (y Int) (atY Int)) Bool
  (or (< x y) (and (= x y) (< atX atY))))
(push)
(assert (distinct take (less (- limit candidate) candidate (- end start) start)))
(check-sat)
(pop)
; A previously visited chunk stays before the new one; once the first
; larger entry is reached every later entry in the sorted suffix qualifies.
(declare-const laterSize Int)
(declare-const laterStart Int)
(push)
(assert (and take (not (less laterSize laterStart a start))))
(assert (not (less b candidate laterSize laterStart)))
(check-sat)
(pop)
; For a live page-aligned chunk and a word-aligned top in [start,end),
; update_base_and_limit writes a complete sentinel. At chunk start, the
; biased table pointer and shifted length name exactly its starts bytes.
(declare-const low Int)
(declare-const extent Int)
(declare-const table Int)
(declare-const top Int)
(assert (and (<= 0 low start top) (< top end) (<= end (+ low extent) 4294967295)
             (= (mod low 4096) 0) (= (mod start 4096) 0) (= (mod end 4096) 0)
             (= (mod extent 4096) 0) (= (mod top 4) 0)
             (<= 0 table) (<= (+ table (div extent 128)) 4294967296)))
(define-fun bias () Int (mod (- table (div low 128)) 4294967296))
(define-fun dst () Int (mod (+ bias (div top 128)) 4294967296))
(define-fun len () Int (mod (- (div end 128) (div top 128)) 4294967296))
(assert (or (> (+ top 4) end)
            (and (= top start) (or (distinct dst (+ table (div (- start low) 128)))
                                   (distinct (+ dst len) (+ table (div (- end low) 128)))))))
(check-sat)
