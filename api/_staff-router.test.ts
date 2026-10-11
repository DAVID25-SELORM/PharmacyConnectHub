import { describe, expect, it, vi } from "vitest";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createStaffRouter } from "./_staff-router";

describe("consolidated staff endpoints", () => {
  for (const prefix of ["staff", "platform-staff"] as const) {
    it.each(["invite", "resend-invite", "update"])(
      `${prefix} preserves %s handler and request`,
      (action) => {
        const handler = vi.fn();
        const req = {
          url: `/api/${prefix}/${action}?action=update`,
          body: { role: "manager" },
          headers: { authorization: "Bearer test" },
        } as VercelRequest;
        const res = {} as VercelResponse;
        createStaffRouter(prefix, { [action]: handler })(req, res);
        expect(handler).toHaveBeenCalledExactlyOnceWith(req, res);
      },
    );
    it.each(["unknown", "constructor", "invite/extra", ""])(
      `${prefix} rejects unsupported path %s`,
      (action) => {
        const handler = vi.fn();
        const json = vi.fn();
        const status = vi.fn(() => ({ json }));
        createStaffRouter(prefix, { invite: handler })(
          { url: `/api/${prefix}/${action}` } as VercelRequest,
          { status } as unknown as VercelResponse,
        );
        expect(status).toHaveBeenCalledWith(404);
        expect(handler).not.toHaveBeenCalled();
      },
    );
  }
});
