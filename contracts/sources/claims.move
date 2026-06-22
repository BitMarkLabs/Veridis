// =============================================================================
// Veridis Protocol — Claims (state machine + tiered approvals)
// Target: Sui Move (2024 edition)
//
// Layer 2. Depends on access_control + identity + policy_registry.
//
// LIFECYCLE
//   SUBMITTED -(agent)-> UNDER_REVIEW -(assessor sets value)-> ASSESSED
//   ASSESSED  -(insurer approve)-> APPROVED            [Tier 1: ≤5,000€]
//   ASSESSED  -(insurer approve)-> (still ASSESSED)
//              -(compliance sign-off)-> APPROVED        [Tier 2: ≤100,000€]
//              -(compliance sign-off w/ justification)-> APPROVED  [Tier 3]
//   APPROVED -(payments)-> PAID -> CLOSED
//   UNDER_REVIEW / ASSESSED -(insurer reject)-> REJECTED -> CLOSED
//   REJECTED / APPROVED -(claimant)-> DISPUTED -(insurer)-> APPROVED | REJECTED
//
// TIERS (MVP thresholds in EUR — set by the assessor at assessment time):
//   Tier 1: value ≤ 5,000        single insurer signature
//   Tier 2: 5,000 < value ≤ 100,000  insurer + compliance (four-eyes)
//   Tier 3: value > 100,000       insurer + compliance + justification hash
// =============================================================================

module veridis::claims;

use sui::event;
use sui::clock::{Self, Clock};

use veridis::access_control::{Self, AccessRegistry, AdminCap, InsurerCap, AgentCap, AssessorCap, ComplianceCap};
use veridis::identity::{Self, IdentityRegistry, ComplianceAttestation, ConsentReceipt};
use veridis::policy_registry::{Self, PolicyRegistry, Policy};

// ===== Versioning ============================================================
const VERSION: u64 = 1;

// ===== States ================================================================
const STATE_SUBMITTED: u8 = 0;
const STATE_UNDER_REVIEW: u8 = 1;
const STATE_ASSESSED: u8 = 2;
const STATE_APPROVED: u8 = 3;
const STATE_REJECTED: u8 = 4;
const STATE_PAID: u8 = 5;
const STATE_DISPUTED: u8 = 6;
const STATE_CLOSED: u8 = 7;

// ===== Tier thresholds (EUR; MVP values — easy to change) ====================
const TIER1_MAX_EUR: u64 = 5_000;
const TIER2_MAX_EUR: u64 = 100_000;

// ===== Errors ================================================================
const EWrongVersion: u64 = 0;
const EZeroCommitment: u64 = 1;
const ENotCovered: u64 = 2;
const EConsentInvalid: u64 = 3;
const ENotClaimant: u64 = 4;
const EInvalidTransition: u64 = 5;
const EZeroAmount: u64 = 6;
const ENotUpgrade: u64 = 7;
const EZeroValue: u64 = 8;
const EAlreadyApproved: u64 = 9;
const ENoInsurerApproval: u64 = 10;
const EAlreadyComplianceSigned: u64 = 11;
const EJustificationRequired: u64 = 12;
const ENotTieredFlow: u64 = 13;

// ===== Shared registry =======================================================
public struct ClaimRegistry has key {
    id: UID,
    version: u64,
    claims_submitted: u64,
}

// ===== The claim (SHARED; no PII) ============================================
public struct Claim has key {
    id: UID,
    policy_id: ID,
    claimant: address,
    state: u8,
    peril_code: u8,
    fnol_commitment: vector<u8>,
    assessment_commitment: vector<u8>,
    decision_reason: u8,
    approved_amount: u64,

    // Tiered approvals
    claim_value_eur: u64,                 // 0 until assessment sets it
    insurer_approved: bool,
    insurer_approver: address,
    insurer_approved_at: u64,
    compliance_approved: bool,
    compliance_approver: address,
    compliance_approved_at: u64,
    justification_commitment: vector<u8>, // empty until Tier 3 sign-off

    submitted_at: u64,
    updated_at: u64,
}

// ===== Events (PII-free audit trail) =========================================
public struct ClaimSubmitted has copy, drop {
    claim_id: ID,
    policy_id: ID,
    claimant: address,
    peril_code: u8,
    submitted_at: u64,
}
public struct ClaimStateChanged has copy, drop {
    claim_id: ID,
    from_state: u8,
    to_state: u8,
    updated_at: u64,
}
public struct ClaimApproved has copy, drop { claim_id: ID, approved_amount: u64, updated_at: u64 }
public struct ClaimRejected has copy, drop { claim_id: ID, reason_code: u8, updated_at: u64 }
public struct ClaimDisputed has copy, drop { claim_id: ID, dispute_commitment: vector<u8>, updated_at: u64 }

// New tier events
public struct InsurerApprovalRecorded has copy, drop {
    claim_id: ID,
    tier: u8,
    approved_amount: u64,
    approver: address,
    updated_at: u64,
}
public struct ComplianceSignOff has copy, drop {
    claim_id: ID,
    signer: address,
    tier: u8,
    justified: bool,
    updated_at: u64,
}

// ===== Init ==================================================================
fun init(ctx: &mut TxContext) {
    transfer::share_object(ClaimRegistry {
        id: object::new(ctx),
        version: VERSION,
        claims_submitted: 0,
    });
}

fun assert_version(reg: &ClaimRegistry) {
    assert!(reg.version == VERSION, EWrongVersion);
}

fun set_state(claim: &mut Claim, to: u8, now: u64) {
    let cid = object::uid_to_inner(&claim.id);
    let from = claim.state;
    claim.state = to;
    claim.updated_at = now;
    event::emit(ClaimStateChanged { claim_id: cid, from_state: from, to_state: to, updated_at: now });
}

/// Pure: which tier does this EUR value fall into? (1, 2, or 3)
fun tier_of(value_eur: u64): u8 {
    if (value_eur <= TIER1_MAX_EUR) 1
    else if (value_eur <= TIER2_MAX_EUR) 2
    else 3
}

// ===== Submit (FNOL) =========================================================
public fun submit_claim(
    claim_reg: &mut ClaimRegistry,
    policy_reg: &PolicyRegistry,
    id_reg: &IdentityRegistry,
    policy: &Policy,
    kyc: &ComplianceAttestation,
    consent: &ConsentReceipt,
    peril_code: u8,
    fnol_commitment: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(claim_reg);
    assert!(!fnol_commitment.is_empty(), EZeroCommitment);
    let claimant = ctx.sender();

    policy_registry::assert_policy_active(policy_reg, policy, clock);
    assert!(policy_registry::policy_holder(policy) == claimant, ENotClaimant);
    assert!(policy_registry::policy_has_coverage(policy, peril_code), ENotCovered);

    identity::assert_attestation_valid(id_reg, kyc, clock);
    assert!(identity::att_subject(kyc) == claimant, ENotClaimant);

    assert!(identity::consent_subject(consent) == claimant, EConsentInvalid);
    assert!(identity::consent_purpose(consent) == identity::purpose_claims_processing(), EConsentInvalid);
    assert!(!identity::is_revoked(id_reg, object::id(consent)), EConsentInvalid);

    let now = clock::timestamp_ms(clock);
    let claim = Claim {
        id: object::new(ctx),
        policy_id: object::id(policy),
        claimant,
        state: STATE_SUBMITTED,
        peril_code,
        fnol_commitment,
        assessment_commitment: vector[],
        decision_reason: 0,
        approved_amount: 0,
        claim_value_eur: 0,
        insurer_approved: false,
        insurer_approver: @0x0,
        insurer_approved_at: 0,
        compliance_approved: false,
        compliance_approver: @0x0,
        compliance_approved_at: 0,
        justification_commitment: vector[],
        submitted_at: now,
        updated_at: now,
    };
    let cid = object::id(&claim);
    claim_reg.claims_submitted = claim_reg.claims_submitted + 1;
    event::emit(ClaimSubmitted { claim_id: cid, policy_id: claim.policy_id, claimant, peril_code, submitted_at: now });
    transfer::share_object(claim);
}

// ===== Triage (AgentCap): SUBMITTED -> UNDER_REVIEW ==========================
public fun begin_review(access_reg: &AccessRegistry, claim: &mut Claim, cap: &AgentCap, clock: &Clock) {
    access_control::assert_agent(access_reg, cap);
    assert!(claim.state == STATE_SUBMITTED, EInvalidTransition);
    set_state(claim, STATE_UNDER_REVIEW, clock::timestamp_ms(clock));
}

// ===== Assessment (AssessorCap): sets value AND commitment ===================
public fun submit_assessment(
    access_reg: &AccessRegistry,
    claim: &mut Claim,
    cap: &AssessorCap,
    assessment_commitment: vector<u8>,
    claim_value_eur: u64,
    clock: &Clock,
) {
    access_control::assert_assessor(access_reg, cap);
    assert!(claim.state == STATE_UNDER_REVIEW, EInvalidTransition);
    assert!(!assessment_commitment.is_empty(), EZeroCommitment);
    assert!(claim_value_eur > 0, EZeroValue);
    claim.assessment_commitment = assessment_commitment;
    claim.claim_value_eur = claim_value_eur;
    set_state(claim, STATE_ASSESSED, clock::timestamp_ms(clock));
}

// ===== Insurer decision (tier-aware) =========================================
/// Tier 1: claim moves to APPROVED in one call.
/// Tier 2/3: insurer approval is RECORDED but state stays ASSESSED until
/// compliance signs off.
public fun approve_claim(
    access_reg: &AccessRegistry,
    claim: &mut Claim,
    cap: &InsurerCap,
    approved_amount: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    access_control::assert_insurer(access_reg, cap);
    assert!(claim.state == STATE_ASSESSED, EInvalidTransition);
    assert!(approved_amount > 0, EZeroAmount);
    assert!(!claim.insurer_approved, EAlreadyApproved);

    let now = clock::timestamp_ms(clock);
    let tier = tier_of(claim.claim_value_eur);
    let signer = ctx.sender();

    claim.approved_amount = approved_amount;
    claim.insurer_approved = true;
    claim.insurer_approver = signer;
    claim.insurer_approved_at = now;

    if (tier == 1) {
        set_state(claim, STATE_APPROVED, now);
        event::emit(ClaimApproved { claim_id: object::id(claim), approved_amount, updated_at: now });
    } else {
        claim.updated_at = now;
        event::emit(InsurerApprovalRecorded {
            claim_id: object::id(claim),
            tier,
            approved_amount,
            approver: signer,
            updated_at: now,
        });
    }
}

/// Second sign-off (Tier 2/3 only). For Tier 3, a non-empty
/// `justification_commitment` (hash of off-chain justification doc) is required.
public fun compliance_sign_off(
    access_reg: &AccessRegistry,
    claim: &mut Claim,
    cap: &ComplianceCap,
    justification_commitment: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    access_control::assert_compliance(access_reg, cap);
    assert!(claim.state == STATE_ASSESSED, EInvalidTransition);
    assert!(claim.insurer_approved, ENoInsurerApproval);
    assert!(!claim.compliance_approved, EAlreadyComplianceSigned);

    let tier = tier_of(claim.claim_value_eur);
    assert!(tier >= 2, ENotTieredFlow); // Tier 1 doesn't need compliance

    let justified = !justification_commitment.is_empty();
    if (tier == 3) {
        assert!(justified, EJustificationRequired);
    };

    let now = clock::timestamp_ms(clock);
    let signer = ctx.sender();
    let approved_amount = claim.approved_amount;

    claim.compliance_approved = true;
    claim.compliance_approver = signer;
    claim.compliance_approved_at = now;
    claim.justification_commitment = justification_commitment;

    set_state(claim, STATE_APPROVED, now);
    event::emit(ComplianceSignOff {
        claim_id: object::id(claim),
        signer,
        tier,
        justified,
        updated_at: now,
    });
    event::emit(ClaimApproved {
        claim_id: object::id(claim),
        approved_amount,
        updated_at: now,
    });
}

// ===== Reject (InsurerCap; single-sig in v0.5) ===============================
public fun reject_claim(
    access_reg: &AccessRegistry,
    claim: &mut Claim,
    cap: &InsurerCap,
    reason_code: u8,
    clock: &Clock,
) {
    access_control::assert_insurer(access_reg, cap);
    assert!(claim.state == STATE_UNDER_REVIEW || claim.state == STATE_ASSESSED, EInvalidTransition);
    let now = clock::timestamp_ms(clock);
    claim.decision_reason = reason_code;
    set_state(claim, STATE_REJECTED, now);
    event::emit(ClaimRejected { claim_id: object::id(claim), reason_code, updated_at: now });
}

// ===== Dispute / resolve =====================================================
public fun dispute_claim(claim: &mut Claim, dispute_commitment: vector<u8>, clock: &Clock, ctx: &TxContext) {
    assert!(claim.claimant == ctx.sender(), ENotClaimant);
    assert!(claim.state == STATE_REJECTED || claim.state == STATE_APPROVED, EInvalidTransition);
    assert!(!dispute_commitment.is_empty(), EZeroCommitment);
    let now = clock::timestamp_ms(clock);
    event::emit(ClaimDisputed { claim_id: object::id(claim), dispute_commitment, updated_at: now });
    set_state(claim, STATE_DISPUTED, now);
}

public fun resolve_dispute_approve(
    access_reg: &AccessRegistry,
    claim: &mut Claim,
    cap: &InsurerCap,
    approved_amount: u64,
    clock: &Clock,
) {
    access_control::assert_insurer(access_reg, cap);
    assert!(claim.state == STATE_DISPUTED, EInvalidTransition);
    assert!(approved_amount > 0, EZeroAmount);
    let now = clock::timestamp_ms(clock);
    claim.approved_amount = approved_amount;
    set_state(claim, STATE_APPROVED, now);
    event::emit(ClaimApproved { claim_id: object::id(claim), approved_amount, updated_at: now });
}

public fun resolve_dispute_reject(
    access_reg: &AccessRegistry,
    claim: &mut Claim,
    cap: &InsurerCap,
    reason_code: u8,
    clock: &Clock,
) {
    access_control::assert_insurer(access_reg, cap);
    assert!(claim.state == STATE_DISPUTED, EInvalidTransition);
    let now = clock::timestamp_ms(clock);
    claim.decision_reason = reason_code;
    set_state(claim, STATE_REJECTED, now);
    event::emit(ClaimRejected { claim_id: object::id(claim), reason_code, updated_at: now });
}

// ===== Settlement hook (InsurerCap): APPROVED -> PAID ========================
public fun mark_paid(access_reg: &AccessRegistry, claim: &mut Claim, cap: &InsurerCap, clock: &Clock) {
    access_control::assert_insurer(access_reg, cap);
    assert!(claim.state == STATE_APPROVED, EInvalidTransition);
    set_state(claim, STATE_PAID, clock::timestamp_ms(clock));
}

// ===== Close (InsurerCap): PAID | REJECTED -> CLOSED =========================
public fun close_claim(access_reg: &AccessRegistry, claim: &mut Claim, cap: &InsurerCap, clock: &Clock) {
    access_control::assert_insurer(access_reg, cap);
    assert!(claim.state == STATE_PAID || claim.state == STATE_REJECTED, EInvalidTransition);
    set_state(claim, STATE_CLOSED, clock::timestamp_ms(clock));
}

// ===== Upgrade migration =====================================================
public fun migrate(_admin: &AdminCap, reg: &mut ClaimRegistry) {
    assert!(reg.version < VERSION, ENotUpgrade);
    reg.version = VERSION;
}

// ===== Accessors =============================================================
public fun claim_state(c: &Claim): u8 { c.state }
public fun claim_claimant(c: &Claim): address { c.claimant }
public fun claim_policy_id(c: &Claim): ID { c.policy_id }
public fun claim_peril_code(c: &Claim): u8 { c.peril_code }
public fun claim_approved_amount(c: &Claim): u64 { c.approved_amount }
public fun claim_decision_reason(c: &Claim): u8 { c.decision_reason }
public fun claim_fnol_commitment(c: &Claim): vector<u8> { c.fnol_commitment }
public fun claim_assessment_commitment(c: &Claim): vector<u8> { c.assessment_commitment }

public fun claim_value_eur(c: &Claim): u64 { c.claim_value_eur }
public fun claim_tier(c: &Claim): u8 { tier_of(c.claim_value_eur) }
public fun claim_insurer_approved(c: &Claim): bool { c.insurer_approved }
public fun claim_compliance_approved(c: &Claim): bool { c.compliance_approved }
public fun claim_justification_commitment(c: &Claim): vector<u8> { c.justification_commitment }

public fun claims_submitted(reg: &ClaimRegistry): u64 { reg.claims_submitted }
public fun version(reg: &ClaimRegistry): u64 { reg.version }

// ===== State + tier code getters =============================================
public fun state_submitted(): u8 { STATE_SUBMITTED }
public fun state_under_review(): u8 { STATE_UNDER_REVIEW }
public fun state_assessed(): u8 { STATE_ASSESSED }
public fun state_approved(): u8 { STATE_APPROVED }
public fun state_rejected(): u8 { STATE_REJECTED }
public fun state_paid(): u8 { STATE_PAID }
public fun state_disputed(): u8 { STATE_DISPUTED }
public fun state_closed(): u8 { STATE_CLOSED }

public fun tier1_max_eur(): u64 { TIER1_MAX_EUR }
public fun tier2_max_eur(): u64 { TIER2_MAX_EUR }

// ===== Test-only bootstrap ===================================================
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
