// =============================================================================
// Veridis Protocol — Access Control (FOUNDATION)
// v2: adds ComplianceCap (role 5) for tiered approvals second sign-off.
// =============================================================================

module veridis::access_control;

use sui::event;
use sui::table::{Self, Table};

const VERSION: u64 = 2;

const ROLE_INSURER: u8 = 1;
const ROLE_AGENT: u8 = 2;
const ROLE_KYC_PROVIDER: u8 = 3;
const ROLE_ASSESSOR: u8 = 4;
const ROLE_COMPLIANCE: u8 = 5;

const EWrongVersion: u64 = 0;
const ECapNotFound: u64 = 1;
const ECapRevoked: u64 = 2;
const EAlreadyRevoked: u64 = 3;
const ENotUpgrade: u64 = 4;

public struct AdminCap has key, store { id: UID }

public struct InsurerCap has key { id: UID }
public struct AgentCap has key { id: UID }
public struct KYCProviderCap has key { id: UID }
public struct AssessorCap has key { id: UID }
public struct ComplianceCap has key { id: UID }

public struct AccessRegistry has key {
    id: UID,
    version: u64,
    caps: Table<ID, CapRecord>,
}

public struct CapRecord has store, copy, drop {
    role: u8,
    holder: address,
    active: bool,
    granted_at_epoch: u64,
}

public struct RoleGranted has copy, drop {
    cap_id: ID,
    role: u8,
    holder: address,
    epoch: u64,
}
public struct RoleRevoked has copy, drop {
    cap_id: ID,
    role: u8,
    holder: address,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(AccessRegistry {
        id: object::new(ctx),
        version: VERSION,
        caps: table::new(ctx),
    });
}

fun assert_version(reg: &AccessRegistry) {
    assert!(reg.version == VERSION, EWrongVersion);
}

fun record_and_emit(
    reg: &mut AccessRegistry,
    cap_id: ID,
    role: u8,
    holder: address,
    epoch: u64,
) {
    reg.caps.add(cap_id, CapRecord { role, holder, active: true, granted_at_epoch: epoch });
    event::emit(RoleGranted { cap_id, role, holder, epoch });
}

fun assert_active(reg: &AccessRegistry, cap_id: ID, expected_role: u8) {
    assert!(reg.caps.contains(cap_id), ECapNotFound);
    let rec = reg.caps.borrow(cap_id);
    assert!(rec.active, ECapRevoked);
    assert!(rec.role == expected_role, ECapRevoked);
}

public fun grant_insurer(_admin: &AdminCap, reg: &mut AccessRegistry, holder: address, ctx: &mut TxContext) {
    assert_version(reg);
    let cap = InsurerCap { id: object::new(ctx) };
    record_and_emit(reg, object::id(&cap), ROLE_INSURER, holder, ctx.epoch());
    transfer::transfer(cap, holder);
}

public fun grant_agent(_admin: &AdminCap, reg: &mut AccessRegistry, holder: address, ctx: &mut TxContext) {
    assert_version(reg);
    let cap = AgentCap { id: object::new(ctx) };
    record_and_emit(reg, object::id(&cap), ROLE_AGENT, holder, ctx.epoch());
    transfer::transfer(cap, holder);
}

public fun grant_kyc_provider(_admin: &AdminCap, reg: &mut AccessRegistry, holder: address, ctx: &mut TxContext) {
    assert_version(reg);
    let cap = KYCProviderCap { id: object::new(ctx) };
    record_and_emit(reg, object::id(&cap), ROLE_KYC_PROVIDER, holder, ctx.epoch());
    transfer::transfer(cap, holder);
}

public fun grant_assessor(_admin: &AdminCap, reg: &mut AccessRegistry, holder: address, ctx: &mut TxContext) {
    assert_version(reg);
    let cap = AssessorCap { id: object::new(ctx) };
    record_and_emit(reg, object::id(&cap), ROLE_ASSESSOR, holder, ctx.epoch());
    transfer::transfer(cap, holder);
}

public fun grant_compliance(_admin: &AdminCap, reg: &mut AccessRegistry, holder: address, ctx: &mut TxContext) {
    assert_version(reg);
    let cap = ComplianceCap { id: object::new(ctx) };
    record_and_emit(reg, object::id(&cap), ROLE_COMPLIANCE, holder, ctx.epoch());
    transfer::transfer(cap, holder);
}

public fun revoke(_admin: &AdminCap, reg: &mut AccessRegistry, cap_id: ID) {
    assert_version(reg);
    assert!(reg.caps.contains(cap_id), ECapNotFound);
    let rec = reg.caps.borrow_mut(cap_id);
    assert!(rec.active, EAlreadyRevoked);
    rec.active = false;
    event::emit(RoleRevoked { cap_id, role: rec.role, holder: rec.holder });
}

public fun assert_insurer(reg: &AccessRegistry, cap: &InsurerCap) {
    assert_version(reg);
    assert_active(reg, object::id(cap), ROLE_INSURER);
}
public fun assert_agent(reg: &AccessRegistry, cap: &AgentCap) {
    assert_version(reg);
    assert_active(reg, object::id(cap), ROLE_AGENT);
}
public fun assert_kyc_provider(reg: &AccessRegistry, cap: &KYCProviderCap) {
    assert_version(reg);
    assert_active(reg, object::id(cap), ROLE_KYC_PROVIDER);
}
public fun assert_assessor(reg: &AccessRegistry, cap: &AssessorCap) {
    assert_version(reg);
    assert_active(reg, object::id(cap), ROLE_ASSESSOR);
}
public fun assert_compliance(reg: &AccessRegistry, cap: &ComplianceCap) {
    assert_version(reg);
    assert_active(reg, object::id(cap), ROLE_COMPLIANCE);
}

public fun migrate(_admin: &AdminCap, reg: &mut AccessRegistry) {
    assert!(reg.version < VERSION, ENotUpgrade);
    reg.version = VERSION;
}

public fun is_cap_active(reg: &AccessRegistry, cap_id: ID): bool {
    if (!reg.caps.contains(cap_id)) return false;
    reg.caps.borrow(cap_id).active
}
public fun version(reg: &AccessRegistry): u64 { reg.version }

public fun role_insurer(): u8 { ROLE_INSURER }
public fun role_agent(): u8 { ROLE_AGENT }
public fun role_kyc_provider(): u8 { ROLE_KYC_PROVIDER }
public fun role_assessor(): u8 { ROLE_ASSESSOR }
public fun role_compliance(): u8 { ROLE_COMPLIANCE }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
