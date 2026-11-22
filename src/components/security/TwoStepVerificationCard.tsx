import { useState } from "react";
import { ShieldCheck, ShieldOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { MfaCodeForm } from "@/components/auth/MfaCodeForm";
import { useMfaState } from "@/hooks/use-mfa";
import { confirmAction } from "@/lib/confirm-action";
import {
  cancelTotpEnrolment,
  mfaErrorMessage,
  parseTotpCode,
  removeMfaFactor,
  startTotpEnrolment,
  type TotpEnrolment,
} from "@/lib/mfa";
import { supabase } from "@/integrations/supabase/client";

/** Turn two-step verification on or off with an authenticator app. */
export function TwoStepVerificationCard() {
  const { state, loading, refresh } = useMfaState({ withFactors: true });
  const [enrolment, setEnrolment] = useState<TotpEnrolment | null>(null);
  const [busy, setBusy] = useState(false);

  const begin = async () => {
    setBusy(true);
    const result = await startTotpEnrolment();
    setBusy(false);
    if (!result.ok) {
      toast.error(result.message);
      return;
    }
    setEnrolment(result.enrolment);
  };

  const cancel = async () => {
    if (enrolment) await cancelTotpEnrolment(enrolment.factorId);
    setEnrolment(null);
  };

  const confirmEnrolment = async (rawCode: string): Promise<string | null> => {
    if (!enrolment) return null;
    const code = parseTotpCode(rawCode);
    if (!code) return "Enter the 6-digit code from your authenticator app.";
    const { error } = await supabase.auth.mfa.challengeAndVerify({
      factorId: enrolment.factorId,
      code,
    });
    if (error) return mfaErrorMessage(error);
    setEnrolment(null);
    await refresh();
    toast.success("Two-step verification is on.");
    return null;
  };

  const remove = async (factorId: string) => {
    const ok = await confirmAction(
      "Turn off two-step verification? Your account will be protected by your password alone.",
    );
    if (!ok) return;
    setBusy(true);
    const message = await removeMfaFactor(factorId);
    setBusy(false);
    if (message) {
      toast.error(message);
      return;
    }
    await refresh();
    toast.success("Two-step verification is off.");
  };

  return (
    <Card className="space-y-4 p-5">
      <div className="flex items-start gap-3">
        {state.enrolled ? (
          <ShieldCheck className="mt-0.5 h-5 w-5 text-emerald-600" aria-hidden="true" />
        ) : (
          <ShieldOff className="mt-0.5 h-5 w-5 text-muted-foreground" aria-hidden="true" />
        )}
        <div>
          <h2 className="font-semibold">Two-step verification</h2>
          <p className="text-sm text-muted-foreground">
            After your password, Drugxone asks for a 6-digit code from an authenticator app on your
            phone (Google Authenticator, Microsoft Authenticator, Authy). A stolen password alone
            then cannot open your account.
          </p>
        </div>
      </div>

      {loading ? (
        <p className="text-sm text-muted-foreground">Checking...</p>
      ) : enrolment ? (
        <div className="space-y-3">
          <ol className="list-decimal space-y-1 pl-5 text-sm">
            <li>Open your authenticator app and add a new account.</li>
            <li>Scan this code, or type the key below into the app.</li>
            <li>Enter the 6-digit code the app shows.</li>
          </ol>
          <div className="flex flex-col items-start gap-3 sm:flex-row sm:items-center">
            <img
              src={enrolment.qrCode}
              alt="QR code to add Drugxone to your authenticator app"
              className="h-40 w-40 rounded-md border bg-white p-2"
            />
            <div className="min-w-0 text-sm">
              <p className="text-muted-foreground">Can't scan? Enter this key:</p>
              <code className="mt-1 block break-all rounded bg-muted px-2 py-1 text-xs">
                {enrolment.secret}
              </code>
            </div>
          </div>
          <div className="max-w-xs">
            <MfaCodeForm submitLabel="Turn on" onSubmit={confirmEnrolment} />
          </div>
          <Button variant="ghost" size="sm" onClick={() => void cancel()}>
            Cancel
          </Button>
        </div>
      ) : state.enrolled ? (
        <div className="space-y-2">
          <p className="text-sm font-medium text-emerald-700">On</p>
          {state.factors.map((factor) => (
            <div
              key={factor.id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-md border px-3 py-2 text-sm"
            >
              <span>
                {factor.friendlyName}
                <span className="ml-2 text-xs text-muted-foreground">
                  added {new Date(factor.createdAt).toLocaleDateString()}
                </span>
              </span>
              <Button
                variant="outline"
                size="sm"
                disabled={busy}
                onClick={() => void remove(factor.id)}
              >
                Turn off
              </Button>
            </div>
          ))}
        </div>
      ) : (
        <Button variant="hero" onClick={() => void begin()} disabled={busy}>
          {busy ? "Starting..." : "Turn on two-step verification"}
        </Button>
      )}
    </Card>
  );
}
