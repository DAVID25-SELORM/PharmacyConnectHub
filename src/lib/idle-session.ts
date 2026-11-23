/**
 * Automatic sign-out after inactivity, so a till or office computer left open does not
 * stay signed in forever. Time is compared against a timestamp (not a running timer) so a
 * laptop that slept past the limit signs out the moment it wakes.
 */

export const BUSINESS_IDLE_MS = 60 * 60 * 1000; // pharmacies, wholesalers, clinics
export const ADMIN_IDLE_MS = 15 * 60 * 1000; // platform admins see every business
export const IDLE_WARNING_MS = 2 * 60 * 1000;
export const ACTIVITY_KEY = "drugxone.last_activity";

export type IdleStatus = "active" | "warning" | "expired";

export function idleLimitFor(roles: readonly string[]): number {
  return roles.includes("admin") ? ADMIN_IDLE_MS : BUSINESS_IDLE_MS;
}

export function idleStatus(
  now: number,
  lastActivity: number,
  limitMs: number,
  warningMs: number = IDLE_WARNING_MS,
): IdleStatus {
  const idle = now - lastActivity;
  if (idle >= limitMs) return "expired";
  if (idle >= limitMs - warningMs) return "warning";
  return "active";
}

export function secondsLeft(now: number, lastActivity: number, limitMs: number): number {
  return Math.max(0, Math.ceil((lastActivity + limitMs - now) / 1000));
}

export function readLastActivity(storage: Pick<Storage, "getItem"> | undefined, fallback: number) {
  try {
    const raw = storage?.getItem(ACTIVITY_KEY);
    const value = raw ? Number(raw) : NaN;
    return Number.isFinite(value) && value > 0 ? value : fallback;
  } catch {
    return fallback;
  }
}

export function writeLastActivity(storage: Pick<Storage, "setItem"> | undefined, at: number) {
  try {
    storage?.setItem(ACTIVITY_KEY, String(at));
  } catch {
    // Storage can be blocked; the in-memory value still protects this tab.
  }
}
