import { SuiClient } from "@mysten/sui/client";
import { config } from "./config.js";

export const sui = new SuiClient({ url: config.rpcUrl });
