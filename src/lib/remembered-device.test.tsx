// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const server = vi.hoisted(() => ({
  rpc: vi.fn(),
  session: null as null | { user: { id: string }; access_token: string },
  aal: { currentLevel: "aal1", nextLevel: "aal2" },
  verify: vi.fn(),
}));
vi.mock("@/integrations/supabase/client", () => ({
  supabase: {
    rpc: server.rpc,
    auth: {
      getSession: async () => ({ data: { session: server.session }, error: null }),
      mfa: {
        getAuthenticatorAssuranceLevel: async () => ({ data: server.aal, error: null }),
        listFactors: async () => ({
          data: {
            totp: [{ id: "factor-1", friendly_name: "App", created_at: "2026-01-01" }],
            all: [],
          },
          error: null,
        }),
        challengeAndVerify: server.verify,
      },
    },
  },
}));

const sessionFor = (userId: string, sessionId: string) => ({
  user: { id: userId },
  access_token: `x.${Buffer.from(JSON.stringify({ session_id: sessionId })).toString("base64url")}.y`,
});
const KEY = "drugxone.device.user-1";
const ok = (data: unknown) => ({ data, error: null });

let lib: typeof import("./remembered-device");
let mfa: typeof import("./mfa");
beforeEach(async () => {
  vi.resetModules();
  lib = await import("./remembered-device");
  mfa = await import("./mfa");
  server.rpc.mockReset();
  server.verify.mockReset();
  server.session = sessionFor("user-1", "session-1");
  server.aal = { currentLevel: "aal1", nextLevel: "aal2" };
  window.localStorage.clear();
});

it("asks for the code on a new device without asking the database anything", async () => {
  expect(await lib.acceptRememberedDevice()).toBe(false);
  expect(server.rpc).not.toHaveBeenCalled();
  expect((await mfa.loadMfaState({ allowRememberedDevice: true })).needsChallenge).toBe(true);
});

it("lets a remembered device in when the database accepts its key", async () => {
  window.localStorage.setItem(KEY, "device-key");
  server.rpc.mockResolvedValue(ok(true));
  expect((await mfa.loadMfaState({ allowRememberedDevice: true })).needsChallenge).toBe(false);
  expect(server.rpc).toHaveBeenCalledWith("use_remembered_device", { p_token: "device-key" });
});

it("still asks for a real code where one is required (password reset, two-step settings)", async () => {
  window.localStorage.setItem(KEY, "device-key");
  server.rpc.mockResolvedValue(ok(true));
  expect((await mfa.loadMfaState({ withFactors: true })).needsChallenge).toBe(true);
  expect(server.rpc).not.toHaveBeenCalled();
});

it("asks again and discards the key once the database refuses it", async () => {
  window.localStorage.setItem(KEY, "old-key");
  server.rpc.mockResolvedValue(ok(false));
  expect((await mfa.loadMfaState({ allowRememberedDevice: true })).needsChallenge).toBe(true);
  expect(window.localStorage.getItem(KEY)).toBeNull();
});

it("never uses one person's key for another", async () => {
  window.localStorage.setItem(KEY, "device-key");
  server.session = sessionFor("user-2", "session-9");
  expect(await lib.acceptRememberedDevice()).toBe(false);
  expect(server.rpc).not.toHaveBeenCalled();
});

it("asks for the code if the database cannot be reached at sign-in, and keeps the key", async () => {
  window.localStorage.setItem(KEY, "device-key");
  server.rpc.mockResolvedValue({ data: null, error: { message: "offline" } });
  expect(await lib.acceptRememberedDevice()).toBe(false);
  expect(window.localStorage.getItem(KEY)).toBe("device-key");
});

it("does not throw someone back to the code screen over a blip, in the same session only", async () => {
  window.localStorage.setItem(KEY, "device-key");
  server.rpc.mockResolvedValue(ok(true));
  expect(await lib.acceptRememberedDevice()).toBe(true);
  server.rpc.mockRejectedValue(new Error("network"));
  expect(await lib.acceptRememberedDevice()).toBe(true);
  server.session = sessionFor("user-1", "session-2");
  expect(await lib.acceptRememberedDevice()).toBe(false);
});

it("keeps the key the database hands out, and stays harmless when it will not", async () => {
  server.rpc.mockResolvedValue(ok("new-key"));
  expect(await lib.rememberThisDevice()).toBe(true);
  expect(window.localStorage.getItem(KEY)).toBe("new-key");
  window.localStorage.clear();
  server.rpc.mockResolvedValue({
    data: null,
    error: { message: "Enter your authenticator code again" },
  });
  expect(await lib.rememberThisDevice()).toBe(false);
  expect(window.localStorage.getItem(KEY)).toBeNull();
});

it("forgets other devices but keeps this one's key, or forgets everything", async () => {
  window.localStorage.setItem(KEY, "device-key");
  server.rpc.mockResolvedValue(ok(2));
  expect(await lib.forgetRememberedDevices({ keepThisOne: true })).toBeNull();
  expect(server.rpc).toHaveBeenLastCalledWith("forget_my_devices", { p_keep_token: "device-key" });
  expect(window.localStorage.getItem(KEY)).toBe("device-key");
  expect(await lib.forgetRememberedDevices({ keepThisOne: false })).toBeNull();
  expect(server.rpc).toHaveBeenLastCalledWith("forget_my_devices", { p_keep_token: null });
  expect(window.localStorage.getItem(KEY)).toBeNull();
});

it("says when devices could not be forgotten, so nothing is claimed that did not happen", async () => {
  window.localStorage.setItem(KEY, "device-key");
  server.rpc.mockResolvedValue({
    data: null,
    error: { code: "XX000", message: "the database is unhappy" },
  });
  expect(await lib.forgetRememberedDevices({ keepThisOne: false })).toBe("the database is unhappy");
  expect(window.localStorage.getItem(KEY)).toBe("device-key");
  server.rpc.mockResolvedValue({
    data: null,
    error: { code: "PGRST202", message: "Could not find the function" },
  });
  expect(await lib.forgetRememberedDevices({ keepThisOne: false })).toBeNull();
});

// The code step itself ------------------------------------------------------------------------------
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let root: Root | null = null;
let box: HTMLDivElement | null = null;
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  box?.remove();
  root = null;
});

const enterCode = async (untick: boolean) => {
  const { RememberedMfaCodeForm } = await import("@/components/auth/RememberedMfaCodeForm");
  const onVerified = vi.fn();
  box = document.createElement("div");
  document.body.append(box);
  root = createRoot(box);
  await act(async () =>
    root!.render(<RememberedMfaCodeForm factorId="factor-1" onVerified={onVerified} />),
  );
  const tick = box.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
  expect(tick.checked).toBe(true);
  if (untick) await act(async () => tick.click());
  const field = box.querySelector<HTMLInputElement>("#mfa-code")!;
  const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    set.call(field, "123456");
    field.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await act(async () => {
    box!
      .querySelector("form")!
      .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  return onVerified;
};

it("remembers the device after an accepted code when the box stays ticked", async () => {
  server.verify.mockResolvedValue({ error: null });
  server.rpc.mockResolvedValue(ok("new-key"));
  const onVerified = await enterCode(false);
  expect(server.rpc).toHaveBeenCalledWith("remember_this_device", expect.anything());
  expect(onVerified).toHaveBeenCalledOnce();
});

it("remembers nothing when the box is unticked (a shared computer)", async () => {
  server.verify.mockResolvedValue({ error: null });
  const onVerified = await enterCode(true);
  expect(server.rpc).not.toHaveBeenCalled();
  expect(window.localStorage.getItem(KEY)).toBeNull();
  expect(onVerified).toHaveBeenCalledOnce();
});

it("remembers nothing when the code is wrong", async () => {
  server.verify.mockResolvedValue({ error: { code: "mfa_verification_failed" } });
  const onVerified = await enterCode(false);
  expect(server.rpc).not.toHaveBeenCalled();
  expect(onVerified).not.toHaveBeenCalled();
});
