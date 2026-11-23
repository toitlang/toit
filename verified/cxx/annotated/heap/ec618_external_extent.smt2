; EC618 aligned halfword memory. Indices are byte offsets from the raw
; object address. The external allocation and queue nodes are disjoint.
(set-logic QF_AUFBV)
(define-sort W () (_ BitVec 32))
(define-sort H () (_ BitVec 16))
(define-sort M () (Array W H))
(define-fun wr ((m M) (a W) (x W)) M
  (store (store m a ((_ extract 15 0) x)) (bvadd a #x00000002) ((_ extract 31 16) x)))
(define-fun rd ((m M) (a W)) W (concat (select m (bvadd a #x00000002)) (select m a)))
(declare-const before M)
(declare-const len W)
(declare-const ptr W)
(declare-const id W)
(declare-const finalized Bool)
(declare-const probe W)
(assert (bvsge len #x00000000))
(assert (bvule id #x01ffffff))
(define-fun hdr ((tag W)) W (bvor (bvshl id #x00000006) (bvshl tag #x00000001)))
(define-fun mark ((m M)) M
  (ite finalized (wr m #x00000000 (bvor (bvand (rd m #x00000000) #xfffffffe) #x00000020)) m))
(define-fun same-class ((m M) (tag W)) Bool
  (and (= (bvashr (rd m #x00000000) #x00000006) id)
       (= ((_ extract 4 1) (rd m #x00000000)) ((_ extract 3 0) tag))
       (= ((_ extract 0 0) (rd m #x00000000)) #b0)))
; The collector's variable-size cases after a zero size in the class table.
(define-fun blob-size ((m M)) W
  (ite (bvslt (rd m #x00000004) #x00000000) #x00000010
       (bvand (bvadd (rd m #x00000004) #x0000000b) #xfffffffc)))
(define-fun string-size ((m M)) W
  (ite (= (select m #x00000006) #xffff) #x00000010
       (bvand (bvadd ((_ zero_extend 16) (select m #x00000006)) #x0000000c) #xfffffffc)))
(define-fun blob () M
  (mark (wr (wr (wr (wr before #x00000000 (hdr #x00000005)) #x00000008 ptr)
                 #x00000004 (bvnot len)) #x0000000c (ite (= ptr #x00000000) #x00000001 #x00000000))))
(define-fun string () M
  (mark (wr (store (store (wr (wr before #x00000000 (hdr #x00000001)) #x00000008 len)
                           #x00000006 #xffff) #x00000004 #xffff) #x0000000c ptr)))
(push)
(assert (or (not (same-class blob #x00000005)) (distinct (blob-size blob) #x00000010)
            (distinct (bvnot (rd blob #x00000004)) len) (distinct (rd blob #x00000008) ptr)
            (and (bvuge probe #x00000010) (distinct (select blob probe) (select before probe)))))
(check-sat)
(pop)
(push)
(assert (or (not (same-class string #x00000001)) (distinct (string-size string) #x00000010)
            (distinct (rd string #x00000008) len) (distinct (rd string #x0000000c) ptr)
            (and (bvuge probe #x00000010) (distinct (select string probe) (select before probe)))))
(check-sat)
(pop)
; Begin mutations with an arbitrary external byte array, so these results
; apply after any number of earlier resizes, including realloc failures.
(assert (bvslt (rd before #x00000004) #x00000000))
(assert (bvule len (bvnot (rd before #x00000004))))
(declare-const new-ptr W)
(define-fun resized-len () M (wr before #x00000004 (bvnot len)))
(define-fun resized () M
  (ite (distinct new-ptr #x00000000) (wr resized-len #x00000008 new-ptr)
       (ite (= len #x00000000) (wr resized-len #x00000008 #x00000000) resized-len)))
(define-fun detached () M (wr (wr before #x00000008 #x00000000) #x00000004 #xffffffff))
(define-fun unchanged ((m M)) Bool
  (=> (or (bvult probe #x00000004) (bvuge probe #x0000000c))
      (= (select m probe) (select before probe))))
(push)
(assert (or (not (unchanged resized)) (distinct (blob-size resized) #x00000010)
            (distinct (bvnot (rd resized #x00000004)) len)
            (distinct (rd resized #x00000008)
                      (ite (and (= new-ptr #x00000000) (distinct len #x00000000))
                           (rd before #x00000008) new-ptr))))
(check-sat)
(pop)
(push)
(assert (or (not (unchanged detached)) (distinct (blob-size detached) #x00000010)
            (distinct (bvnot (rd detached #x00000004)) #x00000000)
            (distinct (rd detached #x00000008) #x00000000)))
(check-sat)
(pop)
