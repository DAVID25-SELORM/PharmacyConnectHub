import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildNavGroups } from "@/lib/app-nav";

/**
 * A page shows the menu only when its header asks for it with `showNav`. A menu destination that
 * forgets loses the sidebar and the phone bottom bar, which is how Security and Settings broke.
 * Each business menu destination is listed here with the file that renders its header.
 * (Admin pages always show the admin menu, so they need no flag.)
 */
const HEADER_FILE: Record<string, string> = {
  "/dashboard": "routes/dashboard.tsx",
  "/wholesaler": "routes/wholesaler.tsx",
  "/wholesaler/accounting": "components/accounting/AccountingPage.tsx",
  "/wholesaler/rfqs": "components/rfq/EnterpriseRfqWorkspace.tsx",
  "/wholesaler/reports": "routes/wholesaler_.reports.tsx",
  "/wholesaler/contacts": "components/crm/PharmacyCrm.tsx",
  "/wholesaler/audit": "components/audit/AuditCentrePage.tsx",
  "/pharmacy": "routes/pharmacy.tsx",
  "/pharmacy/rfqs": "components/rfq/EnterpriseRfqWorkspace.tsx",
  "/pharmacy/procurement": "components/procurement/ExternalProcurement.tsx",
  "/pharmacy/inventory": "routes/pharmacy_.inventory.tsx",
  "/pharmacy/accounting": "components/accounting/AccountingPage.tsx",
  "/pharmacy/reports": "routes/pharmacy_.reports.tsx",
  "/pharmacy/contacts": "components/crm/PharmacyCrm.tsx",
  "/pharmacy/audit": "components/audit/AuditCentrePage.tsx",
  "/staff": "routes/staff.tsx",
  "/settings": "routes/settings.tsx",
  "/security": "routes/security.tsx",
};

const destinations = [
  ...new Set(
    (["wholesaler", "pharmacy"] as const).flatMap((kind) =>
      buildNavGroups({ kind, staffRole: "owner", isPlatformAdmin: false }).flatMap((group) =>
        group.items.map((item) => item.to),
      ),
    ),
  ),
];

describe("every business menu destination keeps the menu", () => {
  it.each(destinations)("%s", (to) => {
    const file = HEADER_FILE[to];
    expect(file, `add ${to} to HEADER_FILE in this test`).toBeDefined();
    const source = readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
    // At least one header on the page turns the menu on ("showNav" or "showNav={...}", not false).
    expect(source).toMatch(/<DashboardHeader[^>]*?\sshowNav(?!=\{false\})/);
  });
});
