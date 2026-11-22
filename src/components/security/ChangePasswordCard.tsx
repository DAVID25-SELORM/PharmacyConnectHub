import { useState } from "react";
import { KeyRound } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { PasswordStrength } from "@/components/auth/PasswordStrength";
import { checkPassword } from "@/lib/password-policy";
import { supabase } from "@/integrations/supabase/client";
import { useSession } from "@/hooks/use-session";

export function ChangePasswordCard() {
  const { user } = useSession();
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [nonce, setNonce] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const context = {
    email: user?.email ?? undefined,
    name: (user?.user_metadata?.full_name as string | undefined) ?? undefined,
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    if (password !== confirm) {
      toast.error("The two passwords do not match.");
      return;
    }
    const check = checkPassword(password, context);
    if (!check.ok) {
      toast.error(check.issues[0]);
      return;
    }
    setBusy(true);
    const { error } = await supabase.auth.updateUser({
      password,
      ...(nonce ? { nonce } : {}),
    });
    if (error?.code === "reauthentication_needed") {
      // The project asks for an emailed code before a password change.
      await supabase.auth.reauthenticate();
      setNonce("");
      setBusy(false);
      toast.info("We emailed you a confirmation code. Enter it below to finish.");
      return;
    }
    setBusy(false);
    if (error) {
      toast.error(error.message);
      return;
    }
    setPassword("");
    setConfirm("");
    setNonce(null);
    toast.success("Password changed.");
  };

  return (
    <Card className="space-y-4 p-5">
      <div className="flex items-start gap-3">
        <KeyRound className="mt-0.5 h-5 w-5 text-muted-foreground" aria-hidden="true" />
        <div>
          <h2 className="font-semibold">Change password</h2>
          <p className="text-sm text-muted-foreground">
            Use a long password you do not use anywhere else. Passwords are never shown to staff and
            are stored only as a one-way hash.
          </p>
        </div>
      </div>
      <form onSubmit={submit} className="max-w-md space-y-3">
        <div className="space-y-2">
          <Label htmlFor="new-password">New password</Label>
          <Input
            id="new-password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
            required
          />
          <PasswordStrength password={password} context={context} />
        </div>
        <div className="space-y-2">
          <Label htmlFor="confirm-new-password">Confirm new password</Label>
          <Input
            id="confirm-new-password"
            type="password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            autoComplete="new-password"
            required
          />
        </div>
        {nonce !== null && (
          <div className="space-y-2">
            <Label htmlFor="password-nonce">Confirmation code from your email</Label>
            <Input
              id="password-nonce"
              value={nonce}
              onChange={(e) => setNonce(e.target.value.trim())}
              autoComplete="one-time-code"
              inputMode="numeric"
              required
            />
          </div>
        )}
        <Button type="submit" variant="hero" disabled={busy}>
          {busy ? "Saving..." : "Change password"}
        </Button>
      </form>
    </Card>
  );
}
