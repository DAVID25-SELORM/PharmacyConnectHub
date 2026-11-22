import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { DashboardHeader } from "@/components/DashboardShell";
import { AdminTwoStepPolicyCard } from "@/components/security/AdminTwoStepPolicyCard";
import { ChangePasswordCard } from "@/components/security/ChangePasswordCard";
import { SessionsCard } from "@/components/security/SessionsCard";
import { YourDataCard } from "@/components/security/YourDataCard";
import { TwoStepVerificationCard } from "@/components/security/TwoStepVerificationCard";
import { useSession } from "@/hooks/use-session";

export const Route = createFileRoute("/security")({
  head: () => ({ meta: [{ title: "Account security - Drugxone" }] }),
  component: SecurityPage,
});

/**
 * Personal account security. Needs only a signed-in person, not an approved workspace,
 * so platform staff without a business can still set up two-step verification.
 */
function SecurityPage() {
  const navigate = useNavigate();
  const { loading, user, roles } = useSession();

  useEffect(() => {
    if (!loading && !user) navigate({ to: "/login", replace: true });
  }, [loading, user, navigate]);

  if (loading || !user) return null;

  return (
    <>
      <DashboardHeader subtitle="Account security" isAdmin={roles.includes("admin")} />
      <main className="container mx-auto max-w-3xl space-y-6 px-4 py-8">
        <header>
          <h1 className="text-2xl font-semibold">Account security</h1>
          <p className="text-muted-foreground">Signed in as {user.email}</p>
        </header>
        <TwoStepVerificationCard />
        {roles.includes("admin") && <AdminTwoStepPolicyCard />}
        <ChangePasswordCard />
        <SessionsCard />
        <YourDataCard />
      </main>
    </>
  );
}
