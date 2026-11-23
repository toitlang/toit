; A mutable intrusive FIFO contains link addresses (node + 4).
; At the loop head prev is the link field of the last retained node or
; the original anchor. The input suffix is current, next, ... . The
; distinctness conditions are local consequences of a valid finite FIFO
; and an independent runnable queue.
(set-logic QF_AUFBV)
(define-sort W () (_ BitVec 32))
(define-sort M () (Array W W))
(declare-const before M)
(declare-const src W)
(declare-const dst W)
(declare-const cur W)
(declare-const prev W)
(declare-const probe W)
(define-fun tail-field ((q W)) W (bvadd q #x00000004))
(define-fun next () W (select before cur))
(define-fun old-tail () W (select before (tail-field dst)))
(define-fun source-tail () W (select before (tail-field src)))
(assert (distinct #x00000000 cur prev dst (tail-field dst) (tail-field src)))
(assert (or (= prev src) (distinct src #x00000000 cur prev dst (tail-field dst) (tail-field src))))
(assert (= (select before prev) cur))
(assert (ite (= next #x00000000) (= source-tail cur) (distinct source-tail cur)))
; A stored null tail or the destination anchor represents an empty FIFO;
; a nonempty FIFO ends in a distinct link whose successor is null.
(assert (=> (or (= old-tail dst) (= old-tail #x00000000)) (= (select before dst) #x00000000)))
(assert (=> (distinct old-tail dst #x00000000)
            (and (distinct old-tail src prev cur (tail-field src) (tail-field dst))
                 (= (select before old-tail) #x00000000))))
(define-fun detached () M (store before cur #x00000000))
; If callback keeps this node, it returns ownership of its own link.
; Restoring next reconstructs the original topology even at the tail.
(push)
(assert (distinct (store detached cur next) before))
(check-sat)
(pop)
; The callback may delete or repurpose the current node on removal. Its
; entire new link value must survive the source queue's repair.
(declare-const repurposed W)
(define-fun repair ((m M)) M
  (store (ite (= next #x00000000) (store m (tail-field src) prev) m) prev next))
(define-fun removed () M (repair (store detached cur repurposed)))
(push)
(assert (or (distinct (select removed cur) repurposed) (distinct (select removed prev) next)
            (distinct (select removed (tail-field src)) (ite (= next #x00000000) prev source-tail))
            (and (distinct probe prev) (distinct probe cur) (distinct probe (tail-field src))
                 (distinct (select removed probe) (select before probe)))))
(check-sat)
(pop)
; Ordinary dead active callback: append the detached node to runnable
; before returning true to remove it from the registration list.
(define-fun last-link () W (ite (= old-tail #x00000000) dst old-tail))
(define-fun appended () M
  (ite (= old-tail #x00000000)
       (store (store (store detached (tail-field dst) cur) cur (select detached dst)) dst cur)
       (store (store (store detached cur (select detached old-tail)) old-tail cur) (tail-field dst) cur)))
(define-fun moved () M (repair appended))
(push)
(assert (or (distinct (select moved cur) #x00000000) (distinct (select moved last-link) cur)
            (distinct (select moved (tail-field dst)) cur) (distinct (select moved prev) next)
            (distinct (select moved dst) (ite (= last-link dst) cur (select before dst)))
            (distinct (select moved (tail-field src)) (ite (= next #x00000000) prev source-tail))
            (and (distinct probe cur) (distinct probe last-link) (distinct probe prev)
                 (distinct probe (tail-field dst)) (distinct probe (tail-field src))
                 (distinct (select moved probe) (select before probe)))))
(check-sat)
(pop)
; ARM NEGS/ADCS produces 1 exactly for a forwarded header inside the
; from-space chunk. Outside the source interval the oracle returns true.
(declare-const key W)
(declare-const lo W)
(declare-const hi W)
(assert (and (bvule lo hi) (= (bvand key #x00000003) #x00000001)))
(define-fun raw () W (bvsub key #x00000001))
(define-fun inside () Bool (and (not (bvult raw lo)) (bvult raw hi)))
(define-fun h () W (select before raw))
(define-fun forwarded () Bool (= (bvand h #x00000003) #x00000001))
(define-fun diff () W (bvsub (bvand h #x00000003) #x00000001))
(define-fun adc () W (bvadd (bvadd (bvneg diff) diff)
                             (ite (= diff #x00000000) #x00000001 #x00000000)))
(push)
(assert (distinct (ite inside adc #x00000001)
                  (ite (or (not inside) forwarded) #x00000001 #x00000000)))
(check-sat)
(pop)
; Selection of the active bit on forwarded/unforwarded keys and the dead
; branch's header update. The null key assignment and lambda callback are
; on separate node fields. Assume valid disjoint heap/node storage.
(define-fun flag ((x W)) W (bvand (bvlshr x #x00000005) #x00000001))
(define-fun header-at ((obj W)) W (select before (bvsub obj #x00000001)))
(define-fun active () W (flag (header-at (ite forwarded h key))))
(push)
(assert (or (distinct active (ite forwarded (flag (header-at h)) (flag h)))
            (and (not forwarded) (distinct (bvand (bvand h #xffffffde) #xffffffc0)
                                           (bvand h #xffffffc0)))
            (distinct (flag (bvand h #xffffffde)) #x00000000)))
(check-sat)
(pop)
; When a dead registered key is active, the constructor of the runnable
; entry clears its raw header flag, replaces the key, and visits lambda in
; place. Model the visitor's relocation of that slot; graph/allocator side
; effects must frame these node fields and the dead key's header.
(declare-const node W)
(declare-const nil-object W)
(declare-const relocated W)
(define-fun key-slot () W (bvadd node #x00000008))
(define-fun lambda-slot () W (bvadd node #x00000010))
(push)
(assert (and inside (not forwarded) (= active #x00000001) (= (bvand h #x00000001) #x00000000)
             (= (select before key-slot) key)
             (distinct raw key-slot lambda-slot (bvadd node #x00000004))))
(define-fun revived () M
  (store (store (store before raw (bvand h #xffffffde)) key-slot nil-object) lambda-slot relocated))
(assert (or (distinct (select revived raw) (bvand h #xffffffdf))
            (distinct (select revived key-slot) nil-object)
            (distinct (select revived lambda-slot) relocated)
            (and (distinct probe raw key-slot lambda-slot) (distinct (select revived probe) (select before probe)))))
(check-sat)
(pop)
; Induction over a finite stable root ring / saved FIFO suffix: at iteration
; i the chosen original node j has been presented precisely when j < i.
; Conditional removal or moving it changes the kept list, never the saved
; successor. Selectors stand for the valid chain in original forward order.
(reset)
(set-logic QF_AUFLIA)
(declare-const nodes (Array Int Int))
(declare-const links (Array Int Int))
(declare-const count Int)
(declare-const i Int)
(declare-const j Int)
(declare-const anchor Int)
(assert (and (<= 0 count) (<= 0 i count) (<= 0 j) (< j count)
             (= (select nodes count) anchor)))
(define-fun seen ((k Int)) Int (ite (< j k) 1 0))
(push)
(assert (or (distinct (seen 0) 0) (distinct (seen count) 1)))
(check-sat)
(pop)
(push)
(assert (< i count))
(define-fun current () Int (select nodes i))
(assert (and (distinct current anchor) (= (select links current) (select nodes (+ i 1)))
             (= (= current (select nodes j)) (= i j))))
(assert (or (distinct (+ (seen i) (ite (= current (select nodes j)) 1 0)) (seen (+ i 1)))
            (>= (- count (+ i 1)) (- count i))
            (and (= (+ i 1) count) (distinct (select links current) anchor))))
(check-sat)
(pop)
