import { useRef, useState } from "react";
import { MfaCodeForm } from "@/components/auth/MfaCodeForm";
import { verifyMfaCode } from "@/lib/mfa";
import { REMEMBER_DAYS, rememberThisDevice } from "@/lib/remembered-device";

/** The code step at sign-in, with the choice to be asked again on this device only after 7 days. */
export function RememberedMfaCodeForm({
  factorId,
  onVerified,
}: {
  factorId: string;
  onVerified: () => void;
}) {
  const [remember, setRemember] = useState(true);
  // Read at the moment the code is accepted, whatever has re-rendered in between.
  const choice = useRef(remember);
  choice.current = remember;

  return (
    <div className="space-y-3">
      <label className="flex items-start gap-2 text-sm">
        <input
          type="checkbox"
          className="mt-0.5 h-4 w-4 shrink-0 accent-primary"
          checked={remember}
          onChange={(e) => setRemember(e.target.checked)}
        />
        <span>
          <span className="font-medium">Remember this device for {REMEMBER_DAYS} days</span>
          <span className="block text-xs text-muted-foreground">
            You will still need your password. Untick on a shared or public computer.
          </span>
        </span>
      </label>
      <MfaCodeForm
        onSubmit={async (code) => {
          const message = await verifyMfaCode(factorId, code);
          if (message) return message;
          if (choice.current) await rememberThisDevice();
          onVerified();
          return null;
        }}
      />
    </div>
  );
}
