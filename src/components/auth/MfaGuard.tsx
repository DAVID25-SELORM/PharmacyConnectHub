import type { ReactNode } from "react";
import { useRouterState } from "@tanstack/react-router";
import { MfaChallengeScreen } from "@/components/auth/MfaChallengeScreen";
import { useMfaState } from "@/hooks/use-mfa";

/** Pages that show nothing private, and the sign-in pages that run their own code step. */
const OPEN_PATHS = new Set([
  "/",
  "/login",
  "/signup",
  "/forgot-password",
  "/reset-password",
  "/help",
  "/privacy",
  "/terms",
]);

export function isOpenPath(pathname: string): boolean {
  const clean = pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
  return OPEN_PATHS.has(clean);
}

/**
 * Sits in the app root. If someone has an authenticator app but only entered their
 * password this session, every private page asks for the code first.
 */
export function MfaGuard({ children }: { children: ReactNode }) {
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const open = isOpenPath(pathname);
  const { state, loading, refresh } = useMfaState({ enabled: !open });

  if (open) return <>{children}</>;
  if (loading) return null;
  if (state.needsChallenge) {
    return (
      <MfaChallengeScreen
        factorId={state.factorId}
        onVerified={() => void refresh()}
        onRetryLoad={() => void refresh()}
      />
    );
  }
  return <>{children}</>;
}
