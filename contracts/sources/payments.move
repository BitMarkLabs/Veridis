// =============================================================================
// Veridis Protocol — Payments (escrow & settlement)
// Target: Sui Move (2024 edition)
//
// Layer 3 (Settlement). Depends on access_control + claims.
//
// MODEL
//   * EscrowVault<T> — SHARED, generic over the coin type T (a test coin now,
//     real SUI later, no code change). Holds the insurer's payout funds.
//   * settle_claim — pays the claimant the approved amount AND calls
//     claims::mark_paid in the SAME transaction. Atomic: either the payout and
//     the APPROVED->PAID transition both happen, or neither does.
//   * PaymentReceipt — soulbound (key-only) proof-of-settlement for the payee.
//
// No PII on-chain. Amounts are settlement figures, not personal data.
// =============================================================================

module veridis::payments;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::clock::{Self, Clock};

use veridis::access_control::{Self, AccessRegistry, AdminCap, InsurerCap};
use veridis::claims::{Self, Claim};

// ===== Versioning ============================================================
const VERSION: u64 = 1;

// ===== Errors ================================================================
const EWrongVersion: u64 = 0;
const EInsufficientFunds: u64 = 1;
const EClaimNotApproved: u64 = 2;
const EZeroAmount: u64 = 3;
const ENotUpgrade: u64 = 4;

// ===== Shared escrow vault (generic over coin type) ==========================
public struct EscrowVault<phantom T> has key {
    id: UID,
    version: u64,
    funds: Balance<T>,
    total_settled: u64,
    settlements_count: u64,
}

// ===== Soulbound proof-of-settlement (owned by payee) ========================
public struct PaymentReceipt has key {
    id: UID,
    claim_id: ID,
    payee: address,
    amount: u64,
    settled_at: u64,
}

// ===== Events (PII-free audit trail) =========================================
public struct VaultCreated has copy, drop { vault_id: ID, by: address }
public struct VaultFunded has copy, drop { vault_id: ID, amount: u64, new_balance: u64 }
public struct VaultWithdrawn has copy, drop { vault_id: ID, amount: u64, new_balance: u64 }
public struct PaymentSettled has copy, drop {
    receipt_id: ID,
    claim_id: ID,
    payee: address,
    amount: u64,
    settled_at: u64,
}

// ===== Vault lifecycle (InsurerCap-gated) ====================================
public fun create_vault<T>(access_reg: &AccessRegistry, cap: &InsurerCap, ctx: &mut TxContext) {
    access_control::assert_insurer(access_reg, cap);
    let vault = EscrowVault<T> {
        id: object::new(ctx),
        version: VERSION,
        funds: balance::zero<T>(),
        total_settled: 0,
        settlements_count: 0,
    };
    event::emit(VaultCreated { vault_id: object::id(&vault), by: ctx.sender() });
    transfer::share_object(vault);
}

public fun fund_vault<T>(
    access_reg: &AccessRegistry,
    vault: &mut EscrowVault<T>,
    cap: &InsurerCap,
    payment: Coin<T>,
) {
    access_control::assert_insurer(access_reg, cap);
    assert!(vault.version == VERSION, EWrongVersion);
    let amount = coin::value(&payment);
    assert!(amount > 0, EZeroAmount);
    balance::join(&mut vault.funds, coin::into_balance(payment));
    event::emit(VaultFunded { vault_id: object::id(vault), amount, new_balance: balance::value(&vault.funds) });
}

public fun withdraw_vault<T>(
    access_reg: &AccessRegistry,
    vault: &mut EscrowVault<T>,
    cap: &InsurerCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    access_control::assert_insurer(access_reg, cap);
    assert!(vault.version == VERSION, EWrongVersion);
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&vault.funds) >= amount, EInsufficientFunds);
    let c = coin::take(&mut vault.funds, amount, ctx);
    event::emit(VaultWithdrawn { vault_id: object::id(vault), amount, new_balance: balance::value(&vault.funds) });
    c
}

// ===== Settlement (atomic payout + APPROVED -> PAID) =========================
public fun settle_claim<T>(
    access_reg: &AccessRegistry,
    vault: &mut EscrowVault<T>,
    claim: &mut Claim,
    cap: &InsurerCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    access_control::assert_insurer(access_reg, cap);
    assert!(vault.version == VERSION, EWrongVersion);
    assert!(claims::claim_state(claim) == claims::state_approved(), EClaimNotApproved);

    let amount = claims::claim_approved_amount(claim);
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&vault.funds) >= amount, EInsufficientFunds);

    let claim_id = object::id(claim);
    let payee = claims::claim_claimant(claim);
    let now = clock::timestamp_ms(clock);

    // 1) Pay the claimant.
    let payout = coin::take(&mut vault.funds, amount, ctx);
    transfer::public_transfer(payout, payee);

    // 2) Transition the claim APPROVED -> PAID (same transaction = atomic).
    claims::mark_paid(access_reg, claim, cap, clock);

    // 3) Soulbound proof-of-settlement to the payee.
    vault.total_settled = vault.total_settled + amount;
    vault.settlements_count = vault.settlements_count + 1;
    let receipt = PaymentReceipt {
        id: object::new(ctx),
        claim_id,
        payee,
        amount,
        settled_at: now,
    };
    event::emit(PaymentSettled { receipt_id: object::id(&receipt), claim_id, payee, amount, settled_at: now });
    transfer::transfer(receipt, payee);
}

// ===== Upgrade migration (AdminCap-gated) ====================================
public fun migrate<T>(_admin: &AdminCap, vault: &mut EscrowVault<T>) {
    assert!(vault.version < VERSION, ENotUpgrade);
    vault.version = VERSION;
}

// ===== Accessors =============================================================
public fun vault_balance<T>(vault: &EscrowVault<T>): u64 { balance::value(&vault.funds) }
public fun total_settled<T>(vault: &EscrowVault<T>): u64 { vault.total_settled }
public fun settlements_count<T>(vault: &EscrowVault<T>): u64 { vault.settlements_count }
public fun vault_version<T>(vault: &EscrowVault<T>): u64 { vault.version }

public fun receipt_claim_id(r: &PaymentReceipt): ID { r.claim_id }
public fun receipt_payee(r: &PaymentReceipt): address { r.payee }
public fun receipt_amount(r: &PaymentReceipt): u64 { r.amount }
public fun receipt_settled_at(r: &PaymentReceipt): u64 { r.settled_at }