import { ConfirmationHost } from "../../src/lib/confirm-action";
import { toast } from "sonner";
import { Toaster } from "../../src/components/ui/sonner";
import React from "react";
import { createRoot } from "react-dom/client";
import { createRootRoute, createRouter, RouterProvider } from "@tanstack/react-router";
import { ExternalSupplyOrders } from "../../src/components/procurement/ExternalSupplyOrders";
import "../../src/styles.css";
const root = createRootRoute({
  component: () => (
    <main className="mx-auto max-w-7xl p-4"><ConfirmationHost/><Toaster/>
      <h1 className="text-2xl">External orders — local test</h1>
      <p>Disconnected fixture. No production data or supplier communication.</p>
      <ExternalSupplyOrders
        pharmacyId="fixture"
        canRecord
        onReceive={(d) =>
          toast.info(`Prepared receipt for ${d.items[0]?.quantity} outstanding packs.`)
        }
        onReceipt={() => toast.info("Sample receipt")}
      />
    </main>
  ),
});
const router = createRouter({ routeTree: root });
createRoot(document.getElementById("root")!).render(<RouterProvider router={router} />);
