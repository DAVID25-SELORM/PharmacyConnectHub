import { ProcurementPayables } from "@/components/procurement/ProcurementPayables";
import { createFileRoute } from "@tanstack/react-router";
import { AccountingPage } from "@/components/accounting/AccountingPage";
import { WorkspaceGate } from "@/components/WorkspaceGate";

export const Route = createFileRoute("/pharmacy_/accounting")({
  head: () => ({ meta: [{ title: "Accounts payable - Drugxone" }] }),
  component: () => (
    <WorkspaceGate>
      <ProcurementPayables />
      <AccountingPage side="pharmacy" />
    </WorkspaceGate>
  ),
});
