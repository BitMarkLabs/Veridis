// =============================================================================
// Veridis Protocol — Negative tests (invariant locks)
// Each test passes ONLY if the operation aborts with the expected error code
// from the expected module.
// =============================================================================

#[test_only]
module veridis::veridis_negative_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::clock::{Self, Clock};

use veridis::access_control::{Self, AdminCap, AccessRegistry, InsurerCap, KYCProviderCap};
use veridis::identity::{Self, IdentityRegistry, ComplianceAttestation, ConsentReceipt};
use veridis::policy_registry::{Self, PolicyRegistry, Policy};
use veridis::claims::{Self, ClaimRegistry, Claim};
use veridis::payments::{Self, EscrowVault};
use sui::sui::SUI;
use sui::coin;

const ADMIN: address = @0xA;
const INSURER: address = @0xB;
const AGENT: address = @0xC;
const ASSESSOR: address = @0xD;
const KYC: address = @0xE;
const CUSTOMER: address = @0xF;

const NOW_MS: u64 = 1_000_000;

fun bootstrap_and_grant(scenario: &mut Scenario) {
    {
        access_control::init_for_testing(scenario.ctx());
        identity::init_for_testing(scenario.ctx());
        policy_registry::init_for_testing(scenario.ctx());
        claims::init_for_testing(scenario.ctx());
    };
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut access_reg = scenario.take_shared<AccessRegistry>();
        access_control::grant_insurer(&admin_cap, &mut access_reg, INSURER, scenario.ctx());
        access_control::grant_agent(&admin_cap, &mut access_reg, AGENT, scenario.ctx());
        access_control::grant_assessor(&admin_cap, &mut access_reg, ASSESSOR, scenario.ctx());
        access_control::grant_kyc_provider(&admin_cap, &mut access_reg, KYC, scenario.ctx());
        scenario.return_to_sender(admin_cap);
        ts::return_shared(access_reg);
    };
}

fun provision_customer(scenario: &mut Scenario, clock: &Clock, coverage: vector<u8>) {
    scenario.next_tx(KYC);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut id_reg = scenario.take_shared<IdentityRegistry>();
        let kyc_cap = scenario.take_from_sender<KYCProviderCap>();
        identity::issue_attestation(&access_reg, &mut id_reg, &kyc_cap, CUSTOMER, identity::kind_kyc_tier1(), b"kyc", 1, 0, clock, scenario.ctx());
        scenario.return_to_sender(kyc_cap);
        ts::return_shared(id_reg);
        ts::return_shared(access_reg);
    };
    scenario.next_tx(CUSTOMER);
    {
        let mut id_reg = scenario.take_shared<IdentityRegistry>();
        identity::grant_consent(&mut id_reg, INSURER, identity::purpose_claims_processing(), b"consent", 1, b"cat", 365, 0, clock, scenario.ctx());
        ts::return_shared(id_reg);
    };
    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut policy_reg = scenario.take_shared<PolicyRegistry>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        policy_registry::issue_policy(&access_reg, &mut policy_reg, &ins_cap, CUSTOMER, 1, coverage, b"policy", 1, 0, 10_000_000, clock, scenario.ctx());
        scenario.return_to_sender(ins_cap);
        ts::return_shared(policy_reg);
        ts::return_shared(access_reg);
    };
}

fun submit_claim_helper(scenario: &mut Scenario, clock: &Clock, peril: u8) {
    scenario.next_tx(CUSTOMER);
    {
        let mut claim_reg = scenario.take_shared<ClaimRegistry>();
        let policy_reg = scenario.take_shared<PolicyRegistry>();
        let id_reg = scenario.take_shared<IdentityRegistry>();
        let policy = scenario.take_from_sender<Policy>();
        let kyc = scenario.take_from_sender<ComplianceAttestation>();
        let consent = scenario.take_from_sender<ConsentReceipt>();
        claims::submit_claim(&mut claim_reg, &policy_reg, &id_reg, &policy, &kyc, &consent, peril, b"fnol", clock, scenario.ctx());
        scenario.return_to_sender(policy);
        scenario.return_to_sender(kyc);
        scenario.return_to_sender(consent);
        ts::return_shared(id_reg);
        ts::return_shared(policy_reg);
        ts::return_shared(claim_reg);
    };
}

// 1) Revoked KYC provider cannot issue
#[test]
#[expected_failure(abort_code = 2, location = veridis::access_control)]
fun revoked_kyc_provider_cannot_issue() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, NOW_MS);
    bootstrap_and_grant(&mut scenario);

    scenario.next_tx(KYC);
    let kyc_cap_id = {
        let cap = scenario.take_from_sender<KYCProviderCap>();
        let id = object::id(&cap);
        scenario.return_to_sender(cap);
        id
    };

    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut access_reg = scenario.take_shared<AccessRegistry>();
        access_control::revoke(&admin_cap, &mut access_reg, kyc_cap_id);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(access_reg);
    };

    scenario.next_tx(KYC);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut id_reg = scenario.take_shared<IdentityRegistry>();
        let kyc_cap = scenario.take_from_sender<KYCProviderCap>();
        identity::issue_attestation(&access_reg, &mut id_reg, &kyc_cap, CUSTOMER, identity::kind_kyc_tier1(), b"x", 1, 0, &clock, scenario.ctx());
        scenario.return_to_sender(kyc_cap);
        ts::return_shared(id_reg);
        ts::return_shared(access_reg);
    };

    clock::destroy_for_testing(clock);
    scenario.end();
}

// 2) Submitting for an uncovered peril fails
#[test]
#[expected_failure(abort_code = 2, location = veridis::claims)]
fun submit_uncovered_peril_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, NOW_MS);
    bootstrap_and_grant(&mut scenario);
    provision_customer(&mut scenario, &clock, vector[27u8]);
    submit_claim_helper(&mut scenario, &clock, 19);

    clock::destroy_for_testing(clock);
    scenario.end();
}

// 3) Submitting on a cancelled policy fails
#[test]
#[expected_failure(abort_code = 4, location = veridis::policy_registry)]
fun submit_on_cancelled_policy_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, NOW_MS);
    bootstrap_and_grant(&mut scenario);
    provision_customer(&mut scenario, &clock, vector[19u8, 27u8]);

    scenario.next_tx(CUSTOMER);
    let policy_id = {
        let p = scenario.take_from_sender<Policy>();
        let id = object::id(&p);
        scenario.return_to_sender(p);
        id
    };

    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut policy_reg = scenario.take_shared<PolicyRegistry>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        policy_registry::cancel_policy(&access_reg, &mut policy_reg, &ins_cap, policy_id, 0, &clock);
        scenario.return_to_sender(ins_cap);
        ts::return_shared(policy_reg);
        ts::return_shared(access_reg);
    };

    submit_claim_helper(&mut scenario, &clock, 19);

    clock::destroy_for_testing(clock);
    scenario.end();
}

// 4) Approving without prior assessment fails
#[test]
#[expected_failure(abort_code = 5, location = veridis::claims)]
fun approve_without_assessment_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, NOW_MS);
    bootstrap_and_grant(&mut scenario);
    provision_customer(&mut scenario, &clock, vector[19u8, 27u8]);
    submit_claim_helper(&mut scenario, &clock, 19);

    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut claim = scenario.take_shared<Claim>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        claims::approve_claim(&access_reg, &mut claim, &ins_cap, 5000, &clock);
        scenario.return_to_sender(ins_cap);
        ts::return_shared(claim);
        ts::return_shared(access_reg);
    };

    clock::destroy_for_testing(clock);
    scenario.end();
}

// 5) Settling a non-approved claim fails
#[test]
#[expected_failure(abort_code = 2, location = veridis::payments)]
fun settle_unapproved_claim_fails() {
    let mut scenario = ts::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, NOW_MS);
    bootstrap_and_grant(&mut scenario);
    provision_customer(&mut scenario, &clock, vector[19u8, 27u8]);
    submit_claim_helper(&mut scenario, &clock, 19);

    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        payments::create_vault<SUI>(&access_reg, &ins_cap, scenario.ctx());
        scenario.return_to_sender(ins_cap);
        ts::return_shared(access_reg);
    };

    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut vault = scenario.take_shared<EscrowVault<SUI>>();
        let mut claim = scenario.take_shared<Claim>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        let funding = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        payments::fund_vault<SUI>(&access_reg, &mut vault, &ins_cap, funding);
        payments::settle_claim<SUI>(&access_reg, &mut vault, &mut claim, &ins_cap, &clock, scenario.ctx());
        scenario.return_to_sender(ins_cap);
        ts::return_shared(claim);
        ts::return_shared(vault);
        ts::return_shared(access_reg);
    };

    clock::destroy_for_testing(clock);
    scenario.end();
}