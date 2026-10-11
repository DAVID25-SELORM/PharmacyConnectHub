import { createFileRoute } from "@tanstack/react-router";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { EnterpriseRfqWorkspace } from "@/components/rfq/EnterpriseRfqWorkspace";
export const Route = createFileRoute("/wholesaler_/rfqs")({
  head: () => ({ meta: [{ title: "RFQ procurement - DrugXOne" }] }),
  component: () => (
    <WorkspaceGate>
      <EnterpriseRfqWorkspace />
    </WorkspaceGate>
  ),
});
