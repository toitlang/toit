; Copyright (C) 2026 Toit contributors.
; SPDX-License-Identifier: LGPL-2.1-only
; Check truncate_binary64 in prim_core.rs against the IEEE round-toward-zero
; conversion, including the domain on which fp.to_sbv is defined.
(set-logic QF_FPBV)
(declare-const x (_ BitVec 64))
(define-fun a () (_ FloatingPoint 11 53) ((_ to_fp 11 53) x))
(define-fun exponent () (_ BitVec 64) (bvand (bvlshr x (_ bv52 64)) #x00000000000007ff))
(define-fun fraction () (_ BitVec 64) (bvand x #x000fffffffffffff))
(define-fun nan () Bool (and (= exponent (_ bv2047 64)) (distinct fraction (_ bv0 64))))
(define-fun min-int () Bool (= x #xc3e0000000000000))
(define-fun in-range () Bool (or min-int (bvult exponent (_ bv1086 64))))
(define-fun significand () (_ BitVec 64) (bvor fraction #x0010000000000000))
(define-fun magnitude () (_ BitVec 64)
  (ite (bvult exponent (_ bv1075 64))
       (bvlshr significand (bvsub (_ bv1075 64) exponent))
       (bvshl significand (bvsub exponent (_ bv1075 64)))))
(define-fun result () (_ BitVec 64)
  (ite min-int #x8000000000000000
       (ite (bvult exponent (_ bv1023 64)) (_ bv0 64)
            (ite (= ((_ extract 63 63) x) #b0) magnitude (bvneg magnitude)))))
(define-fun ieee-in-range () Bool
  (and (fp.geq a ((_ to_fp 11 53) #xc3e0000000000000))
       (fp.lt a ((_ to_fp 11 53) #x43e0000000000000))))
(assert (or (distinct nan (fp.isNaN a))
            (distinct in-range ieee-in-range)
            (and in-range (distinct result ((_ fp.to_sbv 64) RTZ a)))))
(check-sat)
