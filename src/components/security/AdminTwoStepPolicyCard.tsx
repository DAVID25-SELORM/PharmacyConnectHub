import { useCallback, useEffect, useState } from "react";
import { ShieldAlert } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  adminsWithoutMfa,
  loadAdminMfaStatus,
  setAdminMfaRequired,
  type AdminMfaStatus,
} from "@/lib/admin-mfa-policy";
import { confirmAction } from "@/lib/confirm-action";
import { useMfaState } from "@/hooks/use-mfa";

/** Platform admins only: make the database refuse admin powers without the code step. */
export function AdminTwoStepPolicyCard() {
  const [status, setStatus] = useState<AdminMfaStatus | null>(null);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState(false);
  const { state } = useMfaState({ withFactors: true });

  const load = useCallback(async () => {
    const next = await loadAdminMfaStatus();
    setStatus(next);
    setFailed(next === null);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const toggle = async (required: boolean) => {
    const ok = await confirmAction(
      required
        ? "Require two-step verification for every platform admin? Admins without an authenticator app will lose admin access until they set one up."
        : "Stop requiring two-step verification for platform admins?",
    );
    if (!ok) return;
    setBusy(true);
    const message = await setAdminMfaRequired(required);
    setBusy(false);
    if (message) {
      toast.error(message);
      return;
    }
    toast.success(required ? "Admin two-step verification is now required." : "Turned off.");
    await load();
  };

  if (failed) return null;
  if (!status) return null;
  const missing = adminsWithoutMfa(status);

  return (
    <Card className="space-y-3 p-5">
      <div className="flex items-start gap-3">
        <ShieldAlert className="mt-0.5 h-5 w-5 text-muted-foreground" aria-hidden="true" />
        <div>
          <h2 className="font-semibold">Require two-step verification for platform admins</h2>
          <p className="text-sm text-muted-foreground">
            When on, the database itself refuses admin actions (approvals, payments, refunds, staff
            changes) from any session that has not entered an authenticator code, even if someone
            bypasses the screens.
          </p>
        </div>
      </div>
      <ul className="space-y-1 text-sm">
        {status.admins.map((admin) => (
          <li key={admin.user_id} className="flex items-center justify-between gap-2">
            <span className="truncate">{admin.email}</span>
            <span className={admin.enrolled ? "text-emerald-700" : "text-amber-700"}>
              {admin.enrolled ? "Authenticator set up" : "Not set up"}
            </span>
          </li>
        ))}
      </ul>
      {status.required ? (
        <div className="space-y-2">
          <p className="text-sm font-medium text-emerald-700">Required for all admins</p>
          <Button variant="outline" disabled={busy} onClick={() => void toggle(false)}>
            Stop requiring
          </Button>
        </div>
      ) : (
        <div className="space-y-2">
          {missing.length > 0 && (
            <p className="text-sm text-amber-700">
              Every admin must set up an authenticator app before this can be turned on.
            </p>
          )}
          {!state.enrolled && (
            <p className="text-sm text-amber-700">Turn on your own two-step verification first.</p>
          )}
          <Button
            variant="hero"
            disabled={busy || missing.length > 0 || !state.enrolled}
            onClick={() => void toggle(true)}
          >
            Require for all admins
          </Button>
        </div>
      )}
    </Card>
  );
}
