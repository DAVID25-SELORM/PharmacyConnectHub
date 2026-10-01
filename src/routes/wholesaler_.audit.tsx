import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { AuditCentrePage } from "@/components/audit/AuditCentrePage";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { auditFiltersToSearch, parseAuditSearch, type AuditFilters } from "@/lib/audit-centre";

export const Route = createFileRoute("/wholesaler_/audit")({
  head: () => ({ meta: [{ title: "Audit log - Drugxone" }] }),
  validateSearch: (search: Record<string, unknown>) => parseAuditSearch(search),
  component: () => (
    <WorkspaceGate>
      <WholesalerAuditPage />
    </WorkspaceGate>
  ),
});

function WholesalerAuditPage() {
  const navigate = useNavigate({ from: "/wholesaler_/audit" });
  const filters = Route.useSearch();
  const onFiltersChange = (next: AuditFilters) =>
    void navigate({ to: "/wholesaler/audit", search: auditFiltersToSearch(next) as never, replace: true });

  return <AuditCentrePage filters={filters} onFiltersChange={onFiltersChange} />;
}
