import { useState } from "react";
import { MonitorSmartphone } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { confirmAction } from "@/lib/confirm-action";
import { supabase } from "@/integrations/supabase/client";

/** End sessions on other devices, or everywhere. Useful after a lost phone or shared computer. */
export function SessionsCard() {
  const [busy, setBusy] = useState(false);

  const others = async () => {
    if (!(await confirmAction("Sign out of every other device? This device stays signed in."))) {
      return;
    }
    setBusy(true);
    const { error } = await supabase.auth.signOut({ scope: "others" });
    setBusy(false);
    if (error) toast.error(error.message);
    else toast.success("Other devices were signed out.");
  };

  const everywhere = async () => {
    if (!(await confirmAction("Sign out of all devices, including this one?"))) return;
    setBusy(true);
    const { error } = await supabase.auth.signOut({ scope: "global" });
    setBusy(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    window.location.assign("/login");
  };

  return (
    <Card className="space-y-3 p-5">
      <div className="flex items-start gap-3">
        <MonitorSmartphone className="mt-0.5 h-5 w-5 text-muted-foreground" aria-hidden="true" />
        <div>
          <h2 className="font-semibold">Signed-in devices</h2>
          <p className="text-sm text-muted-foreground">
            Lost a phone or used a shared computer? End those sessions. You are also signed out
            automatically after a period of inactivity (15 minutes for platform admins, 1 hour for
            everyone else).
          </p>
        </div>
      </div>
      <div className="flex flex-wrap gap-2">
        <Button variant="outline" disabled={busy} onClick={() => void others()}>
          Sign out other devices
        </Button>
        <Button variant="outline" disabled={busy} onClick={() => void everywhere()}>
          Sign out everywhere
        </Button>
      </div>
    </Card>
  );
}
