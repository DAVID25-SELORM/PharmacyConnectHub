import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import tsConfigPaths from "vite-tsconfig-paths";
import { TanStackRouterVite } from "@tanstack/router-plugin/vite";

export default defineConfig({
  // Local testing only: serve the /api handlers elsewhere (tests/local-supabase/dev-api-server.mjs) and forward /api to them.
  // Unset in normal development and ignored by the production build.
  server: process.env.DEV_API_PROXY ? { proxy: { "/api": process.env.DEV_API_PROXY } } : undefined,
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) {
            return;
          }

          if (id.includes("pdfjs-dist")) {
            return "pdf";
          }

          if (id.includes("jspdf")) {
            return "pdf-export";
          }

          if (id.includes("xlsx")) {
            return "xlsx";
          }

          if (id.includes("react") || id.includes("react-dom") || id.includes("scheduler")) {
            return "react";
          }

          if (id.includes("@tanstack")) {
            return "tanstack";
          }

          if (id.includes("@supabase")) {
            return "supabase";
          }

          if (id.includes("@radix-ui") || id.includes("lucide-react")) {
            return "ui";
          }

          if (id.includes("framer-motion")) {
            return "motion";
          }
        },
      },
    },
  },
  plugins: [
    TanStackRouterVite({
      routesDirectory: "src/routes",
      generatedRouteTree: "src/routeTree.gen.ts",
    }),
    react(),
    tailwindcss(),
    tsConfigPaths(),
  ],
});
