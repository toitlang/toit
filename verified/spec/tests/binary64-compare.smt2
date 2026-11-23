; Copyright (C) 2026 Toit contributors.
; SPDX-License-Identifier: LGPL-2.1-only
; Cross-check the signed-magnitude rank and NaN predicate of prim_core.rs
; against SMT-LIB binary64 comparisons for every pair of encodings.
(set-logic QF_FPBV)
(declare-const x (_ BitVec 64))
(declare-const y (_ BitVec 64))
(define-fun rank ((b (_ BitVec 64))) (_ BitVec 64)
  (let ((m (bvand b #x7fffffffffffffff)))
    (ite (= ((_ extract 63 63) b) #b1) (bvneg m) m)))
(define-fun nan ((b (_ BitVec 64))) Bool
  (and (= ((_ extract 62 52) b) #b11111111111)
       (distinct ((_ extract 51 0) b) #x0000000000000)))
(define-fun ordered () Bool (not (or (nan x) (nan y))))
(define-fun a () (_ FloatingPoint 11 53) ((_ to_fp 11 53) x))
(define-fun b () (_ FloatingPoint 11 53) ((_ to_fp 11 53) y))
(assert (or
  (distinct (and ordered (bvslt (rank x) (rank y))) (fp.lt a b))
  (distinct (and ordered (bvsle (rank x) (rank y))) (fp.leq a b))
  (distinct (and ordered (bvsgt (rank x) (rank y))) (fp.gt a b))
  (distinct (and ordered (bvsge (rank x) (rank y))) (fp.geq a b))
  (distinct (and ordered (= (rank x) (rank y))) (fp.eq a b))))
(check-sat)
