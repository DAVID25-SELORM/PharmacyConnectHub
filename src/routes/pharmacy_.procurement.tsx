import { createFileRoute } from "@tanstack/react-router";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { useSession } from "@/hooks/use-session";
import { ExternalProcurement } from "@/components/procurement/ExternalProcurement";

export const Route = createFileRoute("/pharmacy_/procurement")({
  validateSearch: (
    s: Record<string, unknown>,
  ): { q?: string; review?: string; payment?: string; view?: string } => ({
    q: typeof s.q === "string" ? s.q : "",
    review: typeof s.review === "string" ? s.review : "",
    payment: typeof s.payment === "string" ? s.payment : "",
    view: s.view === "requests" ? "requests" : s.view === "history" ? "history" : "purchases",
  }),
  head: () => ({ meta: [{ title: "External Procurement - DrugXOne" }] }),
  component: Page,
});
function Page() {
  const { business } = useSession();
  const search = Route.useSearch();
  return (
    <WorkspaceGate>
      <ExternalProcurement key={`${business?.id}-${JSON.stringify(search)}`} initial={search} />
    </WorkspaceGate>
  );
}
