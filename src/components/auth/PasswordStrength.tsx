import { checkPassword, PASSWORD_MIN_LENGTH, type PasswordContext } from "@/lib/password-policy";

const BAR_COLOURS = [
  "bg-destructive",
  "bg-destructive",
  "bg-amber-500",
  "bg-emerald-500",
  "bg-emerald-600",
];

/** Live strength meter and plain-language reasons shown under a new-password field. */
export function PasswordStrength({
  password,
  context,
}: {
  password: string;
  context?: PasswordContext;
}) {
  if (!password) {
    return (
      <p className="text-xs text-muted-foreground">
        Use at least {PASSWORD_MIN_LENGTH} characters. A few random words make a strong password.
      </p>
    );
  }
  const result = checkPassword(password, context);
  return (
    <div className="space-y-1" aria-live="polite">
      <div className="flex gap-1" aria-hidden="true">
        {[0, 1, 2, 3].map((i) => (
          <span
            key={i}
            className={`h-1.5 flex-1 rounded-full ${i < result.score ? BAR_COLOURS[result.score] : "bg-muted"}`}
          />
        ))}
      </div>
      <p className="text-xs font-medium">Password strength: {result.label}</p>
      {result.issues.map((issue) => (
        <p key={issue} className="text-xs text-destructive">
          {issue}
        </p>
      ))}
    </div>
  );
}
