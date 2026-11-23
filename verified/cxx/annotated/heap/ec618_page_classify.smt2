; EC618 Thumb unsigned register values are integers in [0, 2^32).
; SUBS and ADD.W reduce modulo 2^32. LSRS #12 divides by 4096.
(set-logic QF_LIA)
(define-fun modulus () Int 4294967296)
(define-fun word ((x Int)) Bool (and (<= 0 x) (< x modulus)))
(declare-const low Int)
(declare-const extent Int)
(declare-const start Int)
(declare-const end Int)
(declare-const table Int)
(declare-const q Int)
(assert (and (word low) (word extent) (word start) (word end) (word table) (word q)))
(assert (<= (+ low extent) modulus))
(assert (and (= (mod low 4096) 0) (= (mod extent 4096) 0)))
; subs r3,start,low; cmp extent,r3; bls return
(define-fun r3 () Int (mod (- start low) modulus))
(define-fun writes () Bool (< r3 extent))
(push)
(assert (distinct writes (and (<= low start) (< start (+ low extent)))))
(check-sat)
(pop)
(assert writes)
; A live descriptor spans whole pages within the mapping. The type table
; has one writable byte per page. The positive tail-call path preserves r1.
(assert (and (= (mod start 4096) 0) (= (mod end 4096) 0) (< start end) (<= end (+ low extent))))
(assert (<= (+ table (div extent 4096)) modulus))
; subs r2,end,start; lsrs r2,#12; add.w r0,table,r3,lsr #12
(define-fun r2 () Int (div (mod (- end start) modulus) 4096))
(define-fun r0 () Int (mod (+ table (div r3 4096)) modulus))
(push)
(assert (not (and (<= table r0) (< 0 r2) (<= (+ r0 r2) (+ table (div extent 4096))))))
(check-sat)
(pop)
; Independently map the observed table address back to its absolute heap
; page. Compare with the unsigned relative-offset predicate proved for memset.
(define-fun heap-page () Int (+ low (* 4096 (- q table))))
(assert (distinct (< (mod (- q r0) modulus) r2)
                  (and (<= table q) (<= start heap-page) (< heap-page end))))
(check-sat)
