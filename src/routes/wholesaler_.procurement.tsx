import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { DashboardHeader } from "@/components/DashboardShell";
import { useSession } from "@/hooks/use-session";
import { externalRpc } from "@/lib/external-procurement";
import { ExternalSupplyOrders } from "@/components/procurement/ExternalSupplyOrders";
export const Route = createFileRoute("/wholesaler_/procurement")({ component: Page });
function Page() {
  return (
    <WorkspaceGate>
      <Documents />
    </WorkspaceGate>
  );
}
function Documents() {
  const { business } = useSession();
  const [allowed, setAllowed] = useState(false),
    [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    setAllowed(false);
    if (business)
      externalRpc<boolean>("can_prepare_procurement", { p_business_id: business.id })
        .then((v) => {
          if (live) setAllowed(v);
        })
        .catch((e) => {
          if (live) setError(e.message);
        });
    return () => {
      live = false;
    };
  }, [business?.id]);
  return (
    <>
      <DashboardHeader subtitle="External procurement documents" showNav />
      <main className="mx-auto max-w-7xl space-y-4 p-4">
        <h1 className="text-2xl font-semibold">External procurement</h1>
        <p>
          Private catalogue, requests and purchase orders. Receiving and inventory posting are not
          part of this workspace.
        </p>
        {error && <p role="alert">{error}</p>}
        {business && allowed ? (
          <ExternalSupplyOrders
            key={business.id}
            pharmacyId={business.id}
            canRecord
            receivingEnabled={false}
            onReceive={() => {}}
            onReceipt={() => {}}
          />
        ) : (
          <p>Purchase processing permission is required.</p>
        )}
      </main>
    </>
  );
}
