; EC618 v5 Thumb memmove, forward branch. Instruction offsets are relative
; to memmove. The runner checks the machine encodings and the allocator call.
; M0 is byte memory after the ABI push; the caller supplies a valid stack
; disjoint from both payload spans. The copy therefore cannot alter the two
; pushed words. Ordinary readable/writable memory and sequential access.
(set-logic QF_AUFBV)
(define-sort Word () (_ BitVec 32))
(define-sort Bytes () (Array Word (_ BitVec 8)))
(declare-const dst Word)
(declare-const src Word)
(declare-const size Word)
(declare-const i Word)
(declare-const q Word)
(declare-const M0 Bytes)
(declare-const M Bytes)
(define-fun one () Word #x00000001)
(define-fun zero () Word #x00000000)
; 00 cmp r0,r1; 02 push; 04 add.w r4,r1,r2 (preserves flags);
; 08 bls 10. Page relocation moves towards lower addresses.
(assert (bvult dst src))
(define-fun r4 () Word (bvadd src size))
(assert (bvuge r4 src))
(define-fun inside ((a Word) (n Word)) Bool
  (and (bvuge a dst) (bvult (bvsub a dst) n)))
(define-fun expected ((a Word) (done Word)) (_ BitVec 8)
  (ite (inside a done) (select M0 (bvadd src (bvsub a dst))) (select M0 a)))
(define-fun registers ((r1 Word) (r3 Word) (done Word)) Bool
  (and (bvule done size) (= r1 (bvadd src done)) (= (bvadd r3 one) (bvadd dst done))))
; 10 subs r3,r0,#1. Establish the invariant for every observed byte.
(push)
(assert (not (and (bvule dst src) (registers src (bvsub dst one) zero)
                  (= (select M0 q) (expected q zero)))))
(check-sat)
(pop)
(declare-const r1 Word)
(declare-const r3 Word)
(assert (registers r1 r3 i))
; 12 cmp r1,r4; 14 beq 28. At exit the universal byte invariant
; is the required copy postcondition, including untouched addresses.
(push)
(assert (= r1 r4))
(assert (= (select M q) (expected q i)))
(assert (not (and (= i size) (= (select M q) (expected q size)))))
(check-sat)
(pop)
(assert (distinct r1 r4))
; 16 ldrb.w r2,[r1],#1; 1a strb.w r2,[r3,#1]!; 1e b 12.
(define-fun read-byte () (_ BitVec 8) (select M r1))
(define-fun write-address () Word (bvadd r3 one))
(define-fun next-memory () Bytes (store M write-address read-byte))
(define-fun next-i () Word (bvadd i one))
; Instantiate the universal induction hypothesis at both observed addresses.
(assert (= (select M q) (expected q i)))
(assert (= read-byte (expected r1 i)))
(push)
(assert (not (and (bvuge r1 src) (bvult r1 r4)
                  (inside write-address size) (bvult write-address r1)
                  (registers (bvadd r1 one) write-address next-i)
                  (bvult (bvsub size next-i) (bvsub size i)))))
(check-sat)
(pop)
(assert (not (= (select next-memory q) (expected q next-i))))
(check-sat)
