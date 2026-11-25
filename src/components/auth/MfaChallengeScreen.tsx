import { ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { RememberedMfaCodeForm } from "@/components/auth/RememberedMfaCodeForm";
import { supabase } from "@/integrations/supabase/client";

/** Full-page step shown when a password was accepted but the authenticator code is still owed. */
export function MfaChallengeScreen({
  factorId,
  onVerified,
  onRetryLoad,
}: {
  factorId: string | null;
  onVerified: () => void;
  onRetryLoad?: () => void;
}) {
  const signOut = async () => {
    await supabase.auth.signOut({ scope: "local" });
    window.location.assign("/login");
  };

  return (
    <div className="min-h-screen bg-gradient-soft flex items-center justify-center p-4">
      <Card className="w-full max-w-md space-y-4 p-8 shadow-elegant">
        <div className="flex items-center gap-2">
          <ShieldCheck className="h-6 w-6 text-primary" aria-hidden="true" />
          <h1 className="font-display text-2xl font-bold">Two-step verification</h1>
        </div>
        <p className="text-sm text-muted-foreground">
          Open your authenticator app and enter the 6-digit code for Drugxone.
        </p>
        {factorId ? (
          <RememberedMfaCodeForm factorId={factorId} onVerified={onVerified} />
        ) : (
          <div role="alert" className="space-y-2 text-sm">
            <p>We could not load your verification settings.</p>
            {onRetryLoad && (
              <Button variant="outline" size="sm" onClick={onRetryLoad}>
                Try again
              </Button>
            )}
          </div>
        )}
        <Button variant="ghost" size="sm" className="w-full" onClick={() => void signOut()}>
          Sign out
        </Button>
      </Card>
    </div>
  );
}
