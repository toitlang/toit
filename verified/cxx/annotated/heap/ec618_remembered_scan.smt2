; EC618 old-space remembered scanning. The match of this model to the linked
; slot code was checked once by a removed script and is unchecked now
; (verified/core/TRUSTED.md, "Unchecked linked-image results").
(set-logic QF_AUFBV)
(define-sort W () (_ BitVec 32))
(define-sort B () (_ BitVec 8))
(define-fun idx ((a W)) W (bvlshr a #x00000007))
(declare-const start W)
(declare-const end W)
(declare-const card W)
(declare-const bias W)
(declare-const starts-bias W)
(define-fun meta ((a W)) W (bvadd bias (idx a)))
(define-fun starts ((a W)) W (bvadd starts-bias (idx a)))
(assert (and (bvule start card) (bvult card end)
             (= (bvand start #x00000fff) #x00000000) (= (bvand end #x00000fff) #x00000000)
             (= (bvand card #x0000007f) #x00000000)
             (= (bvand (meta start) #x00000003) #x00000000)))
; Physical table slices are live and contiguous. The *bias* is unsigned
; modular arithmetic, even when the base is below the shifted heap address.
(declare-const cards (Array W B))
(define-fun at ((i W)) B (select cards (bvadd (meta card) i)))
(define-fun four () W (concat (at #x00000003) (at #x00000002) (at #x00000001) (at #x00000000)))
(declare-const probe W)
(push)
(assert (= (bvand (meta card) #x00000003) #x00000000))
(define-fun next4 () W (bvadd card #x00000200))
(assert (or (bvule next4 card) (bvugt next4 end)
            (distinct (meta next4) (bvadd (meta card) #x00000004))
            (and (= four #x00000000) (bvule card probe) (bvult probe next4)
                 (distinct (select cards (meta probe)) #x00))))
(check-sat)
(pop)
(push)
(assert (or (bvule (bvadd card #x00000080) card) (bvugt (bvadd card #x00000080) end)
            (distinct (meta (bvadd card #x00000080)) (bvadd (meta card) #x00000001))
            (distinct (= (starts start) (starts card)) (= start card))))
(check-sat)
(pop)
; Backtrack in steps of 128, but only inspect a starts byte when its
; card is strictly above the earliest safe boundary. At the first card
; the lower bound always terminates the loop.
(declare-const walk W)
(declare-const earliest W)
(assert (and (bvule start earliest) (bvule earliest end) (bvule start walk) (bvule walk card)
             (= (bvand walk #x0000007f) #x00000000)))
(push)
(assert (bvugt walk start))
(define-fun prev () W (bvsub walk #x00000080))
(assert (or (bvult prev start) (bvuge prev walk)
            (distinct (starts prev) (bvsub (starts walk) #x00000001))
            (and (= prev start) (bvugt prev earliest))))
(check-sat)
(pop)
; Real recorded object starts are aligned and belong to the recorded
; card. The recorded byte contains the low 8 bits, not just a card offset.
(declare-const boundary W)
(push)
(assert (and (bvult walk card) (bvugt walk earliest)
             (= (idx walk) (idx boundary)) (= (bvand boundary #x00000003) #x00000000)))
(define-fun entry () B ((_ extract 7 0) boundary))
(define-fun decoded () W (bvadd (bvand walk #xffffff00) ((_ zero_extend 24) entry)))
(assert (or (= entry #x02) (distinct decoded boundary) (bvult decoded earliest) (bvuge decoded card)))
(check-sat)
(pop)
; The instance write barrier records the card of the object, even if a
; field lies on a later card. The field argument indexes a valid instance
; field; the linked signed rounding sequence leaves its byte offset intact.
(declare-const raw W)
(declare-const fields W)
(declare-const field W)
(assert (and (= (bvand raw #x00000003) #x00000000) (bvule start raw) (bvult raw end)
             (bvult field fields) (bvule fields #x000007fe)
             (bvule (bvshl (bvadd fields #x00000001) #x00000002) (bvsub end raw))))
(define-fun tagged () W (bvadd raw #x00000001))
(define-fun field-off () W (bvshl (bvadd field #x00000001) #x00000002))
(define-fun rounded () W (bvand (ite (bvslt field-off #x00000000) (bvadd field-off #x00000003) field-off)
                                 #xfffffffc))
(push)
(assert (or (distinct (meta tagged) (meta raw))
            (distinct (bvsub (bvadd tagged rounded) #x00000001) (bvadd raw field-off))
            (bvult (bvadd raw field-off) (bvadd raw #x00000004))
            (bvugt (bvadd (bvadd raw field-off) #x00000004) end)
            (distinct (select (store cards (meta tagged) #x01) (meta raw)) #x01)))
(check-sat)
(pop)
; Probe induction for ONE arbitrary actual object start on a dirty card.
; At entry, earliest is an actual boundary that cannot have passed an
; unvisited start on this or a later card. A decoded earlier start lies
; before this card. Stepping by true object sizes preserves this invariant:
; by definition a partition has no start strictly inside the current span.
(reset)
(set-logic QF_LIA)
(declare-const card Int)
(declare-const probe Int)
(declare-const stop Int)
(declare-const earliest Int)
(declare-const seed Int)
(declare-const cursor Int)
(declare-const size Int)
(assert (and (<= card probe) (< probe (+ card 128)) (< probe stop)
             (<= earliest probe) (or (= seed earliest) (< seed card))))
(push)
(assert (> seed probe))
(check-sat)
(pop)
; Prefix skip loop does not visit any object and cannot skip the probe.
(push)
(assert (and (<= seed cursor) (< cursor card) (> size 0) (<= (+ cursor size) stop)
             (or (<= probe cursor) (<= (+ cursor size) probe))))
(assert (or (>= cursor stop) (> (+ cursor size) probe) (<= (+ cursor size) cursor)))
(check-sat)
(pop)
; The visit loop starts at the first start >= card, or at the sentinel.
; For this witness it cannot reach the sentinel before visiting the probe.
; Invariant: seen(cursor) is the count of visits to the probe so far.
(define-fun seen ((x Int)) Int (ite (< probe x) 1 0))
(push)
(assert (and (<= card cursor) (< cursor (+ card 128)) (< cursor stop) (> size 0)
             (<= (+ cursor size) stop) (or (<= probe cursor) (<= (+ cursor size) probe))))
(assert (or (distinct (+ (seen cursor) (ite (= cursor probe) 1 0)) (seen (+ cursor size)))
            (>= (- stop (+ cursor size)) (- stop cursor))))
(check-sat)
(pop)
(push)
(assert (or (>= cursor (+ card 128)) (= cursor stop)))
(assert (distinct (seen cursor) 1))
(check-sat)
(pop)
; For ANY later valid object start, neither forward loop steps past it.
; This also covers an object spanning several cards: encountering a dirty
; byte inside it cannot cause its payload to be interpreted as headers.
(declare-const later Int)
(push)
(assert (and (>= later (+ card 128)) (< cursor (+ card 128)) (> size 0)
             (or (<= later cursor) (<= (+ cursor size) later))))
(assert (> (+ cursor size) later))
(check-sat)
(pop)
; Record rebuilding by the linked ScavengeVisitor::do_roots body (matched
; once by a removed script; unchecked now). An ordinary untouched old slot cannot already
; refer to the fresh to-space. A repeated visit of the same slot is also
; safe if the record already includes its previously established bit.
(reset)
(set-logic QF_BV)
(define-sort W () (_ BitVec 32))
(declare-const source W)
(declare-const target W)
(declare-const old W)
(declare-const forwarding W)
(declare-const copy W)
(declare-const promoted W)
(declare-const mark W)
(declare-const prior Bool)
(declare-const promotion-ok Bool)
; Distinct aligned live 4096-byte chunks with nonwrapping ends.
(assert (and (= (bvand source #x00000fff) #x00000000) (= (bvand target #x00000fff) #x00000000)
             (bvule source #xffffe000) (bvule target #xffffe000) (distinct source target)))
(define-fun member ((a W) (base W)) Bool
  (and (bvule base a) (bvult a (bvadd base #x00001000))))
(define-fun obj ((a W)) Bool (= (bvand a #x00000003) #x00000001))
; Valid slots contain Smis or heap references; a new successful to-space
; copy is tagged inside the survivor page. A successful promotion is outside.
(assert (or (= (bvand old #x00000001) #x00000000) (obj old)))
(assert (and (obj copy) (member copy target) (obj promoted) (not (member promoted target))))
(define-fun young ((a W)) Bool (and (obj a) (member a target)))
(assert (=> (young old) prior))
(define-fun from () Bool (and (distinct (bvand old #x00000001) #x00000000)
                               (bvult (bvsub old source) #x00001000)))
(define-fun forwarded () Bool (obj forwarding))
(define-fun promote () Bool (and (bvult (bvsub old #x00000001) mark) promotion-ok))
(define-fun result () W
  (ite from (ite forwarded forwarding (ite promote promoted copy)) old))
(define-fun record () Bool
  (or prior (and from (ite forwarded (bvult (bvsub forwarding target) #x00001000) (not promote)))))
(push)
(assert (distinct record (or prior (young result))))
(check-sat)
(pop)
