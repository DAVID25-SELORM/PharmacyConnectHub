import { useEffect, useState } from "react";
import type { Session, User } from "@supabase/supabase-js";
import { supabase } from "@/integrations/supabase/client";

export type AppRole = "admin" | "pharmacy" | "wholesaler";

export type Business = {
  id: string;
  type: "pharmacy" | "wholesaler";
  name: string;
  license_number: string | null;
  city: string | null;
  region: string | null;
  verification_status: "pending" | "approved" | "rejected";
  rejection_reason: string | null;
};

export type SessionState = {
  loading: boolean;
  session: Session | null;
  user: User | null;
  roles: AppRole[];
  business: Business | null;
};

export function useSession(): SessionState & { refresh: () => Promise<void> } {
  const [state, setState] = useState<SessionState>({
    loading: true,
    session: null,
    user: null,
    roles: [],
    business: null,
  });

  const loadExtras = async (user: User | null) => {
    if (!user) {
      setState({ loading: false, session: null, user: null, roles: [], business: null });
      return;
    }
    const [{ data: rolesData }, { data: bizData }] = await Promise.all([
      supabase.from("user_roles").select("role").eq("user_id", user.id),
      supabase.from("businesses").select("*").eq("owner_id", user.id).maybeSingle(),
    ]);
    const roles = (rolesData ?? []).map((r) => r.role as AppRole);
    setState((s) => ({
      ...s,
      loading: false,
      user,
      roles,
      business: (bizData as Business | null) ?? null,
    }));
  };

  const refresh = async () => {
    const { data } = await supabase.auth.getSession();
    setState((s) => ({ ...s, session: data.session }));
    await loadExtras(data.session?.user ?? null);
  };

  useEffect(() => {
    // Set listener BEFORE getSession (per Supabase guidance)
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      setState((s) => ({ ...s, session }));
      // defer extras to avoid blocking the callback
      setTimeout(() => loadExtras(session?.user ?? null), 0);
    });
    void refresh();
    return () => sub.subscription.unsubscribe();
  }, []);

  return { ...state, refresh };
}
