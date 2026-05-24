import { defineConfig } from "rolldown";

export default defineConfig({
  input: "src/main.ts",
  output: {
    file: "public/bundle.js",
    format: "esm",
    sourcemap: true,
  },
});
