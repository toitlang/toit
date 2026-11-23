; In a well-formed list the distinct live node addresses may be named by
; their original traversal ranks. -1 stands for NULL. Nodes outside this
; bucket are disjoint and the checked stores never name them.
(set-logic QF_LIA)
(declare-const n Int)
(declare-const cut Int)
(declare-const i Int)
(assert (and (> n 0) (<= 0 cut) (< cut n)))
(define-fun nil () Int (- 1))
(define-fun next ((j Int)) Int (ite (< (+ j 1) n) (+ j 1) nil))
(define-fun prev ((j Int)) Int (ite (> j 0) (- j 1) nil))
; Unlink only rewrites links in the live neighbors.
(define-fun unext ((j Int)) Int (ite (= j (prev cut)) (next cut) (next j)))
(define-fun uprev ((j Int)) Int (ite (= j (next cut)) (prev cut) (prev j)))
(define-fun uhead () Int (ite (= cut 0) (next cut) 0))
(define-fun retained ((rank Int)) Int
  (ite (or (< rank 0) (>= rank (- n 1))) nil (ite (< rank cut) rank (+ rank 1))))
(push)
(assert (or (distinct uhead (retained 0))
            (and (<= 0 i) (< i (- n 1))
                 (or (distinct (unext (retained i)) (retained (+ i 1)))
                     (distinct (uprev (retained i)) (retained (- i 1)))))))
(check-sat)
(pop)
; Insert a disjoint node n ahead of the original nodes, including for an
; empty bucket. Use m separately so that m=0 is in the domain.
(declare-const m Int)
(assert (>= m 0))
(define-fun inserted ((rank Int)) Int
  (ite (or (< rank 0) (> rank m)) nil (ite (= rank 0) m (- rank 1))))
(define-fun inext ((j Int)) Int
  (ite (= j m) (ite (= m 0) nil 0) (ite (< (+ j 1) m) (+ j 1) nil)))
(define-fun iprev ((j Int)) Int
  (ite (= j m) nil (ite (= j 0) m (- j 1))))
(assert (and (<= 0 i m)
             (or (distinct (inext (inserted i)) (inserted (+ i 1)))
                 (distinct (iprev (inserted i)) (inserted (- i 1))))))
(check-sat)
