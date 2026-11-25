import { supabase } from "@/integrations/supabase/client";
import { acceptRememberedDevice } from "@/lib/remembered-device";

/**
 * Two-step verification with an authenticator app (TOTP), using Supabase Auth.
 *
 * A signed-in session has an assurance level: "aal1" after the password alone,
 * "aal2" once a code from an enrolled authenticator app has been checked.
 */

export interface MfaFactor {
  id: string;
  friendlyName: string;
  createdAt: string;
}

export interface MfaState {
  /** The person has at least one verified authenticator app. */
  enrolled: boolean;
  /** Signed in with a password but the code for this session has not been entered. */
  needsChallenge: boolean;
  /** Factor to challenge: the first verified authenticator app. */
  factorId: string | null;
  factors: MfaFactor[];
}

export const NO_MFA: MfaState = {
  enrolled: false,
  needsChallenge: false,
  factorId: null,
  factors: [],
};

type AalLevel = string | null | undefined;

/** Pure decision used by the guard, kept separate so it can be tested without a network. */
export function interpretAssurance(
  currentLevel: AalLevel,
  nextLevel: AalLevel,
  factors: MfaFactor[],
): MfaState {
  const enrolled = factors.length > 0;
  return {
    enrolled,
    needsChallenge: enrolled && currentLevel === "aal1" && nextLevel === "aal2",
    factorId: factors[0]?.id ?? null,
    factors,
  };
}

/** Accepts "123 456", "123-456" or "123456" and returns the six digits, or null. */
export function parseTotpCode(input: string): string | null {
  const digits = input.replace(/[\s-]/g, "");
  return /^\d{6}$/.test(digits) ? digits : null;
}

/** Turns the provider's error into something a pharmacist can act on. */
export function mfaErrorMessage(error: { message?: string; code?: string } | null): string {
  if (!error) return "Something went wrong. Please try again.";
  if (
    error.code === "mfa_verification_failed" ||
    /invalid.*(code|totp)/i.test(error.message ?? "")
  ) {
    return "That code is not right. Open your authenticator app and enter the current 6-digit code.";
  }
  if (
    error.code === "over_request_rate_limit" ||
    /rate limit|too many/i.test(error.message ?? "")
  ) {
    return "Too many attempts. Wait a minute and try again.";
  }
  return error.message || "Something went wrong. Please try again.";
}

/**
 * Reads the session's assurance level (a local read) and, only when a code is needed or
 * the caller wants the full list for the settings page, the person's authenticator apps.
 */
export async function loadMfaState(
  options: { withFactors?: boolean; allowRememberedDevice?: boolean } = {},
): Promise<MfaState> {
  const aal = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (aal.error) {
    // Fail open on a read error so a network blip does not lock people out; the database
    // still enforces the platform-admin rule on its own.
    return NO_MFA;
  }
  const needsFactors = options.withFactors || aal.data?.nextLevel === "aal2";
  if (!needsFactors) return NO_MFA;
  const factorList = await supabase.auth.mfa.listFactors();
  if (factorList.error) {
    // A code is required but the app list did not load: stay locked rather than skip the step.
    return aal.data?.nextLevel === "aal2" && aal.data.currentLevel === "aal1"
      ? { enrolled: true, needsChallenge: true, factorId: null, factors: [] }
      : NO_MFA;
  }
  const factors: MfaFactor[] = (factorList.data?.totp ?? []).map((f) => ({
    id: f.id,
    friendlyName: f.friendly_name ?? "Authenticator app",
    createdAt: f.created_at,
  }));
  const state = interpretAssurance(aal.data?.currentLevel, aal.data?.nextLevel, factors);
  // Opening the app on a remembered device needs no code. Callers that need a real code (password reset,
  // two-step settings) leave this off, because the sign-in service insists on one for those.
  if (state.needsChallenge && options.allowRememberedDevice && (await acceptRememberedDevice())) {
    return { ...state, needsChallenge: false };
  }
  return state;
}

/** Checks a code for an enrolled factor. Returns an error message, or null when it worked. */
export async function verifyMfaCode(factorId: string, rawCode: string): Promise<string | null> {
  const code = parseTotpCode(rawCode);
  if (!code) return "Enter the 6-digit code from your authenticator app.";
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code });
  return error ? mfaErrorMessage(error) : null;
}

export interface TotpEnrolment {
  factorId: string;
  /** SVG data URI of the QR code. */
  qrCode: string;
  /** Same secret as text, for people who cannot scan. */
  secret: string;
}

export async function startTotpEnrolment(): Promise<
  { ok: true; enrolment: TotpEnrolment } | { ok: false; message: string }
> {
  // Clear half-finished attempts so the list never fills with unverified factors.
  const existing = await supabase.auth.mfa.listFactors();
  for (const factor of existing.data?.all ?? []) {
    if (factor.factor_type === "totp" && factor.status === "unverified") {
      await supabase.auth.mfa.unenroll({ factorId: factor.id });
    }
  }
  const { data, error } = await supabase.auth.mfa.enroll({
    factorType: "totp",
    issuer: "Drugxone",
    friendlyName: `Authenticator ${new Date().toISOString().slice(0, 10)}`,
  });
  if (error || !data) return { ok: false, message: mfaErrorMessage(error) };
  return {
    ok: true,
    enrolment: { factorId: data.id, qrCode: data.totp.qr_code, secret: data.totp.secret },
  };
}

export async function cancelTotpEnrolment(factorId: string): Promise<void> {
  await supabase.auth.mfa.unenroll({ factorId });
}

export async function removeMfaFactor(factorId: string): Promise<string | null> {
  const { error } = await supabase.auth.mfa.unenroll({ factorId });
  return error ? mfaErrorMessage(error) : null;
}
