// =============================================================================
// Veridis Protocol — End-to-end happy-path test
// Lives in tests/ (compiled only in test mode, never published).
// =============================================================================

#[test_only]
module veridis::veridis_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;

use veridis::access_control::{Self, AdminCap, AccessRegistry, InsurerCap, AgentCap, AssessorCap, KYCProviderCap};
use veridis::identity::{Self, IdentityRegistry, ComplianceAttestation, ConsentReceipt};
use veridis::policy_registry::{Self, PolicyRegistry, Policy};
use veridis::claims::{Self, ClaimRegistry, Claim};
use veridis::payments::{Self, EscrowVault, PaymentReceipt};

const ADMIN: address = @0xA;
const INSURER: address = @0xB;
const AGENT: address = @0xC;
const ASSESSOR: address = @0xD;
const KYC: address = @0xE;
const CUSTOMER: address = @0xF;

const PERIL: u8 = 19;
const APPROVED_AMOUNT: u64 = 5_000;
const VAULT_FUNDING: u64 = 10_000;
const NOW_MS: u64 = 1_000_000;

#[test]
fun happy_path_full_lifecycle() {
    let mut scenario = ts::begin(ADMIN);

    let mut clock = clock::create_for_testing(scenario.ctx());
    clock::set_for_testing(&mut clock, NOW_MS);

    // TX1 (ADMIN): bootstrap registries + AdminCap
    {
        access_control::init_for_testing(scenario.ctx());
        identity::init_for_testing(scenario.ctx());
        policy_registry::init_for_testing(scenario.ctx());
        claims::init_for_testing(scenario.ctx());
    };

    // TX2 (ADMIN): grant the four operational roles
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

    // TX3 (KYC): issue KYC attestation to the customer
    scenario.next_tx(KYC);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut id_reg = scenario.take_shared<IdentityRegistry>();
        let kyc_cap = scenario.take_from_sender<KYCProviderCap>();
        identity::issue_attestation(
            &access_reg, &mut id_reg, &kyc_cap,
            CUSTOMER, identity::kind_kyc_tier1(), b"kyc-commitment", 1, 0,
            &clock, scenario.ctx(),
        );
        scenario.return_to_sender(kyc_cap);
        ts::return_shared(id_reg);
        ts::return_shared(access_reg);
    };

    // TX4 (CUSTOMER): grant consent
    scenario.next_tx(CUSTOMER);
    {
        let mut id_reg = scenario.take_shared<IdentityRegistry>();
        identity::grant_consent(
            &mut id_reg, INSURER, identity::purpose_claims_processing(),
            b"consent-commitment", 1, b"categories", 365, 0,
            &clock, scenario.ctx(),
        );
        ts::return_shared(id_reg);
    };

    // TX5 (INSURER): issue policy to the customer
    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut policy_reg = scenario.take_shared<PolicyRegistry>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        let coverage = vector[19u8, 27u8];
        policy_registry::issue_policy(
            &access_reg, &mut policy_reg, &ins_cap,
            CUSTOMER, 1, coverage, b"policy-commitment", 1,
            0, 10_000_000,
            &clock, scenario.ctx(),
        );
        scenario.return_to_sender(ins_cap);
        ts::return_shared(policy_reg);
        ts::return_shared(access_reg);
    };

    // TX6 (CUSTOMER): submit claim (FNOL)
    scenario.next_tx(CUSTOMER);
    {
        let mut claim_reg = scenario.take_shared<ClaimRegistry>();
        let policy_reg = scenario.take_shared<PolicyRegistry>();
        let id_reg = scenario.take_shared<IdentityRegistry>();
        let policy = scenario.take_from_sender<Policy>();
        let kyc = scenario.take_from_sender<ComplianceAttestation>();
        let consent = scenario.take_from_sender<ConsentReceipt>();
        claims::submit_claim(
            &mut claim_reg, &policy_reg, &id_reg,
            &policy, &kyc, &consent, PERIL, b"fnol-commitment",
            &clock, scenario.ctx(),
        );
        scenario.return_to_sender(policy);
        scenario.return_to_sender(kyc);
        scenario.return_to_sender(consent);
        ts::return_shared(id_reg);
        ts::return_shared(policy_reg);
        ts::return_shared(claim_reg);
    };

    // TX7 (AGENT): begin review
    scenario.next_tx(AGENT);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut claim = scenario.take_shared<Claim>();
        let agent_cap = scenario.take_from_sender<AgentCap>();
        claims::begin_review(&access_reg, &mut claim, &agent_cap, &clock);
        scenario.return_to_sender(agent_cap);
        ts::return_shared(claim);
        ts::return_shared(access_reg);
    };

    // TX8 (ASSESSOR): submit assessment
    scenario.next_tx(ASSESSOR);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut claim = scenario.take_shared<Claim>();
        let assessor_cap = scenario.take_from_sender<AssessorCap>();
        claims::submit_assessment(&access_reg, &mut claim, &assessor_cap, b"assessment-commitment", &clock);
        scenario.return_to_sender(assessor_cap);
        ts::return_shared(claim);
        ts::return_shared(access_reg);
    };

    // TX9 (INSURER): approve
    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut claim = scenario.take_shared<Claim>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        claims::approve_claim(&access_reg, &mut claim, &ins_cap, APPROVED_AMOUNT, &clock);
        assert!(claims::claim_state(&claim) == claims::state_approved(), 1);
        scenario.return_to_sender(ins_cap);
        ts::return_shared(claim);
        ts::return_shared(access_reg);
    };

    // TX10 (INSURER): create the escrow vault
    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();
        payments::create_vault<SUI>(&access_reg, &ins_cap, scenario.ctx());
        scenario.return_to_sender(ins_cap);
        ts::return_shared(access_reg);
    };

    // TX11 (INSURER): fund vault + settle atomically
    scenario.next_tx(INSURER);
    {
        let access_reg = scenario.take_shared<AccessRegistry>();
        let mut vault = scenario.take_shared<EscrowVault<SUI>>();
        let mut claim = scenario.take_shared<Claim>();
        let ins_cap = scenario.take_from_sender<InsurerCap>();

        let funding = coin::mint_for_testing<SUI>(VAULT_FUNDING, scenario.ctx());
        payments::fund_vault<SUI>(&access_reg, &mut vault, &ins_cap, funding);
        payments::settle_claim<SUI>(&access_reg, &mut vault, &mut claim, &ins_cap, &clock, scenario.ctx());

        assert!(claims::claim_state(&claim) == claims::state_paid(), 2);
        assert!(payments::total_settled<SUI>(&vault) == APPROVED_AMOUNT, 3);
        assert!(payments::vault_balance<SUI>(&vault) == VAULT_FUNDING - APPROVED_AMOUNT, 4);
        assert!(payments::settlements_count<SUI>(&vault) == 1, 5);

        scenario.return_to_sender(ins_cap);
        ts::return_shared(claim);
        ts::return_shared(vault);
        ts::return_shared(access_reg);
    };

    // TX12 (CUSTOMER): verify payout coin + soulbound receipt
    scenario.next_tx(CUSTOMER);
    {
        let payout = scenario.take_from_sender<Coin<SUI>>();
        assert!(coin::value(&payout) == APPROVED_AMOUNT, 6);

        let receipt = scenario.take_from_sender<PaymentReceipt>();
        assert!(payments::receipt_amount(&receipt) == APPROVED_AMOUNT, 7);
        assert!(payments::receipt_payee(&receipt) == CUSTOMER, 8);

        scenario.return_to_sender(payout);
        scenario.return_to_sender(receipt);
    };

    clock::destroy_for_testing(clock);
    scenario.end();
}