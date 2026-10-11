import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwind from "@tailwindcss/vite";
import { resolve } from "node:path";
export default defineConfig({
  plugins: [react(), tailwind()],
  resolve: {
    alias: [
      {
        find: "@/integrations/supabase/client",
        replacement: resolve("tests/browser/orders-supabase.ts"),
      },
      { find: "@/hooks/use-session", replacement: resolve("tests/browser/orders-session.ts") },
      { find: "@", replacement: resolve("src") },
    ],
  },
});
