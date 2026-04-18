import { listBusinessStaff } from "../_lib/staff.js";

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
      : message === "Not authorized to view this team."
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
    const staff = await listBusinessStaff({
      accessToken: getAccessToken(req),
      businessId: req.body?.businessId,
    });

    res.status(200).json({ staff });
  } catch (error) {
    sendError(res, error);
  }
}
