// "Remember this device for 7 days." After the authenticator code, this browser keeps a random key. On the next sign-in the password is entered as usual and the key is offered to
// the database, which decides whether the code is still needed. Nothing here decides that: a missing, expired or forgotten key simply means the code is asked for.
//
// The key stays after signing out (that is the point), is separate for each person, and opens nothing without that person's password.
import { supabase } from "@/integrations/supabase/client";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export const REMEMBER_DAYS = 7;
const storageKey = (userId: string) => `drugxone.device.${userId}`;

function read(userId: string): string | null {
  try {
    return window.localStorage.getItem(storageKey(userId));
  } catch {
    return null;
  }
}

function write(userId: string, token: string | null) {
  try {
    if (token) window.localStorage.setItem(storageKey(userId), token);
    else window.localStorage.removeItem(storageKey(userId));
  } catch {
    // Storage can be blocked (a private window): the code is simply asked for next time.
  }
}

/** The signed-in person and which sign-in session this is. */
async function currentSession(): Promise<{ userId: string; sessionId: string } | null> {
  const { data } = await supabase.auth.getSession();
  const session = data.session;
  if (!session?.user?.id) return null;
  let sessionId = "";
  try {
    const payload = session.access_token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    sessionId = (JSON.parse(atob(payload)) as { session_id?: string }).session_id ?? "";
  } catch {
    // An unreadable token only means this session cannot be recognised again below.
  }
  return { userId: session.user.id, sessionId };
}

// The app re-checks whenever the tab is focused. A network blip during such a re-check must not throw someone who was already let in back to the code screen (and lose what they
// were typing), so a "yes" is remembered for that one session. The database still refuses anything it should.
let acceptedSession: string | null = null;

/** True when the database accepts this device's key for the current session, so no code is needed. */
export async function acceptRememberedDevice(): Promise<boolean> {
  const who = await currentSession();
  if (!who) return false;
  const token = read(who.userId);
  if (!token) return false;
  let answer: { data: unknown; error: unknown };
  try {
    answer = await db.rpc("use_remembered_device", { p_token: token });
  } catch (error) {
    answer = { data: null, error };
  }
  if (answer.error) return who.sessionId !== "" && acceptedSession === who.sessionId;
  if (answer.data === true) {
    acceptedSession = who.sessionId;
    return true;
  }
  // The database said no (expired, forgotten, password changed): the key is of no further use.
  acceptedSession = null;
  write(who.userId, null);
  return false;
}

/** Called right after a code was accepted. Failing is harmless: the code is asked for next time. */
export async function rememberThisDevice(): Promise<boolean> {
  const who = await currentSession();
  if (!who) return false;
  try {
    const label = typeof navigator === "undefined" ? "" : navigator.userAgent.slice(0, 200);
    const { data, error } = await db.rpc("remember_this_device", { p_label: label });
    if (error || typeof data !== "string") return false;
    write(who.userId, data);
    return true;
  } catch {
    return false;
  }
}

const notThereYet = (error: { code?: string; message?: string }) =>
  /PGRST202|42883|could not find the function|does not exist/i.test(
    `${error.code ?? ""} ${error.message ?? ""}`,
  );

/**
 * Forgets remembered devices: all of them, or all but this one. Returns an error message, or null
 * when done. Used by "sign out other devices / everywhere", which must not leave a lost device remembered.
 */
export async function forgetRememberedDevices(options: {
  keepThisOne: boolean;
}): Promise<string | null> {
  const who = await currentSession();
  const keep = options.keepThisOne && who ? read(who.userId) : null;
  const { error } = await db.rpc("forget_my_devices", { p_keep_token: keep });
  // Before the database update there are no remembered devices, so there is nothing to forget.
  if (error && !notThereYet(error)) return error.message;
  if (!options.keepThisOne && who) {
    write(who.userId, null);
    acceptedSession = null;
  }
  return null;
}

/** How many devices are remembered for this person, or null when that cannot be told. */
export async function countRememberedDevices(): Promise<number | null> {
  try {
    const { data, error } = await db.rpc("my_remembered_device_count");
    return error || typeof data !== "number" ? null : data;
  } catch {
    return null;
  }
}
