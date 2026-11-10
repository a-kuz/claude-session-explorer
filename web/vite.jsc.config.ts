import { defineConfig } from "vite";

export default defineConfig({
  publicDir: false,
  build: {
    outDir: "../Sources/Resources",
    emptyOutDir: false,
    target: "es2020",
    minify: true,
    lib: {
      entry: "src/variants-jsc.ts",
      formats: ["iife"],
      name: "SETranscriptBundle",
      fileName: () => "transcript.js",
    },
  },
});
