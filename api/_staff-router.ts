import type { VercelRequest, VercelResponse } from "@vercel/node";

type Handler = (req: VercelRequest, res: VercelResponse) => unknown;
export function createStaffRouter(
  prefix: "staff" | "platform-staff",
  handlers: Record<string, Handler>,
) {
  return (req: VercelRequest, res: VercelResponse) => {
    const pathname = new URL(req.url ?? "/", "https://internal.invalid").pathname;
    const action = pathname.startsWith(`/api/${prefix}/`)
      ? pathname.slice(`/api/${prefix}/`.length)
      : "";
    if (!Object.prototype.hasOwnProperty.call(handlers, action)) {
      return res.status(404).json({ error: "Unknown staff endpoint." });
    }
    return handlers[action](req, res);
  };
}
