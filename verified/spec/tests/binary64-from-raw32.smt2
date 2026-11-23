; Copyright (C) 2026 Toit contributors.
; SPDX-License-Identifier: LGPL-2.1-only
; Verify exact widening for all binary32 numbers and infinities. IEEE leaves
; NaN payload selection open; separately check the input classification.
(set-logic QF_FPBV)
(declare-const x (_ BitVec 32))
(declare-const shift (_ BitVec 32))
(define-fun exponent () (_ BitVec 32) (bvand (bvlshr x (_ bv23 32)) #x000000ff))
(define-fun frac () (_ BitVec 32) (bvand x #x007fffff))
(define-fun sign () (_ BitVec 64) (concat (bvand x #x80000000) #x00000000))
(assert (=> (distinct frac (_ bv0 32))
  (and (bvule shift (_ bv31 32))
       (= (bvlshr frac (bvsub (_ bv31 32) shift)) (_ bv1 32)))))
(define-fun wide ((n (_ BitVec 32))) (_ BitVec 64) ((_ zero_extend 32) n))
(define-fun bits () (_ BitVec 64)
  (bvor sign
    (ite (= exponent (_ bv0 32))
      (ite (= frac (_ bv0 32)) (_ bv0 64)
        (bvor (bvshl (wide (bvsub (_ bv905 32) shift)) (_ bv52 64))
              (bvshl (wide (bvand (bvshl frac shift) #x7fffffff)) (_ bv21 64))))
      (ite (= exponent (_ bv255 32)) #x7ff0000000000000
        (bvor (bvshl (wide (bvadd exponent (_ bv896 32))) (_ bv52 64))
              (bvshl (wide frac) (_ bv29 64)))))))
(define-fun a () (_ FloatingPoint 8 24) ((_ to_fp 8 24) x))
(define-fun nan () Bool (bvugt (bvand x #x7fffffff) #x7f800000))
(assert (or (distinct nan (fp.isNaN a))
            (and (not nan) (distinct bits (fp.to_ieee_bv ((_ to_fp 11 53) RNE a))))))
(check-sat)
