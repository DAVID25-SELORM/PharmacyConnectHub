import type { VercelRequest, VercelResponse } from "@vercel/node";
import { receiptHandler } from "../_receipt-delivery.js";
export default function handler(req: VercelRequest, res: VercelResponse) {
  return receiptHandler(req, res, true);
}
