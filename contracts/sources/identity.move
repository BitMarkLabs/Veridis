// =============================================================================
// Veridis Protocol — Identity, KYC & Compliance Attestations
// Target: Sui Move (2024 edition)
//
// Layer 1 (Core service). Depends ONLY on access_control.
// Soulbound, PII-free attestations + GDPR consent receipts.
// =============================================================================

module veridis::identity;

use sui::event;
use sui::table::{Self, Table};
use sui::clock::{Self, Clock};

use veridis::access_control::{Self, AccessRegistry, AdminCap, KYCProviderCap};

// ===== Versioning ============================================================
const VERSION: u64 = 1;

// ===== Attestation kinds =====================================================
const KIND_KYC_TIER1: u8 = 1;
const KIND_KYC_TIER2: u8 = 2;
const KIND_AML_CLEARED: u8 = 10;
const KIND_SANCTIONS_CLEARED: u8 = 11;
const KIND_ASSESSOR_LICENSE: u8 = 20;
const KIND_REGULATORY: u8 = 30;

// ===== Consent purposes ======================================================
const PURPOSE_CLAIMS_PROCESSING: u8 = 1;
const PURPOSE_EVIDENCE_TRANSFER: u8 = 2;
const PURPOSE_PAYOUT: u8 = 3;

// ===== Errors ================================================================
const EWrongVersion: u64 = 0;
const EZeroCommitment: u64 = 1;
const EExpiryInPast: u64 = 2;
const ENotSubject: u64 = 3;
const EAlreadyRevoked: u64 = 4;
const ERevoked: u64 = 5;
const EExpired: u64 = 6;
const ENotUpgrade: u64 = 7;

// ===== Shared registry =======================================================
public struct IdentityRegistry has key {
    id: UID,
    version: u64,
    revoked: Table<ID, RevocationRecord>,
    attestations_issued: u64,
    consents_issued: u64,
}

public struct RevocationRecord has store, copy, drop {
    revoked_at: u64,
    reason_code: u8,
}

// ===== Soulbound objects =====================================================
public struct ComplianceAttestation has key {
    id: UID,
    subject: address,
    issuer: address,
    kind: u8,
    commitment: vector<u8>,
    schema_version: u16,
    issued_at: u64,
    expires_at: u64,
}

public struct ConsentReceipt has key {
    id: UID,
    subject: address,
    insurer: address,
    purpose: u8,
    consent_commitment: vector<u8>,
    policy_version: u16,
    data_categories: vector<u8>,
    retention_days: u32,
    issued_at: u64,
    expires_at: u64,
}

// ===== Events ================================================================
public struct AttestationIssued has copy, drop {
    attestation_id: ID,
    subject: address,
    issuer: address,
    kind: u8,
    issued_at: u64,
    expires_at: u64,
}
public struct AttestationRevoked has copy, drop {
    attestation_id: ID,
    revoked_at: u64,
    reason_code: u8,
}
public struct AttestationBurned has copy, drop {
    attestation_id: ID,
    subject: address,
    burned_at: u64,
}
public struct ConsentGranted has copy, drop {
    receipt_id: ID,
    subject: address,
    insurer: address,
    purpose: u8,
    issued_at: u64,
}
public struct ConsentRevoked has copy, drop {
    receipt_id: ID,
    revoked_at: u64,
}

// ===== Init ==================================================================
fun init(ctx: &mut TxContext) {
    transfer::share_object(IdentityRegistry {
        id: object::new(ctx),
        version: VERSION,
        revoked: table::new(ctx),
        attestations_issued: 0,
        consents_issued: 0,
    });
}

fun assert_version(reg: &IdentityRegistry) {
    assert!(reg.version == VERSION, EWrongVersion);
}

// ===== Issuance ==============================================================
public fun issue_attestation(
    access_reg: &AccessRegistry,
    reg: &mut IdentityRegistry,
    cap: &KYCProviderCap,
    subject: address,
    kind: u8,
    commitment: vector<u8>,
    schema_version: u16,
    expires_at: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(reg);
    access_control::assert_kyc_provider(access_reg, cap);
    assert!(!commitment.is_empty(), EZeroCommitment);
    let now = clock::timestamp_ms(clock);
    if (expires_at != 0) assert!(expires_at > now, EExpiryInPast);

    let issuer = ctx.sender();
    let att = ComplianceAttestation {
        id: object::new(ctx),
        subject,
        issuer,
        kind,
        commitment,
        schema_version,
        issued_at: now,
        expires_at,
    };
    let aid = object::id(&att);
    reg.attestations_issued = reg.attestations_issued + 1;
    event::emit(AttestationIssued { attestation_id: aid, subject, issuer, kind, issued_at: now, expires_at });
    transfer::transfer(att, subject);
}

public fun grant_consent(
    reg: &mut IdentityRegistry,
    insurer: address,
    purpose: u8,
    consent_commitment: vector<u8>,
    policy_version: u16,
    data_categories: vector<u8>,
    retention_days: u32,
    expires_at: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(reg);
    assert!(!consent_commitment.is_empty(), EZeroCommitment);
    let now = clock::timestamp_ms(clock);
    if (expires_at != 0) assert!(expires_at > now, EExpiryInPast);

    let subject = ctx.sender();
    let receipt = ConsentReceipt {
        id: object::new(ctx),
        subject,
        insurer,
        purpose,
        consent_commitment,
        policy_version,
        data_categories,
        retention_days,
        issued_at: now,
        expires_at,
    };
    let rid = object::id(&receipt);
    reg.consents_issued = reg.consents_issued + 1;
    event::emit(ConsentGranted { receipt_id: rid, subject, insurer, purpose, issued_at: now });
    transfer::transfer(receipt, subject);
}

// ===== Revocation ============================================================
public fun revoke_attestation(
    access_reg: &AccessRegistry,
    reg: &mut IdentityRegistry,
    cap: &KYCProviderCap,
    attestation_id: ID,
    reason_code: u8,
    clock: &Clock,
) {
    assert_version(reg);
    access_control::assert_kyc_provider(access_reg, cap);
    assert!(!reg.revoked.contains(attestation_id), EAlreadyRevoked);
    let now = clock::timestamp_ms(clock);
    reg.revoked.add(attestation_id, RevocationRecord { revoked_at: now, reason_code });
    event::emit(AttestationRevoked { attestation_id, revoked_at: now, reason_code });
}

public fun withdraw_consent(
    reg: &mut IdentityRegistry,
    receipt: &ConsentReceipt,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_version(reg);
    assert!(receipt.subject == ctx.sender(), ENotSubject);
    let rid = object::id(receipt);
    assert!(!reg.revoked.contains(rid), EAlreadyRevoked);
    let now = clock::timestamp_ms(clock);
    reg.revoked.add(rid, RevocationRecord { revoked_at: now, reason_code: 0 });
    event::emit(ConsentRevoked { receipt_id: rid, revoked_at: now });
}

// ===== Burn ==================================================================
public fun burn_attestation(att: ComplianceAttestation, clock: &Clock, ctx: &TxContext) {
    assert!(att.subject == ctx.sender(), ENotSubject);
    let ComplianceAttestation {
        id, subject, issuer: _, kind: _, commitment: _, schema_version: _, issued_at: _, expires_at: _,
    } = att;
    let aid = object::uid_to_inner(&id);
    event::emit(AttestationBurned { attestation_id: aid, subject, burned_at: clock::timestamp_ms(clock) });
    object::delete(id);
}

// ===== Verification ==========================================================
public fun is_attestation_valid(reg: &IdentityRegistry, att: &ComplianceAttestation, clock: &Clock): bool {
    if (reg.revoked.contains(object::id(att))) return false;
    let now = clock::timestamp_ms(clock);
    if (att.expires_at != 0 && now >= att.expires_at) return false;
    true
}

public fun assert_attestation_valid(reg: &IdentityRegistry, att: &ComplianceAttestation, clock: &Clock) {
    assert!(!reg.revoked.contains(object::id(att)), ERevoked);
    let now = clock::timestamp_ms(clock);
    assert!(att.expires_at == 0 || now < att.expires_at, EExpired);
}

public fun is_revoked(reg: &IdentityRegistry, id: ID): bool {
    reg.revoked.contains(id)
}

// ===== Migration =============================================================
public fun migrate(_admin: &AdminCap, reg: &mut IdentityRegistry) {
    assert!(reg.version < VERSION, ENotUpgrade);
    reg.version = VERSION;
}

// ===== Accessors =============================================================
public fun att_subject(att: &ComplianceAttestation): address { att.subject }
public fun att_issuer(att: &ComplianceAttestation): address { att.issuer }
public fun att_kind(att: &ComplianceAttestation): u8 { att.kind }
public fun att_commitment(att: &ComplianceAttestation): vector<u8> { att.commitment }
public fun att_expires_at(att: &ComplianceAttestation): u64 { att.expires_at }

public fun consent_subject(r: &ConsentReceipt): address { r.subject }
public fun consent_insurer(r: &ConsentReceipt): address { r.insurer }
public fun consent_purpose(r: &ConsentReceipt): u8 { r.purpose }

public fun attestations_issued(reg: &IdentityRegistry): u64 { reg.attestations_issued }
public fun consents_issued(reg: &IdentityRegistry): u64 { reg.consents_issued }
public fun version(reg: &IdentityRegistry): u64 { reg.version }

// ===== Kind / purpose getters ================================================
public fun kind_kyc_tier1(): u8 { KIND_KYC_TIER1 }
public fun kind_kyc_tier2(): u8 { KIND_KYC_TIER2 }
public fun kind_aml_cleared(): u8 { KIND_AML_CLEARED }
public fun kind_sanctions_cleared(): u8 { KIND_SANCTIONS_CLEARED }
public fun kind_assessor_license(): u8 { KIND_ASSESSOR_LICENSE }
public fun kind_regulatory(): u8 { KIND_REGULATORY }

public fun purpose_claims_processing(): u8 { PURPOSE_CLAIMS_PROCESSING }
public fun purpose_evidence_transfer(): u8 { PURPOSE_EVIDENCE_TRANSFER }
public fun purpose_payout(): u8 { PURPOSE_PAYOUT }

// ===== Test-only =============================================================
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
