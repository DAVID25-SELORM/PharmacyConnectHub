import { createFileRoute } from "@tanstack/react-router";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { PharmacyCrm } from "@/components/crm/PharmacyCrm";
import { useSession } from "@/hooks/use-session";
export const Route = createFileRoute("/pharmacy_/contacts")({
  head: () => ({ meta: [{ title: "Contacts / CRM - Drugxone" }] }),
  component: ContactsRoute,
});
function ContactsRoute() {
  const { business } = useSession();
  return (
    <WorkspaceGate>
      <PharmacyCrm key={business?.id} />
    </WorkspaceGate>
  );
}
