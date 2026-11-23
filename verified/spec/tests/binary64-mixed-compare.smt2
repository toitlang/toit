; Copyright (C) 2026 Toit contributors.
; SPDX-License-Identifier: LGPL-2.1-only
; Check magnitude_order against a floating-point comparison in a format
; wide enough to represent both the integer and the binary64 value exactly.
(set-logic QF_FPBV)
(declare-const i (_ BitVec 64))
(declare-const d (_ BitVec 64))
(assert (= ((_ extract 63 63) d) #b0))
(define-fun f () (_ FloatingPoint 11 53) ((_ to_fp 11 53) d))
(assert (not (fp.isNaN f)))
(define-fun e () (_ BitVec 64) (bvlshr d (_ bv52 64)))
(define-fun sig () (_ BitVec 64) (bvor (bvand d #x000fffffffffffff) #x0010000000000000))
(define-fun shift () (_ BitVec 64) (bvsub (_ bv1075 64) e))
(define-fun whole () (_ BitVec 64)
  (ite (bvult e (_ bv1023 64)) (_ bv0 64)
    (ite (bvuge e (_ bv1075 64)) (bvshl sig (bvsub e (_ bv1075 64)))
      (bvlshr sig shift))))
(define-fun fraction () Bool
  (ite (bvult e (_ bv1023 64)) (distinct d (_ bv0 64))
    (and (bvult e (_ bv1075 64)) (distinct sig (bvshl whole shift)))))
(define-fun outside () Bool (bvuge e (_ bv1087 64)))
(define-fun less () Bool (or outside (bvult i whole) (and (= i whole) fraction)))
(define-fun equal () Bool (and (not outside) (= i whole) (not fraction)))
(define-fun lhs () (_ FloatingPoint 11 64) ((_ to_fp_unsigned 11 64) RNE i))
(define-fun rhs () (_ FloatingPoint 11 64) ((_ to_fp 11 64) RNE f))
(assert (or (distinct less (fp.lt lhs rhs)) (distinct equal (fp.eq lhs rhs))))
(check-sat)
