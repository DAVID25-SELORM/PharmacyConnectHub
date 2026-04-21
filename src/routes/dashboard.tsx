import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Building2, Pill, Store } from "lucide-react";
import { useEffect } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { useSession, type Business } from "@/hooks/use-session";

export const Route = createFileRoute("/dashboard")({
  component: DashboardRedirect,
});

function workspaceRoute(business: Business) {
  return business.type === "wholesaler" ? "/wholesaler" : "/pharmacy";
}

function DashboardRedirect() {
  const { loading, user, roles, business, businesses, setActiveBusiness } = useSession();
  const navigate = useNavigate();

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (business) {
      navigate({ to: workspaceRoute(business) });
      return;
    }
    if (businesses.length === 0) {
      if (roles.includes("admin")) {
        navigate({ to: "/admin" });
        return;
      }

      navigate({ to: "/onboarding" });
    }
  }, [loading, user, roles, business, businesses, navigate]);

  const openWorkspace = (workspace: Business) => {
    setActiveBusiness(workspace.id);
    navigate({ to: workspaceRoute(workspace) });
  };

  if (loading || !user) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="flex items-center gap-3 text-muted-foreground">
          <Pill className="h-5 w-5 animate-pulse" />
          <span>Loading your workspace…</span>
        </div>
      </div>
    );
  }

  if (!business && businesses.length > 1) {
    return (
      <div className="min-h-screen bg-background">
        <main className="mx-auto max-w-5xl px-4 py-12 sm:px-6 lg:px-8">
          <div className="mx-auto max-w-3xl text-center">
            <h1 className="font-display text-3xl font-bold">Choose a workspace</h1>
            <p className="mt-3 text-muted-foreground">
              This account can access more than one business. Pick the workspace you want to open
              now.
            </p>
          </div>

          <div className="mt-8 grid gap-4 md:grid-cols-2">
            {businesses.map((workspace) => {
              const Icon = workspace.type === "wholesaler" ? Building2 : Store;

              return (
                <Card key={workspace.id} className="p-6">
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex items-start gap-3">
                      <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-muted">
                        <Icon className="h-5 w-5 text-primary" />
                      </div>
                      <div>
                        <h2 className="font-display text-xl font-bold">{workspace.name}</h2>
                        <p className="mt-1 text-sm text-muted-foreground">
                          {workspace.city ?? "Location pending"}
                          {workspace.region ? `, ${workspace.region}` : ""}
                        </p>
                      </div>
                    </div>
                    <Badge variant="secondary" className="capitalize">
                      {workspace.type}
                    </Badge>
                  </div>

                  <div className="mt-4 flex flex-wrap gap-2">
                    <Badge variant="outline" className="capitalize">
                      {workspace.staff_role}
                    </Badge>
                    <Badge variant="outline" className="capitalize">
                      {workspace.verification_status}
                    </Badge>
                  </div>

                  <div className="mt-6 flex gap-2">
                    <Button variant="hero" onClick={() => openWorkspace(workspace)}>
                      Open workspace
                    </Button>
                    {roles.includes("admin") && (
                      <Button variant="outline" onClick={() => navigate({ to: "/admin" })}>
                        Admin console
                      </Button>
                    )}
                  </div>
                </Card>
              );
            })}
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="flex items-center gap-3 text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" />
        <span>Loading your workspace…</span>
      </div>
    </div>
  );
}
