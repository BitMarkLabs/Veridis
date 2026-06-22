// Mirrors the on-chain enums so the API returns human-readable labels.

/** claims.move: STATE_* codes */
export const CLAIM_STATES: Record<number, string> = {
  0: "SUBMITTED",
  1: "UNDER_REVIEW",
  2: "ASSESSED",
  3: "APPROVED",
  4: "REJECTED",
  5: "PAID",
  6: "DISPUTED",
  7: "CLOSED",
};

/** access_control.move: ROLE_* codes */
export const ROLES: Record<number, string> = {
  1: "INSURER",
  2: "AGENT",
  3: "KYC_PROVIDER",
  4: "ASSESSOR",
};

/** identity.move: KIND_* attestation codes */
export const ATTESTATION_KINDS: Record<number, string> = {
  1: "KYC_TIER1",
  2: "KYC_TIER2",
  10: "AML_CLEARED",
  11: "SANCTIONS_CLEARED",
  20: "ASSESSOR_LICENSE",
  30: "REGULATORY",
};

/** policy_registry.move: STATUS_* codes */
export const POLICY_STATUS: Record<number, string> = {
  0: "ACTIVE",
  1: "SUSPENDED",
  2: "CANCELLED",
};

export function stateLabel(code: number | undefined): string {
  return code === undefined ? "UNKNOWN" : CLAIM_STATES[code] ?? `STATE_${code}`;
}
