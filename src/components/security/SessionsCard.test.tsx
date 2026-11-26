// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const calls = vi.hoisted(() => [] as string[]);
const forget = vi.hoisted(() => vi.fn());
const toast = vi.hoisted(() => ({ success: vi.fn(), error: vi.fn() }));
vi.mock("sonner", () => ({ toast }));
vi.mock("@/lib/confirm-action", () => ({ confirmAction: async () => true }));
vi.mock("@/lib/remembered-device", () => ({ forgetRememberedDevices: forget }));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    auth: {
      signOut: async ({ scope }: { scope: string }) => {
        calls.push(`sign out ${scope}`);
        return { error: null };
      },
    },
  },
}));

import { SessionsCard } from "./SessionsCard";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let root: Root;
let box: HTMLDivElement;
beforeEach(async () => {
  calls.length = 0;
  forget.mockReset();
  toast.error.mockReset();
  toast.success.mockReset();
  box = document.createElement("div");
  document.body.append(box);
  root = createRoot(box);
  await act(async () => root.render(<SessionsCard />));
});
afterEach(async () => {
  await act(async () => root.unmount());
  box.remove();
});
const press = async (label: string) => {
  const button = [...box.querySelectorAll("button")].find((b) => b.textContent?.trim() === label)!;
  await act(async () => button.click());
};
const forgets = (answer: string | null) =>
  forget.mockImplementation(async ({ keepThisOne }: { keepThisOne: boolean }) => {
    calls.push(keepThisOne ? "forget other devices" : "forget every device");
    return answer;
  });

// A lost laptop must not stay remembered: forgetting comes first.
it("forgets the other remembered devices before signing them out", async () => {
  forgets(null);
  await press("Sign out other devices");
  expect(calls).toEqual(["forget other devices", "sign out others"]);
  expect(toast.success).toHaveBeenCalled();
});

it("forgets every remembered device before signing out everywhere", async () => {
  forgets(null);
  await press("Sign out everywhere");
  expect(calls).toEqual(["forget every device", "sign out global"]);
});

it.each(["Sign out other devices", "Sign out everywhere"])(
  "%s: changes nothing and says so when devices cannot be forgotten",
  async (label) => {
    forgets("the database is unhappy");
    await press(label);
    expect(calls.filter((c) => c.startsWith("sign out"))).toEqual([]);
    expect(toast.error).toHaveBeenCalledWith("Nothing was changed: the database is unhappy");
    expect(toast.success).not.toHaveBeenCalled();
  },
);
