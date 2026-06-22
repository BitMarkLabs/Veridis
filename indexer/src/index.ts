import { config, isPackageConfigured } from "./config.js";
import { store } from "./store.js";
import { createApi } from "./api.js";
import { startIndexer } from "./indexer.js";

function main() {
  store.load();

  const app = createApi();
  app.listen(config.port, () => {
    console.log(`[api] Veridis read API on http://localhost:${config.port}`);
    console.log(`[api] try: /health  /stats  /claims  /events`);
    if (!isPackageConfigured()) {
      console.warn(
        "[api] NOTE: VERIDIS_PACKAGE_ID is 0x0. Publish the Move package, " +
          "put the package id in .env, and restart to begin indexing.",
      );
    }
  });

  startIndexer();

  const shutdown = () => {
    console.log("\n[app] shutting down, flushing datastore...");
    store.persist();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main();
