import React from "react";
import { createRoot } from "react-dom/client";
import { createRootRoute, createRouter, RouterProvider } from "@tanstack/react-router";
import { DocumentBrandingSettings } from "../../src/components/documents/DocumentBrandingSettings";
import "../../src/styles.css";
const root = createRootRoute({
  component: () => (
    <main className="mx-auto max-w-5xl p-4">
      <h1 className="text-2xl">Business Settings - Test Pharmacy</h1>
      <p>Disconnected fixture. No production data.</p>
      <DocumentBrandingSettings businessId="fixture" businessName="Test Pharmacy" />
    </main>
  ),
});
const router = createRouter({ routeTree: root });
createRoot(document.getElementById("root")!).render(<RouterProvider router={router} />);
