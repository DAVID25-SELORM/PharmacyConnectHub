// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { toast, type Action } from "sonner";
import { installChunkRecovery, MODULE_LOAD_MESSAGE } from "./chunk-recovery";

vi.mock("sonner", () => ({ toast: { error: vi.fn() } }));

describe("module loading recovery", () => {
  let cleanup: (() => void) | undefined;
  afterEach(() => { cleanup?.(); vi.clearAllMocks(); });

  it("offers an in-app refresh without discarding work automatically", () => {
    const reload = vi.fn();
    cleanup = installChunkRecovery(window, reload);
    const error = new TypeError("Failed to fetch dynamically imported module");
    const event = new Event("vite:preloadError", { cancelable: true });
    Object.assign(event, { payload: error });
    window.dispatchEvent(event);
    expect(error.message).toBe(MODULE_LOAD_MESSAGE);
    expect(event.defaultPrevented).toBe(false);
    expect(reload).not.toHaveBeenCalled();
    const options = vi.mocked(toast.error).mock.calls[0][1];
    expect(options?.id).toBe("module-load-recovery");
    expect(options?.duration).toBe(Infinity);
    const action = options?.action as Action;
    action.onClick({} as Parameters<Action["onClick"]>[0]);
    expect(reload).toHaveBeenCalledOnce();
  });

  it("handles non-Error payloads and removes the listener on cleanup", () => {
    cleanup = installChunkRecovery(window, vi.fn());
    window.dispatchEvent(new Event("vite:preloadError"));
    expect(toast.error).toHaveBeenCalledOnce();
    cleanup();
    window.dispatchEvent(new Event("vite:preloadError"));
    expect(toast.error).toHaveBeenCalledOnce();
  });
});
