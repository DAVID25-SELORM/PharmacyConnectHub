/** Strict allowlist: never include error messages, URLs, identities or session objects. */
export function authDiagnostic(
  event: string,
  error?: unknown,
  extra: {
    hasSession?: boolean;
    count?: number;
    decision?: string;
    projectHost?: string;
  } = {},
) {
  const e =
    error && typeof error === "object" ? (error as { code?: unknown; status?: unknown }) : {};
  console.info("[DrugXOne auth]", {
    event,
    code: typeof e.code === "string" && /^[A-Za-z0-9_]+$/.test(e.code) ? e.code : null,
    status: typeof e.status === "number" ? e.status : null,
    ...extra,
  });
}

export async function withAuthTimeout<T>(operation: PromiseLike<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      Promise.resolve(operation),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject({ code: "auth_load_timeout" }), 20000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
