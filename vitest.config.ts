import { defineConfig } from "vitest/config";

// The pinned @1inch SDK bundles ESM with extensionless relative imports; Node's strict ESM
// resolver rejects those under vitest. Inlining the packages routes them through Vite's
// resolver, which accepts extensionless specifiers, same as tsx does for the scripts.
export default defineConfig({
  test: {
    include: ["scripts/**/*.test.ts"],
    server: { deps: { inline: [/@1inch\//] } },
  },
});
