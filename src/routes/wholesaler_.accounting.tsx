import { createFileRoute } from "@tanstack/react-router";
import { AccountingPage } from "@/components/accounting/AccountingPage";
import { WorkspaceGate } from "@/components/WorkspaceGate";

export const Route = createFileRoute("/wholesaler_/accounting")({
  head: () => ({ meta: [{ title: "Accounts receivable - Drugxone" }] }),
  component: () => (
    <WorkspaceGate>
      <AccountingPage side="wholesaler" />
    </WorkspaceGate>
  ),
});
