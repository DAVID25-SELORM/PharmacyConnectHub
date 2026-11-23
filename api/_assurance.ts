// Two-step verification for platform admins on the server side.
//
// The Vercel API handlers verify the caller's token and then act with the service role, so the
// database cannot see which assurance level the session reached. They read it from the token
// here (already verified by Supabase before this is called) and ask the database whether the
// platform's admin two-step rule is satisfied. The rule is off until an admin turns it on.

type RpcClient = {
  rpc: (
    fn: string,
    args: Record<string, unknown>,
  ) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
};

/** "aal2" when the session passed the authenticator-app code, otherwise "aal1". */
export function tokenAssuranceLevel(token: string): "aal1" | "aal2" {
  try {
    const payload = token.split(".")[1];
    if (!payload) return "aal1";
    const json = Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString(
      "utf8",
    );
    return (JSON.parse(json) as { aal?: unknown }).aal === "aal2" ? "aal2" : "aal1";
  } catch {
    return "aal1";
  }
}

/** False only when the rule is on and this admin session has not passed the code step. */
export async function adminSessionAllowed(client: RpcClient, token: string): Promise<boolean> {
  const { data, error } = await client.rpc("admin_mfa_ok", { p_aal: tokenAssuranceLevel(token) });
  // If the database cannot answer, refuse: these are admin powers.
  return !error && data === true;
}
