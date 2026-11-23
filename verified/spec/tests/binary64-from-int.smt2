; Copyright (C) 2026 Toit contributors.
; SPDX-License-Identifier: LGPL-2.1-only
; Check integer_binary64 against IEEE signed integer conversion. For each
; nonzero magnitude, leading_zeros selects the unique normalization shift.
(set-logic QF_FPBV)
(declare-const i (_ BitVec 64))
(declare-const shift (_ BitVec 64))
(define-fun mag () (_ BitVec 64) (ite (bvslt i (_ bv0 64)) (bvneg i) i))
(assert (=> (distinct i (_ bv0 64))
  (and (bvule shift (_ bv63 64))
       (= (bvlshr mag (bvsub (_ bv63 64) shift)) (_ bv1 64)))))
(define-fun normalized () (_ BitVec 64) (bvshl mag shift))
(define-fun retained () (_ BitVec 64) (bvlshr normalized (_ bv11 64)))
(define-fun discarded () (_ BitVec 64) (bvand normalized #x00000000000007ff))
(define-fun round-up () Bool
  (or (bvugt discarded (_ bv1024 64))
      (and (= discarded (_ bv1024 64)) (= ((_ extract 0 0) retained) #b1))))
(define-fun base () (_ BitVec 64) (bvshl (bvsub (_ bv1085 64) shift) (_ bv52 64)))
(define-fun bits () (_ BitVec 64)
  (ite (= i (_ bv0 64)) (_ bv0 64)
       (bvor (bvand i #x8000000000000000)
             (bvadd base retained (ite round-up (_ bv1 64) (_ bv0 64))))))
(assert (distinct bits (fp.to_ieee_bv ((_ to_fp 11 53) RNE i))))
(check-sat)
