import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { useSession } from "@/hooks/use-session";
import { Pill } from "lucide-react";

export const Route = createFileRoute("/dashboard")({
  component: DashboardRedirect,
});

function DashboardRedirect() {
  const { loading, user, roles, business } = useSession();
  const navigate = useNavigate();

  useEffect(() => {
    if (loading) return;
    if (!user) {
      navigate({ to: "/login" });
      return;
    }
    if (roles.includes("admin")) {
      navigate({ to: "/admin" });
      return;
    }
    if (!business) {
      navigate({ to: "/onboarding" });
      return;
    }
    if (business.type === "wholesaler") navigate({ to: "/wholesaler" });
    else navigate({ to: "/pharmacy" });
  }, [loading, user, roles, business, navigate]);

  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="flex items-center gap-3 text-muted-foreground">
        <Pill className="h-5 w-5 animate-pulse" />
        <span>Loading your workspace…</span>
      </div>
    </div>
  );
}
