import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { loadMfaState, NO_MFA, type MfaState } from "@/lib/mfa";

/**
 * Two-step verification state for the signed-in person. `enabled = false` skips the
 * work entirely, for public pages that have nothing to protect.
 */
export function useMfaState(options: { enabled?: boolean; withFactors?: boolean } = {}) {
  const { enabled = true, withFactors = false } = options;
  const [state, setState] = useState<MfaState>(NO_MFA);
  const [loading, setLoading] = useState(enabled);

  const refresh = useCallback(async () => {
    if (!enabled) {
      setState(NO_MFA);
      setLoading(false);
      return;
    }
    try {
      setState(await loadMfaState({ withFactors }));
    } catch {
      setState(NO_MFA);
    } finally {
      setLoading(false);
    }
  }, [enabled, withFactors]);

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
