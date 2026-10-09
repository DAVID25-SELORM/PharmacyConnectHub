import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import type { SessionState } from "./use-session";
const mock = vi.hoisted(() => ({
  subscribe: null as null | ((listener: () => void) => () => void),
  listener: null as null | ((event: string, session: unknown) => void),
  getSession: vi.fn(),
  refreshSession: vi.fn(),
  signOut: vi.fn(),
  from: vi.fn(),
  onAuthStateChange: vi.fn(),
}));
vi.mock("react", () => ({
  useSyncExternalStore: (subscribe: typeof mock.subscribe, get: () => SessionState) => {
    mock.subscribe = subscribe;
    return get();
  },
}));
vi.mock("@/integrations/supabase/client", () => ({ supabase: { auth: mock, from: mock.from } }));
const session = { user: { id: "owner" }, expires_at: 9999999999, access_token: "SECRET_TOKEN" };
const business = {
  id: "business",
  name: "Private name",
  type: "pharmacy",
  verification_status: "approved",
  staff_role: "owner",
};
let read: () => SessionState;
let results: Record<string, unknown>;
const ok = (data: unknown) => ({ data, error: null, status: 200 });
async function start() {
  const { useSession } = await import("./use-session");
  read = useSession;
  read();
  mock.subscribe!(() => undefined);
  await vi.advanceTimersByTimeAsync(0);
  return useSession;
}
beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  vi.clearAllMocks();
  vi.stubGlobal("window", {
    localStorage: { getItem: () => null, setItem: vi.fn(), removeItem: vi.fn() },
  });
  vi.spyOn(console, "info").mockImplementation(() => undefined);
  results = {
    user_roles: ok([{ role: "pharmacy" }]),
    businesses: ok([business]),
    business_staff: ok([]),
  };
  mock.getSession.mockResolvedValue({ data: { session }, error: null });
  mock.refreshSession.mockResolvedValue({ data: { session }, error: null });
  mock.onAuthStateChange.mockImplementation((callback) => {
    mock.listener = callback;
    return { data: { subscription: { unsubscribe: vi.fn() } } };
  });
  mock.from.mockImplementation((table: string) => {
    const query = {
      select: () => query,
      eq: () => query,
      order: () => query,
      then: (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
        Promise.resolve(results[table]).then(resolve, reject),
    };
    return query;
  });
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
describe("session lifecycle", () => {
  it.each(["owner", "manager", "cashier", "accountant"])(
    "restores %s without duplicate listeners",
    async (role) => {
      results.business_staff = ok([{ role, business }]);
      await start();
      read();
      mock.subscribe!(() => undefined);
      expect(read().authStatus).toBe("authenticated");
      expect(read().business?.staff_role).toBe(role);
      expect(mock.onAuthStateChange).toHaveBeenCalledTimes(1);
      expect(mock.signOut).not.toHaveBeenCalled();
    },
  );
  it.each([
    { code: "PGRST301", status: 401 },
    { code: "42501", status: 403 },
    { code: "network_error", status: 0 },
  ])("keeps authentication on query failure %j", async (error) => {
    results.user_roles = { data: null, error, status: error.status };
    const use = await start();
    expect(read()).toMatchObject({
      authStatus: "authenticated",
      authorizationStatus: "recoverable-error",
      loadError: true,
    });
    expect(mock.signOut).not.toHaveBeenCalled();
    expect(mock.refreshSession).not.toHaveBeenCalled();
    results.user_roles = ok([{ role: "pharmacy" }]);
    await use().refresh();
    expect(read().loadError).toBe(false);
  });
  it.each(["businesses", "business_staff"])(
    "treats a %s lookup failure as recoverable",
    async (table) => {
      results[table] = { data: null, error: { code: "42501" }, status: 403 };
      await start();
      expect(read()).toMatchObject({ authStatus: "authenticated", loadError: true });
      expect(mock.signOut).not.toHaveBeenCalled();
    },
  );
  it("keeps a login with no organization authenticated for onboarding", async () => {
    results.businesses = ok([]);
    results.user_roles = ok([]);
    await start();
    expect(read()).toMatchObject({
      authStatus: "authenticated",
      authorizationStatus: "unauthorized",
      loadError: false,
      business: null,
    });
  });
  it("refreshes a healthy dashboard without rotating its token", async () => {
    const use = await start();
    await use().refresh();
    expect(read().business?.id).toBe("business");
    expect(mock.refreshSession).not.toHaveBeenCalled();
  });
  it("preserves an expired session on a temporary refresh failure", async () => {
    mock.getSession.mockResolvedValue({
      data: { session: { ...session, expires_at: 1 } },
      error: null,
    });
    mock.refreshSession.mockResolvedValue({
      data: { session: null },
      error: { code: "network_error", status: 0 },
    });
    await start();
    expect(read().loadError).toBe(true);
    expect(read().authStatus).toBe("authenticated");
    expect(mock.signOut).not.toHaveBeenCalled();
  });
  it("slow lookup completes; a stalled lookup becomes retryable, never logout", async () => {
    results.businesses = new Promise((resolve) => setTimeout(() => resolve(ok([business])), 5000));
    await start();
    expect(read().loading).toBe(true);
    await vi.advanceTimersByTimeAsync(5000);
    expect(read().business?.id).toBe("business");
    results.businesses = new Promise(() => undefined);
    const { useSession } = await import("./use-session");
    const retry = useSession().refresh();
    await vi.advanceTimersByTimeAsync(20001);
    await retry;
    expect(read()).toMatchObject({ loading: false, loadError: true, authStatus: "authenticated" });
    expect(mock.signOut).not.toHaveBeenCalled();
  });
  it("invalidates delayed hydration on SDK sign-out", async () => {
    let finish!: (value: unknown) => void;
    results.businesses = new Promise((resolve) => {
      finish = resolve;
    });
    await start();
    mock.listener!("SIGNED_OUT", null);
    finish(ok([business]));
    await vi.advanceTimersByTimeAsync(0);
    expect(read().user).toBeNull();
    expect(read().business).toBeNull();
  });
  it("does not let restoration overwrite a newer signed-in account", async () => {
    let finish!: (value: unknown) => void;
    mock.getSession.mockReturnValue(
      new Promise((resolve) => {
        finish = resolve;
      }),
    );
    await start();
    mock.listener!("SIGNED_IN", { ...session, user: { id: "new-owner" } });
    await vi.advanceTimersByTimeAsync(0);
    finish({ data: { session: null }, error: null });
    await vi.advanceTimersByTimeAsync(0);
    expect(read().user?.id).toBe("new-owner");
  });
  it.each(["pending", "rejected"])(
    "keeps %s approval separate from authentication",
    async (status) => {
      results.businesses = ok([{ ...business, verification_status: status }]);
      await start();
      expect(read()).toMatchObject({
        authStatus: "authenticated",
        authorizationStatus: "unauthorized",
      });
      expect(mock.signOut).not.toHaveBeenCalled();
    },
  );
  it("handles storage restrictions and a wholesaler account", async () => {
    window.localStorage.getItem = () => {
      throw new Error("storage blocked");
    };
    results.businesses = ok([{ ...business, type: "wholesaler" }]);
    await start();
    expect(read().business?.type).toBe("wholesaler");
    expect(JSON.stringify(vi.mocked(console.info).mock.calls)).not.toMatch(
      /SECRET_TOKEN|Private name|access_token/,
    );
  });
  it("redacts raw error messages, headers and credentials from diagnostics", async () => {
    results.businesses = {
      data: null,
      status: 403,
      error: {
        code: "42501",
        message: "SECRET_TOKEN private@example.com",
        details: "password=secret",
        headers: { Authorization: "Bearer SECRET_TOKEN" },
      },
    };
    await start();
    const logs = JSON.stringify(vi.mocked(console.info).mock.calls);
    expect(logs).toContain("42501");
    expect(logs).toContain("403");
    expect(logs).not.toMatch(/SECRET_TOKEN|private@example|password=|Authorization/);
  });
  it("has a recoverable restoration error rather than a login redirect", async () => {
    mock.getSession.mockRejectedValue({ code: "network_error" });
    await start();
    expect(read()).toMatchObject({
      authStatus: "recoverable-error",
      loadError: true,
      loading: false,
    });
  });
});
