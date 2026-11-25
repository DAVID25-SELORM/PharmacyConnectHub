import { useEffect, useState } from "react";
import { Link, useRouterState } from "@tanstack/react-router";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useSession } from "@/hooks/use-session";
import { hasAcceptedCurrentVersion, recordConsent, signedUpWithConsent } from "@/lib/privacy";

/**
 * Asks people who have not yet accepted the current Privacy Notice and Terms to do so.
 * It never blocks work: it is a card at the bottom of the screen until they accept.
 * Accounts created with the sign-up checkbox are recorded silently on first visit.
 */
export function ConsentBanner() {
  const { user } = useSession();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const [needed, setNeeded] = useState(false);
  const [busy, setBusy] = useState(false);
  const userId = user?.id ?? null;
  const metadata = user?.user_metadata;

  useEffect(() => {
    if (!userId) {
      setNeeded(false);
      return;
    }
    let cancelled = false;
    void (async () => {
      if (await hasAcceptedCurrentVersion(userId)) return;
      if (signedUpWithConsent(metadata) && (await recordConsent("signup")) === null) return;
      if (!cancelled) setNeeded(true);
    })();
    return () => {
      cancelled = true;
    };
    // The metadata object changes identity on every session refresh; the id is what matters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId]);

  if (!needed || pathname === "/privacy" || pathname === "/terms") return null;

  const accept = async () => {
    setBusy(true);
    const message = await recordConsent("app");
    setBusy(false);
    if (message) {
      toast.error(message);
      return;
    }
    setNeeded(false);
  };

  return (
    <div
      role="region"
      data-consent-banner
      aria-label="Privacy Notice and Terms of Use"
      className="fixed inset-x-3 bottom-3 z-50 mx-auto max-w-xl rounded-xl border bg-background p-4 shadow-lg sm:bottom-4"
    >
      <p className="text-sm">
        Please review our{" "}
        <Link to="/privacy" className="font-medium text-primary underline">
          Privacy Notice
        </Link>{" "}
        and{" "}
        <Link to="/terms" className="font-medium text-primary underline">
          Terms of Use
        </Link>
        . They explain what data we hold and your rights.
      </p>
      <div className="mt-3 flex justify-end">
        <Button variant="hero" size="sm" disabled={busy} onClick={() => void accept()}>
          {busy ? "Saving..." : "I agree"}
        </Button>
      </div>
    </div>
  );
}
