; Copyright (C) 2026 Toit contributors.
; SPDX-License-Identifier: LGPL-2.1-only
; Compare the binary64 result bits with IEEE directed rounding, including
; signed zeros. IEEE leaves the NaN encoding unspecified.
(set-logic QF_FPBV)
(declare-const x (_ BitVec 64))
(declare-const op (_ BitVec 8))
(assert (and (bvuge op #x02) (bvule op #x04)))
(define-fun a () (_ FloatingPoint 11 53) ((_ to_fp 11 53) x))
(assert (not (fp.isNaN a)))
(define-fun sign () (_ BitVec 64) (bvand x #x8000000000000000))
(define-fun mag () (_ BitVec 64) (bvand x #x7fffffffffffffff))
(define-fun e () (_ BitVec 64) (bvlshr mag (_ bv52 64)))
(define-fun away () Bool (or (and (= op #x02) (= sign (_ bv0 64)))
                             (and (= op #x03) (distinct sign (_ bv0 64)))))
(define-fun unit () (_ BitVec 64) (bvshl (_ bv1 64) (bvsub (_ bv1075 64) e)))
(define-fun mask () (_ BitVec 64) (bvsub unit (_ bv1 64)))
(define-fun base () (_ BitVec 64) (bvand x (bvnot mask)))
(define-fun result () (_ BitVec 64)
  (ite (or (= mag (_ bv0 64)) (bvuge e (_ bv1075 64))) x
    (ite (bvult e (_ bv1023 64))
      (bvor sign (ite away #x3ff0000000000000 (_ bv0 64)))
      (ite (and away (distinct (bvand x mask) (_ bv0 64))) (bvadd base unit) base))))
(define-fun mode () RoundingMode (ite (= op #x02) RTP (ite (= op #x03) RTN RTZ)))
(assert (distinct result (fp.to_ieee_bv (fp.roundToIntegral mode a))))
(check-sat)
