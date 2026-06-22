import "dotenv/config";

/** Veridis on-chain modules that emit events we want to index. */
export const MODULES = [
  "access_control",
  "identity",
  "policy_registry",
  "claims",
  "payments",
] as const;

export type ModuleName = (typeof MODULES)[number];

export const config = {
  rpcUrl: process.env.SUI_RPC_URL ?? "https://fullnode.testnet.sui.io:443",
  packageId: process.env.VERIDIS_PACKAGE_ID ?? "0x0",
  pollIntervalMs: Number(process.env.POLL_INTERVAL_MS ?? 4000),
  port: Number(process.env.PORT ?? 8787),
  dataFile: process.env.DATA_FILE ?? "./data/veridis-index.json",
  pageLimit: 50,
};

export function isPackageConfigured(): boolean {
  return (
    !!config.packageId &&
    config.packageId !== "0x0" &&
    config.packageId.startsWith("0x") &&
    config.packageId.length > 3
  );
}
