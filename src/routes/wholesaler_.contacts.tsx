import { createFileRoute } from "@tanstack/react-router";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { PharmacyCrm } from "@/components/crm/PharmacyCrm";

export const Route = createFileRoute("/wholesaler_/contacts")({
  head: () => ({ meta: [{ title: "Contacts / CRM - Drugxone" }] }),
  component: WholesalerContactsRoute,
});

function WholesalerContactsRoute() {
  return (
    <WorkspaceGate>
      <PharmacyCrm />
    </WorkspaceGate>
  );
}
