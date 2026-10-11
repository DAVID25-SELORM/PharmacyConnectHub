import { createFileRoute } from "@tanstack/react-router";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { DashboardHeader } from "@/components/DashboardShell";
import { DocumentBrandingSettings } from "@/components/documents/DocumentBrandingSettings";
import { useSession } from "@/hooks/use-session";

export const Route = createFileRoute("/settings")({
  component: () => (
    <WorkspaceGate>
      <Settings />
    </WorkspaceGate>
  ),
});

function Settings() {
  const { business } = useSession();
  if (!business) return null;
  const manage = ["owner", "manager"].includes(business.staff_role);
  return (
    <>
      <DashboardHeader subtitle="Business settings" />
      <main className="container mx-auto max-w-5xl space-y-6 px-4 py-8">
        <header>
          <h1 className="text-2xl font-semibold">Business Settings</h1>
          <p className="text-muted-foreground">
            {business.name} · {business.type} workspace
          </p>
        </header>
        <section className="rounded-lg border p-5">
          <h2 className="font-semibold">Business identity</h2>
          <p>{business.name}</p>
          <p>{[business.address, business.city, business.region].filter(Boolean).join(", ")}</p>
          <p>
            {business.phone} · {business.public_email}
          </p>
          <p>Licence: {business.license_number || "Not provided"}</p>
          <p className="mt-2 text-sm text-muted-foreground">
            Document presentation does not replace your registered business details.
          </p>
        </section>
        {manage ? (
          <DocumentBrandingSettings
            key={business.id}
            businessId={business.id}
            businessName={business.name}
          />
        ) : (
          <p role="status">A business owner or manager can edit document branding.</p>
        )}
      </main>
    </>
  );
}
