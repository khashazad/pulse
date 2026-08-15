import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig(({ command }) => ({
  plugins: [react()],
  publicDir: command === "serve" ? "dev-public" : false,
  server: {
    proxy: {
      "/auth": "http://localhost:8787",
      "/measures": "http://localhost:8787",
      "/weight": "http://localhost:8787",
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    restoreMocks: true,
  },
}));
