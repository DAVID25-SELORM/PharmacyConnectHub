import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

/**
 * One field for the 6-digit code from an authenticator app.
 * `onSubmit` resolves to an error message, or null when the code was accepted.
 */
export function MfaCodeForm({
  onSubmit,
  submitLabel = "Verify code",
  autoFocus = true,
}: {
  onSubmit: (code: string) => Promise<string | null>;
  submitLabel?: string;
  autoFocus?: boolean;
}) {
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const message = await onSubmit(code);
      if (message) {
        setError(message);
        setCode("");
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-3" noValidate>
      <div className="space-y-2">
        <Label htmlFor="mfa-code">6-digit code</Label>
        <Input
          id="mfa-code"
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/[^\d\s-]/g, "").slice(0, 7))}
          inputMode="numeric"
          autoComplete="one-time-code"
          placeholder="123 456"
          autoFocus={autoFocus}
          aria-describedby={error ? "mfa-code-error" : undefined}
          aria-invalid={error ? true : undefined}
          className="text-center text-lg tracking-widest"
        />
        {error && (
          <p id="mfa-code-error" role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
      </div>
      <Button type="submit" variant="hero" className="w-full" disabled={busy || code.length < 6}>
        {busy ? "Checking..." : submitLabel}
      </Button>
    </form>
  );
}
