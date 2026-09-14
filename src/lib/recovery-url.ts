export function cleanRecoveryUrl(href: string): string {
  const url = new URL(href);
  for (const key of [
    "code",
    "access_token",
    "refresh_token",
    "token",
    "recovery_token",
    "token_hash",
    "type",
    "error",
    "error_code",
    "error_description",
  ])
    url.searchParams.delete(key);
  url.hash = "";
  return url.toString();
}
