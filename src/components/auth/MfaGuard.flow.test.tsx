// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const path = vi.hoisted(() => ({ current: "/login" }));
const loadMfaState = vi.hoisted(() => vi.fn());
vi.mock("@tanstack/react-router", () => ({
  useRouterState: ({ select }: { select: (s: { location: { pathname: string } }) => unknown }) =>
    select({ location: { pathname: path.current } }),
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: { onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }) },
  },
}));
vi.mock("@/lib/mfa", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/lib/mfa")>()),
  loadMfaState,
}));
vi.mock("@/components/auth/MfaChallengeScreen", () => ({
  MfaChallengeScreen: () => <div data-testid="challenge">Enter your code</div>,
}));

import { MfaGuard } from "./MfaGuard";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;
const page = () => (
  <MfaGuard>
    <div data-testid="private">Private page</div>
  </MfaGuard>
);
beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  loadMfaState.mockReset();
  path.current = "/login";
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});
const has = (id: string) => host.querySelector(`[data-testid="${id}"]`) !== null;

it("shows nothing private while the code check is still running after leaving a public page", async () => {
  let finish!: (v: unknown) => void;
  loadMfaState.mockReturnValue(new Promise((resolve) => (finish = resolve)));

  await act(async () => root.render(page())); // on /login: open, nothing to check
  expect(has("private")).toBe(true);

  path.current = "/pharmacy";
  await act(async () => root.render(page())); // now on a private page, check still pending
  expect(has("private")).toBe(false);
  expect(has("challenge")).toBe(false);

  await act(async () =>
    finish({ enrolled: true, needsChallenge: true, factorId: "f1", factors: [] }),
  );
  expect(has("private")).toBe(false);
  expect(has("challenge")).toBe(true);
});

it("shows the page once the check says no code is needed", async () => {
  loadMfaState.mockResolvedValue({
    enrolled: false,
    needsChallenge: false,
    factorId: null,
    factors: [],
  });
  path.current = "/pharmacy";
  await act(async () => root.render(page()));
  expect(has("private")).toBe(true);
  expect(has("challenge")).toBe(false);
});

it("lets the page through if the check itself fails, as before", async () => {
  loadMfaState.mockRejectedValue(new Error("offline"));
  path.current = "/pharmacy";
  await act(async () => root.render(page()));
  expect(has("private")).toBe(true);
});
