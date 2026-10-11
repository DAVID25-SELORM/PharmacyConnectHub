import { createFileRoute, Link } from "@tanstack/react-router";
import { AccountingPage } from "@/components/accounting/AccountingPage";
import { WorkspaceGate } from "@/components/WorkspaceGate";

export const Route = createFileRoute("/pharmacy_/accounting")({
  head: () => ({ meta: [{ title: "Accounts payable - Drugxone" }] }),
  component: () => (
    <WorkspaceGate>
      <div className="bg-muted px-6 py-3 text-sm">
        <Link
          className="font-medium text-primary underline"
          to="/pharmacy/procurement"
          search={{ payment: "credit" }}
        >
          External supplier payables
        </Link>
        <span className="ml-2">
          Track off-platform balances and payments separately from marketplace credit.
        </span>
      </div>
      <AccountingPage side="pharmacy" />
    </WorkspaceGate>
  ),
});
