const PRIVATE_TEAM_GUIDANCE_EMAILS = new Set(["xtalcfc@gmail.com"]);

function normalizeEmail(email: string | null | undefined) {
  return email?.trim().toLowerCase() ?? "";
}

export function shouldShowPrivateTeamGuidance(email: string | null | undefined) {
  return PRIVATE_TEAM_GUIDANCE_EMAILS.has(normalizeEmail(email));
}
