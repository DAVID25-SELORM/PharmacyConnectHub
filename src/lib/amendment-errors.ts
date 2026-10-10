// The message to show when an order-amendment action (propose, respond, ship, report...) fails. The database writes clear
// messages for every business rule; the one case it cannot word itself is an action the platform owner has switched off for now
// (the function is then not callable at all), which the database reports as "permission denied for function ...".
export function amendmentError(error: unknown): string {
  const message = (error as { message?: string } | null)?.message ?? "";
  if (/permission denied for function/i.test(message)) {
    return "This action is switched off for now. Please try again later, or contact support if it is urgent.";
  }
  return message || "Something went wrong. Please try again.";
}
