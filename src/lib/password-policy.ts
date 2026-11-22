/**
 * Password rules for choosing a NEW password (sign-up, reset, change).
 * Signing in never applies these, so existing accounts with older, shorter
 * passwords keep working until their owner next changes the password.
 *
 * The rules follow current guidance: length matters most, a block list of
 * obvious passwords, nothing built from the person's own email or name, and no
 * forced symbol gymnastics for long passphrases.
 */

export const PASSWORD_MIN_LENGTH = 10;
/** Supabase hashes with bcrypt, which ignores everything past 72 characters. */
export const PASSWORD_MAX_LENGTH = 72;
/** At or above this length a passphrase is accepted without mixing character types. */
export const PASSPHRASE_LENGTH = 16;

export interface PasswordContext {
  email?: string;
  name?: string;
}

export interface PasswordCheck {
  ok: boolean;
  /** Plain-language reasons the password was refused, empty when ok. */
  issues: string[];
  /** 0 (very weak) to 4 (strong), for the strength meter. */
  score: 0 | 1 | 2 | 3 | 4;
  label: "Too weak" | "Weak" | "Fair" | "Good" | "Strong";
}

/** Passwords people really use. Compared after stripping digits and symbols. */
const COMMON_STEMS = new Set([
  "password",
  "passw0rd",
  "passcode",
  "letmein",
  "welcome",
  "welcome1",
  "admin",
  "administrator",
  "administrator1",
  "qwerty",
  "qwertyuiop",
  "asdfgh",
  "asdfghjkl",
  "zxcvbn",
  "zxcvbnm",
  "abcdef",
  "abcdefgh",
  "iloveyou",
  "monkey",
  "dragon",
  "football",
  "baseball",
  "master",
  "shadow",
  "sunshine",
  "princess",
  "login",
  "secret",
  "changeme",
  "trustno",
  "ghana",
  "accra",
  "kumasi",
  "pharmacy",
  "pharmacist",
  "wholesale",
  "wholesaler",
  "medicine",
  "drugxone",
  "healthflow",
  "nhis",
  "test",
  "testing",
  "user",
  "demo",
]);

const COMMON_WHOLE = new Set([
  "1234567890",
  "12345678910",
  "0123456789",
  "9876543210",
  "1q2w3e4r5t",
  "1qaz2wsx3edc",
  "0987654321",
  "1111111111",
  "0000000000",
]);

function stemOf(password: string): string {
  return password.toLowerCase().replace(/[^a-z]/g, "");
}

function isCommon(password: string): boolean {
  const lower = password.toLowerCase();
  if (COMMON_WHOLE.has(lower)) return true;
  const stem = stemOf(password);
  if (COMMON_STEMS.has(stem)) return true;
  // "Password2024!" style: a common word plus a few digits or symbols.
  for (const word of COMMON_STEMS) {
    if (word.length >= 5 && lower.startsWith(word)) {
      const rest = lower.slice(word.length).replace(/[^a-z]/g, "");
      if (rest.length === 0) return true;
    }
  }
  return false;
}

function isRepetitive(password: string): boolean {
  if (new Set(password).size < 5) return true;
  // A single repeated block, e.g. "abcabcabcabc".
  return /^(.{1,4})\1{2,}$/.test(password);
}

function containsSequence(password: string): boolean {
  const lower = password.toLowerCase();
  let run = 1;
  let direction = 0;
  for (let i = 1; i < lower.length; i++) {
    const diff = lower.charCodeAt(i) - lower.charCodeAt(i - 1);
    if ((diff === 1 || diff === -1) && (direction === 0 || direction === diff)) {
      direction = diff;
      run++;
      // Most of the password is one run, e.g. "abcdefghijk" or "9876543210".
      if (run >= Math.max(6, Math.ceil(lower.length * 0.7))) return true;
    } else {
      run = 1;
      direction = 0;
    }
  }
  return false;
}

function classCount(password: string): number {
  return [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((re) => re.test(password)).length;
}

function usesPersonalDetails(password: string, context: PasswordContext): boolean {
  const lower = password.toLowerCase();
  const local =
    context.email
      ?.split("@")[0]
      ?.toLowerCase()
      .replace(/[^a-z0-9]/g, "") ?? "";
  if (local.length >= 4 && lower.replace(/[^a-z0-9]/g, "").includes(local)) return true;
  const words = (context.name ?? "")
    .toLowerCase()
    .split(/[^a-z]+/)
    .filter((w) => w.length >= 4);
  return words.some((w) => lower.includes(w));
}

const LABELS: PasswordCheck["label"][] = ["Too weak", "Weak", "Fair", "Good", "Strong"];

export function checkPassword(password: string, context: PasswordContext = {}): PasswordCheck {
  const issues: string[] = [];
  if (password.length < PASSWORD_MIN_LENGTH) {
    issues.push(`Use at least ${PASSWORD_MIN_LENGTH} characters.`);
  }
  if (password.length > PASSWORD_MAX_LENGTH) {
    issues.push(`Use ${PASSWORD_MAX_LENGTH} characters or fewer.`);
  }
  if (password.length >= 1) {
    if (isCommon(password))
      issues.push("This is a very common password. Choose something less obvious.");
    else if (isRepetitive(password)) issues.push("Avoid repeating the same characters.");
    else if (containsSequence(password)) issues.push("Avoid keyboard or number sequences.");
    if (usesPersonalDetails(password, context)) {
      issues.push("Do not use your email address or name in your password.");
    }
    if (
      password.length >= PASSWORD_MIN_LENGTH &&
      password.length < PASSPHRASE_LENGTH &&
      classCount(password) < 2
    ) {
      issues.push(
        `Mix letters with numbers or symbols, or use ${PASSPHRASE_LENGTH}+ characters (a passphrase).`,
      );
    }
  }

  let points = 0;
  if (password.length >= PASSWORD_MIN_LENGTH) points++;
  if (password.length >= 14) points++;
  if (password.length >= PASSPHRASE_LENGTH + 4) points++;
  if (classCount(password) >= 3) points++;
  const capped = Math.min(points, 4) as 0 | 1 | 2 | 3 | 4;
  const score = (issues.length > 0 ? Math.min(capped, 1) : Math.max(capped, 2)) as
    0 | 1 | 2 | 3 | 4;

  return { ok: issues.length === 0, issues, score, label: LABELS[score] };
}
