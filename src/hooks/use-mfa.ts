import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { loadMfaState, NO_MFA, type MfaState } from "@/lib/mfa";

/**
 * Two-step verification state for the signed-in person. `enabled = false` skips the
 * work entirely, for public pages that have nothing to protect.
 */
export function useMfaState(
  options: { enabled?: boolean; withFactors?: boolean; allowRememberedDevice?: boolean } = {},
) {
  const { enabled = true, withFactors = false, allowRememberedDevice = false } = options;
  const [state, setState] = useState<MfaState>(NO_MFA);
  // True once the check has run for the page being shown. It is reset while on a page that skips
  // the check, so moving from a public page (such as the sign-in page) to a private one counts
  // as "not checked yet" and the guard waits instead of showing the page for a moment first.
  const [settled, setSettled] = useState(false);
  const loading = enabled && !settled;

  const refresh = useCallback(async () => {
    if (!enabled) {
      setState(NO_MFA);
      setSettled(false);
      return;
    }
    try {
      setState(await loadMfaState({ withFactors, allowRememberedDevice }));
    } catch {
      setState(NO_MFA);
    } finally {
      setSettled(true);
    }
  }, [enabled, withFactors, allowRememberedDevice]);

  useEffect(() => {
    void refresh();
    if (!enabled) return;
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event) => {
      // Defer: Supabase must not be called from inside its own auth callback.
      if (
        event === "SIGNED_IN" ||
        event === "SIGNED_OUT" ||
        event === "MFA_CHALLENGE_VERIFIED" ||
        event === "USER_UPDATED"
      ) {
        setTimeout(() => void refresh(), 0);
      }
    });
    return () => subscription.unsubscribe();
  }, [enabled, refresh]);

  return { state, loading, refresh };
}
