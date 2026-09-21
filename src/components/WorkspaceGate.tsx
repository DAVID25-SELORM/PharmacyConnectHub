import { useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, type ReactNode } from "react";
import { Pill } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { resolveWorkspaceAccess } from "@/lib/workspace-access";

/**
 * Wraps operational business routes. Children are mounted (and therefore fetch data)
 * only once the active business is approved.
 */
export function WorkspaceGate({
  children,
  allowWorkspaceChooser = false,
}: {
  children: ReactNode;
  allowWorkspaceChooser?: boolean;
}) {
  const navigate = useNavigate();
  const { loading, user, roles, business, businesses, loadError, refresh } = useSession();
  const wasAllowed = useRef(false);

  const decision = resolveWorkspaceAccess({
    loading,
    hasUser: Boolean(user),
    loadError: Boolean(loadError),
    roles,
    business,
    businessCount: businesses.length,
    allowWorkspaceChooser,
  });

  useEffect(() => {
    if (decision.kind === "allow") {
      wasAllowed.current = true;
    } else if (decision.kind === "redirect") {
      wasAllowed.current = false;
      navigate({ to: decision.to, replace: true });
    }
  }, [decision, navigate]);

  // Background session refreshes briefly report `loading`; keep an already-approved
  // workspace mounted so carts and forms are not lost.
  if (decision.kind === "allow" || (decision.kind === "loading" && wasAllowed.current)) {
    return <>{children}</>;
  }

  if (decision.kind === "error") {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 p-8 text-center">
        <p className="max-w-sm text-muted-foreground">
          We couldn't verify your account status. Please try again.
        </p>
        <div className="flex gap-2">
          <Button onClick={() => void refresh()}>Try again</Button>
          <Button
            variant="outline"
            onClick={async () => {
              await supabase.auth.signOut();
              navigate({ to: "/login" });
            }}
          >
            Sign out
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center text-muted-foreground">
      <Pill className="h-5 w-5 animate-pulse" />
      <span className="ml-2">Checking your DrugXOne account...</span>
    </div>
  );
}
