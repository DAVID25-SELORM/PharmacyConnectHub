import { supabase } from "@/integrations/supabase/client";

export interface AdminMfaStatus {
  required: boolean;
  admins: { user_id: string; email: string; enrolled: boolean }[];
}

// The functions are newer than the generated Supabase types.
const rpc = (name: string, args: Record<string, unknown> = {}) =>
  (
    supabase as unknown as {
      rpc: (
        n: string,
        a: Record<string, unknown>,
      ) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
    }
  ).rpc(name, args);

export async function loadAdminMfaStatus(): Promise<AdminMfaStatus | null> {
  const { data, error } = await rpc("get_admin_mfa_status");
  if (error || !data) return null;
  return data as AdminMfaStatus;
}

/** Returns an error message, or null when the setting was saved. */
export async function setAdminMfaRequired(required: boolean): Promise<string | null> {
  const { error } = await rpc("set_admin_mfa_required", { p_required: required });
  return error ? error.message : null;
}

/** Admins who still need to set up an authenticator app before the rule can be turned on. */
export function adminsWithoutMfa(status: AdminMfaStatus): string[] {
  return status.admins.filter((a) => !a.enrolled).map((a) => a.email);
}
