#!/usr/bin/env bash
# =============================================================================
# Veridis — End-to-end happy-path demo (Sui testnet)
# Τρέχει ΟΛΗ τη ροή μιας ζημιάς με μία εντολή και δείχνει το αποτέλεσμα
# από τον indexer. Κάθε εκτέλεση δημιουργεί μια ΦΡΕΣΚΙΑ ζημιά.
#
# Προαπαιτούμενα:
#   - sui CLI σε testnet, active-address = ο κάτοχος των caps παρακάτω
#   - python3
#   - (προαιρετικά) ο indexer να τρέχει στο http://localhost:8787
#
# Χρήση:
#   chmod +x veridis-happy-path.sh
#   ./veridis-happy-path.sh
# =============================================================================
set -euo pipefail

# ---- Deployment (testnet) — από το deployment.testnet.json --------------------
PKG=0x03881a736ae6b9d9126308a04f1c0a4cc631dbbc938b11b1e3a1a5217a8aec1b
ACCESS=0x7fc2b87f7c6d52fec66b4c760d8148fcae44fd472177359d390f2ec6bf3864fb
IDENTITY=0x6d352265d70e933b5638b3f0369b752f5080b29290e75435fb8a4dee2ed8371c
POLICY_REG=0x90b1c52eb2cc307ad2f345409d8f6ef9365221ef75a6a92a8d25a419881031b0
CLAIMS_REG=0x29862b1b9c55f6ec399666263e429299ba18eca85d3ece80f00756badf95438a
ME=0xd333724aa66f513981f2f46669e43c0be5dfce6fc30548cc171a3d291a40e4bc

# Role capabilities (μόνιμα owned objects — δίνονται μία φορά, εδώ τα ξαναχρησιμοποιούμε)
INSURER=0xda9dd604180941bad5fbeb0e3c7e1bddc4322940a56525788929f1176913fb3c
AGENT=0x912f7d596e426d0fca788faff39e691405ccb1f71490eb23ea41a9df0efc9cc0
KYC=0x075d8a8827a7ee145b0ae6e566b97aaba29c9d8288414183619f11d7eed3d3a8
ASSESSOR=0xcc8b2c1bbc419eb66aac58aff52331e1fd30a88847cad3b866beac2645cba833

CLOCK=0x6
GAS=50000000
GAS_BIG=100000000
INDEXER=${INDEXER:-http://localhost:8787}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- helpers ----------------------------------------------------------------
status() { python3 -c "import json;d=json.load(open('$1'));s=d.get('effects',{}).get('status',{});print(s.get('status',s))"; }
digest() { python3 -c "import json;print(json.load(open('$1')).get('digest',''))"; }
created() { # $1=json file  $2=struct name (π.χ. Claim, Policy, EscrowVault)
  python3 -c "
import json
d=json.load(open('$1'))
for c in d.get('objectChanges',[]):
    if c.get('type')=='created':
        t=c.get('objectType','').split('<')[0].split('::')[-1]
        if t=='$2':
            print(c['objectId']); break
"
}
step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

echo "=============================================="
echo " Veridis — happy-path demo (Sui testnet)"
echo " package: $PKG"
echo "=============================================="

# 1) KYC attestation (KYCProviderCap) -> soulbound στον ασφαλισμένο
step "1/8  Έκδοση KYC attestation"
sui client call --package $PKG --module identity --function issue_attestation \
  --args $ACCESS $IDENTITY $KYC $ME 1 0xa1a1a1 1 0 $CLOCK \
  --gas-budget $GAS --json > "$TMP/att.json"
KYC_ATT=$(created "$TMP/att.json" ComplianceAttestation)
echo "   status: $(status "$TMP/att.json")  |  ComplianceAttestation = $KYC_ATT"

# 2) Consent (το δίνει ο ασφαλισμένος, purpose 1 = CLAIMS_PROCESSING)
step "2/8  Συγκατάθεση (consent) από τον ασφαλισμένο"
sui client call --package $PKG --module identity --function grant_consent \
  --args $IDENTITY $ME 1 0xb2b2b2 1 0x0102 365 0 $CLOCK \
  --gas-budget $GAS --json > "$TMP/consent.json"
CONSENT=$(created "$TMP/consent.json" ConsentReceipt)
echo "   status: $(status "$TMP/consent.json")  |  ConsentReceipt = $CONSENT"

# 3) Policy (InsurerCap), coverage 0x010203 = perils [1,2,3]
step "3/8  Έκδοση συμβολαίου (Policy)"
sui client call --package $PKG --module policy_registry --function issue_policy \
  --args $ACCESS $POLICY_REG $INSURER $ME 1 0x010203 0xc3c3c3 1 0 9999999999999 $CLOCK \
  --gas-budget $GAS --json > "$TMP/policy.json"
POLICY=$(created "$TMP/policy.json" Policy)
echo "   status: $(status "$TMP/policy.json")  |  Policy = $POLICY"

# 4) Submit claim (FNOL) — consent-gated, χωρίς cap (αυτό θα ήταν gasless στην παραγωγή)
step "4/8  Υποβολή ζημιάς (FNOL) — peril 1"
sui client call --package $PKG --module claims --function submit_claim \
  --args $CLAIMS_REG $POLICY_REG $IDENTITY $POLICY $KYC_ATT $CONSENT 1 0xd4d4d4 $CLOCK \
  --gas-budget $GAS --json > "$TMP/claim.json"
CLAIM=$(created "$TMP/claim.json" Claim)
echo "   status: $(status "$TMP/claim.json")  |  Claim = $CLAIM"

# 5) Agent: SUBMITTED -> UNDER_REVIEW
step "5/8  Έναρξη εξέτασης (Agent)"
sui client call --package $PKG --module claims --function begin_review \
  --args $ACCESS $CLAIM $AGENT $CLOCK \
  --gas-budget $GAS --json > "$TMP/review.json"
echo "   status: $(status "$TMP/review.json")"

# 6) Assessor: UNDER_REVIEW -> ASSESSED
step "6/8  Πραγματογνωμοσύνη (Assessor)"
sui client call --package $PKG --module claims --function submit_assessment \
  --args $ACCESS $CLAIM $ASSESSOR 0xe5e5e5 $CLOCK \
  --gas-budget $GAS --json > "$TMP/assess.json"
echo "   status: $(status "$TMP/assess.json")"

# 7) Insurer: ASSESSED -> APPROVED (1000 MIST)
step "7/8  Έγκριση (Insurer) — ποσό 1000 MIST"
sui client call --package $PKG --module claims --function approve_claim \
  --args $ACCESS $CLAIM $INSURER 1000 $CLOCK \
  --gas-budget $GAS --json > "$TMP/approve.json"
echo "   status: $(status "$TMP/approve.json")"

# 8) Vault: create + fund + settle (APPROVED -> PAID, ατομικά)
step "8/8  Vault: δημιουργία → χρηματοδότηση → settle"
sui client call --package $PKG --module payments --function create_vault \
  --type-args 0x2::sui::SUI --args $ACCESS $INSURER \
  --gas-budget $GAS --json > "$TMP/vault.json"
VAULT=$(created "$TMP/vault.json" EscrowVault)
echo "   create  : $(status "$TMP/vault.json")  |  EscrowVault = $VAULT"

sui client ptb \
  --split-coins gas "[1000000]" \
  --assign c \
  --move-call $PKG::payments::fund_vault "<0x2::sui::SUI>" @$ACCESS @$VAULT @$INSURER c.0 \
  --gas-budget $GAS_BIG --json > "$TMP/fund.json"
echo "   fund    : $(status "$TMP/fund.json")"

sui client call --package $PKG --module payments --function settle_claim \
  --type-args 0x2::sui::SUI --args $ACCESS $VAULT $CLAIM $INSURER $CLOCK \
  --gas-budget $GAS_BIG --json > "$TMP/settle.json"
SETTLE_TX=$(digest "$TMP/settle.json")
echo "   settle  : $(status "$TMP/settle.json")  |  tx = $SETTLE_TX"

# ---- Αποτέλεσμα από τον indexer ---------------------------------------------
step "Επαλήθευση από τον indexer (περίμενε το επόμενο poll)…"
sleep 6
if curl -sf "$INDEXER/health" >/dev/null 2>&1; then
  echo "   /claims/$CLAIM :"
  curl -s "$INDEXER/claims/$CLAIM" | python3 -m json.tool || true
  echo "   /stats :"
  curl -s "$INDEXER/stats" | python3 -m json.tool || true
else
  echo "   (ο indexer δεν απαντά στο $INDEXER — παρ' όλα αυτά η ζημιά είναι PAID on-chain)"
fi

echo ""
echo "=============================================="
echo " ✅ Ολοκληρώθηκε. Claim: $CLAIM"
echo " 🔗 Settle tx: https://suiscan.xyz/testnet/tx/$SETTLE_TX"
echo "=============================================="