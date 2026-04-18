declare module "./api/staff/invite.js" {
  import type { IncomingMessage, ServerResponse } from "node:http";

  const handler: (
    req: IncomingMessage & { body?: unknown },
    res: ServerResponse,
  ) => Promise<void> | void;

  export default handler;
}

declare module "./api/staff/joined.js" {
  import type { IncomingMessage, ServerResponse } from "node:http";

  const handler: (
    req: IncomingMessage & { body?: unknown },
    res: ServerResponse,
  ) => Promise<void> | void;

  export default handler;
}
