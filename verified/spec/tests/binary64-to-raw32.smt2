; Copyright (C) 2026 Toit contributors.
; SPDX-License-Identifier: LGPL-2.1-only
; Check narrowed_binary64 against IEEE conversion to binary32 on every
; non-NaN input, including both signed zeros and both infinities.
(set-logic QF_FPBV)
(declare-const x (_ BitVec 64))
(define-fun a () (_ FloatingPoint 11 53) ((_ to_fp 11 53) x))
(define-fun e () (_ BitVec 64) (bvand (bvlshr x (_ bv52 64)) #x00000000000007ff))
(define-fun sig () (_ BitVec 64) (bvor (bvand x #x000fffffffffffff) #x0010000000000000))
(define-fun subnormal () Bool (bvult e (_ bv897 64)))
(define-fun shift () (_ BitVec 64) (ite subnormal (bvsub (_ bv926 64) e) (_ bv29 64)))
(define-fun kept () (_ BitVec 64) (bvlshr sig shift))
(define-fun half () (_ BitVec 64) (bvshl (_ bv1 64) (bvsub shift (_ bv1 64))))
(define-fun rest () (_ BitVec 64) (bvand sig (bvsub (bvadd half half) (_ bv1 64))))
(define-fun up () Bool (or (bvugt rest half) (and (= rest half) (= ((_ extract 0 0) kept) #b1))))
(define-fun base () (_ BitVec 64)
  (ite subnormal (_ bv0 64) (bvshl (bvsub e (_ bv897 64)) (_ bv23 64))))
(define-fun bits () (_ BitVec 32)
  (bvor (bvand ((_ extract 63 32) x) #x80000000)
        (ite (bvult e (_ bv873 64)) (_ bv0 32)
             (ite (bvugt e (_ bv1150 64)) #x7f800000
                  ((_ extract 31 0) (bvadd base kept (ite up (_ bv1 64) (_ bv0 64))))))))
(assert (not (fp.isNaN a)))
(assert (distinct bits (fp.to_ieee_bv ((_ to_fp 8 24) RNE a))))
(check-sat)
