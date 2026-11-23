; Linked swap_semi_spaces on a valid single-chunk survivor space.
(set-logic QF_BV)
(define-sort W () (_ BitVec 32))
(declare-const start W)
(declare-const top W)
(declare-const limit W)
(declare-const heur W)
(declare-const heapLimit W)
(declare-const maxSize W)
(declare-const empty Bool)
(declare-const failed (_ BitVec 8))
(assert (and (bvule start top) (bvult top limit) (bvule failed #x01)))
; ITE NE sets r7=0 for nonempty old space; otherwise EOR flips the bool.
(define-fun postpone () (_ BitVec 8) (ite empty (bvxor failed #x01) #x00))
(define-fun bytes () W (bvsub top start))
(define-fun mark1 () W
  (ite (bvsgt heur (_ bv39 32)) top
    (ite (or (= postpone #x00) (bvuge bytes (_ bv2048 32))) top start)))
(define-fun finalMark () W
  (ite (= maxSize (_ bv0 32)) mark1
    (ite (bvugt heapLimit (_ bv4096 32)) mark1 start)))
; Independent specification uses widened offsets from start instead of
; a subtraction that could otherwise wrap.
(define-fun small () Bool
  (bvult ((_ zero_extend 1) top) (bvadd ((_ zero_extend 1) start) (_ bv2048 33))))
(define-fun reset () Bool
  (or (and empty (= failed #x00) (bvslt heur (_ bv40 32)) small)
      (and (distinct maxSize (_ bv0 32)) (bvule heapLimit (_ bv4096 32)))))
(assert (or (distinct finalMark (ite reset start top))
            (bvult finalMark start) (bvugt finalMark top)))
(check-sat)
