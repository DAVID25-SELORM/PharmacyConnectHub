import { inviteBusinessStaff } from "../_lib/staff.js";

function getFallbackOrigin(req) {
  const host = req.headers["x-forwarded-host"] || req.headers.host;
  const proto = req.headers["x-forwarded-proto"] || "https";

  if (!host) {
    return undefined;
  }

  return `${proto}://${host}`;
}

function getAccessToken(req) {
  const authHeader = req.headers.authorization;

  if (!authHeader?.startsWith("Bearer ")) {
    return "";
  }

  return authHeader.slice("Bearer ".length).trim();
}

function sendError(res, error) {
  const message = error instanceof Error ? error.message : "Unexpected error.";
  const status =
    message === "Your session expired. Please sign in again."
      ? 401
      : message === "Only the business owner can add staff."
        ? 403
        : 400;

  res.status(status).json({ error: message });
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    res.status(405).json({ error: "Method not allowed." });
    return;
  }

  try {
    const result = await inviteBusinessStaff(
      {
        accessToken: getAccessToken(req),
        businessId: req.body?.businessId,
        email: req.body?.email,
        role: req.body?.role,
        origin: req.body?.origin,
      },
      getFallbackOrigin(req),
    );

    res.status(200).json(result);
  } catch (error) {
    sendError(res, error);
  }
}
