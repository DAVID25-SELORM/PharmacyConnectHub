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

function tokenSession(token: string): { userId: string; sessionId: string } | null {
  try {
    const payload = token.split(".")[1] ?? "";
    const json = Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString(
      "utf8",
    );
    const claims = JSON.parse(json) as { sub?: unknown; session_id?: unknown };
    return typeof claims.sub === "string" && typeof claims.session_id === "string"
      ? { userId: claims.sub, sessionId: claims.session_id }
      : null;
  } catch {
    return null;
  }
}

/**
 * The level to judge the session by: "aal2" when it passed the code step, or when the database
 * says it was opened on a device remembered within the last 7 days. If the database cannot say,
 * the token's own level stands.
 */
export async function sessionAssuranceLevel(
  client: RpcClient,
  token: string,
): Promise<"aal1" | "aal2"> {
  if (tokenAssuranceLevel(token) === "aal2") return "aal2";
  const session = tokenSession(token);
  if (!session) return "aal1";
  try {
    const { data, error } = await client.rpc("mfa_remembered_session_ok", {
      p_user_id: session.userId,
      p_session_id: session.sessionId,
    });
    return !error && data === true ? "aal2" : "aal1";
  } catch {
    return "aal1";
  }
}

/** False only when the rule is on and this admin session has not satisfied two-step. */
export async function adminSessionAllowed(client: RpcClient, token: string): Promise<boolean> {
  const { data, error } = await client.rpc("admin_mfa_ok", {
    p_aal: await sessionAssuranceLevel(client, token),
  });
  // If the database cannot answer, refuse: these are admin powers.
  return !error && data === true;
}
