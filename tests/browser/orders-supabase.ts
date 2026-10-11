// Deliberately disconnected fixture: no network or authenticated session.
export const supabase = {
  auth: { getSession: async () => ({ data: { session: null } }) },
  rpc: async () => ({ data: [], error: null }),
};
