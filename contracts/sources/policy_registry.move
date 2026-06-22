// =============================================================================
// Veridis Protocol — Policy Registry
// Target: Sui Move (2024 edition)
// Layer 1 (Core service). Depends ONLY on access_control.
// Owned Policy proof-of-coverage + shared lifecycle registry. No PII, no amounts.
// =============================================================================

module veridis::policy_registry;

use sui::event;
use sui::table::{Self, Table};
use sui::clock::{Self, Clock};

use veridis::access_control::{Self, AccessRegistry, AdminCap, InsurerCap};

const VERSION: u64 = 1;

const STATUS_ACTIVE: u8 = 0;
const STATUS_SUSPENDED: u8 = 1;
const STATUS_CANCELLED: u8 = 2;

const EWrongVersion: u64 = 0;
const EZeroCommitment: u64 = 1;
const EInvalidPeriod: u64 = 2;
const EPolicyNotFound: u64 = 3;
const EPolicyNotActive: u64 = 4;
const EPolicyExpired: u64 = 5;
const EAlreadyCancelled: u64 = 6;
const ENotUpgrade: u64 = 7;

public struct PolicyRegistry has key {
    id: UID,
    version: u64,
    records: Table<ID, PolicyStatusRecord>,
    policies_issued: u64,
}

public struct PolicyStatusRecord has store, copy, drop {
    status: u8,
    valid_from: u64,
    valid_until: u64,
    updated_at: u64,
}

public struct Policy has key {
    id: UID,
    holder: address,
    insurer: address,
    product_code: u16,
    coverage_codes: vector<u8>,
    commitment: vector<u8>,
    schema_version: u16,
    issued_at: u64,
}

public struct PolicyIssued has copy, drop {
    policy_id: ID,
    holder: address,
    insurer: address,
    product_code: u16,
    valid_from: u64,
    valid_until: u64,
    issued_at: u64,
}
public struct PolicyRenewed has copy, drop { policy_id: ID, new_valid_until: u64, updated_at: u64 }
public struct PolicySuspended has copy, drop { policy_id: ID, updated_at: u64 }
public struct PolicyReinstated has copy, drop { policy_id: ID, updated_at: u64 }
public struct PolicyCancelled has copy, drop { policy_id: ID, reason_code: u8, updated_at: u64 }

fun init(ctx: &mut TxContext) {
    transfer::share_object(PolicyRegistry {
        id: object::new(ctx),
        version: VERSION,
        records: table::new(ctx),
        policies_issued: 0,
    });
}

fun assert_version(reg: &PolicyRegistry) {
    assert!(reg.version == VERSION, EWrongVersion);
}

public fun issue_policy(
    access_reg: &AccessRegistry,
    reg: &mut PolicyRegistry,
    cap: &InsurerCap,
    holder: address,
    product_code: u16,
    coverage_codes: vector<u8>,
    commitment: vector<u8>,
    schema_version: u16,
    valid_from: u64,
    valid_until: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(reg);
    access_control::assert_insurer(access_reg, cap);
    assert!(!commitment.is_empty(), EZeroCommitment);
    assert!(valid_until > valid_from, EInvalidPeriod);

    let now = clock::timestamp_ms(clock);
    let insurer = ctx.sender();
    let policy = Policy {
        id: object::new(ctx),
        holder,
        insurer,
        product_code,
        coverage_codes,
        commitment,
        schema_version,
        issued_at: now,
    };
    let pid = object::id(&policy);
    reg.records.add(pid, PolicyStatusRecord { status: STATUS_ACTIVE, valid_from, valid_until, updated_at: now });
    reg.policies_issued = reg.policies_issued + 1;
    event::emit(PolicyIssued { policy_id: pid, holder, insurer, product_code, valid_from, valid_until, issued_at: now });
    transfer::transfer(policy, holder);
}

public fun renew_policy(
    access_reg: &AccessRegistry,
    reg: &mut PolicyRegistry,
    cap: &InsurerCap,
    policy_id: ID,
    new_valid_until: u64,
    clock: &Clock,
) {
    assert_version(reg);
    access_control::assert_insurer(access_reg, cap);
    assert!(reg.records.contains(policy_id), EPolicyNotFound);
    let now = clock::timestamp_ms(clock);
    let rec = reg.records.borrow_mut(policy_id);
    assert!(rec.status != STATUS_CANCELLED, EAlreadyCancelled);
    assert!(new_valid_until > rec.valid_until, EInvalidPeriod);
    rec.valid_until = new_valid_until;
    rec.status = STATUS_ACTIVE;
    rec.updated_at = now;
    event::emit(PolicyRenewed { policy_id, new_valid_until, updated_at: now });
}

public fun suspend_policy(
    access_reg: &AccessRegistry,
    reg: &mut PolicyRegistry,
    cap: &InsurerCap,
    policy_id: ID,
    clock: &Clock,
) {
    assert_version(reg);
    access_control::assert_insurer(access_reg, cap);
    assert!(reg.records.contains(policy_id), EPolicyNotFound);
    let now = clock::timestamp_ms(clock);
    let rec = reg.records.borrow_mut(policy_id);
    assert!(rec.status != STATUS_CANCELLED, EAlreadyCancelled);
    rec.status = STATUS_SUSPENDED;
    rec.updated_at = now;
    event::emit(PolicySuspended { policy_id, updated_at: now });
}

public fun reinstate_policy(
    access_reg: &AccessRegistry,
    reg: &mut PolicyRegistry,
    cap: &InsurerCap,
    policy_id: ID,
    clock: &Clock,
) {
    assert_version(reg);
    access_control::assert_insurer(access_reg, cap);
    assert!(reg.records.contains(policy_id), EPolicyNotFound);
    let now = clock::timestamp_ms(clock);
    let rec = reg.records.borrow_mut(policy_id);
    assert!(rec.status != STATUS_CANCELLED, EAlreadyCancelled);
    rec.status = STATUS_ACTIVE;
    rec.updated_at = now;
    event::emit(PolicyReinstated { policy_id, updated_at: now });
}

public fun cancel_policy(
    access_reg: &AccessRegistry,
    reg: &mut PolicyRegistry,
    cap: &InsurerCap,
    policy_id: ID,
    reason_code: u8,
    clock: &Clock,
) {
    assert_version(reg);
    access_control::assert_insurer(access_reg, cap);
    assert!(reg.records.contains(policy_id), EPolicyNotFound);
    let now = clock::timestamp_ms(clock);
    let rec = reg.records.borrow_mut(policy_id);
    assert!(rec.status != STATUS_CANCELLED, EAlreadyCancelled);
    rec.status = STATUS_CANCELLED;
    rec.updated_at = now;
    event::emit(PolicyCancelled { policy_id, reason_code, updated_at: now });
}

public fun assert_policy_active(reg: &PolicyRegistry, policy: &Policy, clock: &Clock) {
    assert_version(reg);
    let pid = object::id(policy);
    assert!(reg.records.contains(pid), EPolicyNotFound);
    let rec = reg.records.borrow(pid);
    assert!(rec.status == STATUS_ACTIVE, EPolicyNotActive);
    let now = clock::timestamp_ms(clock);
    assert!(now >= rec.valid_from && now < rec.valid_until, EPolicyExpired);
}

public fun is_policy_active(reg: &PolicyRegistry, policy: &Policy, clock: &Clock): bool {
    let pid = object::id(policy);
    if (!reg.records.contains(pid)) return false;
    let rec = reg.records.borrow(pid);
    if (rec.status != STATUS_ACTIVE) return false;
    let now = clock::timestamp_ms(clock);
    now >= rec.valid_from && now < rec.valid_until
}

public fun policy_has_coverage(policy: &Policy, code: u8): bool {
    policy.coverage_codes.contains(&code)
}

public fun migrate(_admin: &AdminCap, reg: &mut PolicyRegistry) {
    assert!(reg.version < VERSION, ENotUpgrade);
    reg.version = VERSION;
}

public fun policy_holder(p: &Policy): address { p.holder }
public fun policy_insurer(p: &Policy): address { p.insurer }
public fun policy_product_code(p: &Policy): u16 { p.product_code }
public fun policy_coverage_codes(p: &Policy): vector<u8> { p.coverage_codes }
public fun policy_commitment(p: &Policy): vector<u8> { p.commitment }
public fun policy_issued_at(p: &Policy): u64 { p.issued_at }

public fun policy_status(reg: &PolicyRegistry, policy_id: ID): u8 {
    assert!(reg.records.contains(policy_id), EPolicyNotFound);
    reg.records.borrow(policy_id).status
}
public fun policies_issued(reg: &PolicyRegistry): u64 { reg.policies_issued }
public fun version(reg: &PolicyRegistry): u64 { reg.version }

public fun status_active(): u8 { STATUS_ACTIVE }
public fun status_suspended(): u8 { STATUS_SUSPENDED }
public fun status_cancelled(): u8 { STATUS_CANCELLED }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
