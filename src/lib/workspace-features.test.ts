import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  PHARMACY_TABS,
  WHOLESALER_TABS,
  buildNavGroups,
  validWorkspaceTab,
  type NavContext,
} from "./app-nav";

// A commit about something else once removed the wholesaler Billing tab, the expired-units note
// and the supplier identity on bulk printing from the wholesaler page, and nothing failed.
// These read the page source so that losing any of them fails here.

const page = (file: string) => readFileSync(resolve(process.cwd(), "src/routes", file), "utf8");

const WORKSPACES = [
  { kind: "wholesaler", file: "wholesaler.tsx", tabs: WHOLESALER_TABS },
  { kind: "pharmacy", file: "pharmacy.tsx", tabs: PHARMACY_TABS },
] as const;

const BILLING_ROLES = ["owner", "manager", "finance", "accountant"];
const OTHER_ROLES = ["cashier", "warehouse", "assistant"];

const billingItem = (kind: "wholesaler" | "pharmacy", staffRole: string) => {
  const context: NavContext = { kind, staffRole, isPlatformAdmin: false };
  return buildNavGroups(context)
    .flatMap((group) => group.items)
    .find((item) => item.id === "billing");
};

describe.each(WORKSPACES)("$kind Billing screen", ({ kind, file, tabs }) => {
  it("renders the billing panel in a billing tab", () => {
    expect(page(file)).toMatch(
      /<TabsContent value="billing">\s*<BillingPanel businessId=\{business\.id\} \/>/,
    );
  });

  // Billing notices link to /<kind>?tab=billing.
  it("opens Billing from a ?tab=billing link", () => {
    expect(validWorkspaceTab(kind, "billing")).toBe("billing");
  });

  it.each(BILLING_ROLES)("has a Billing menu entry for the %s", (role) => {
    expect(billingItem(kind, role)).toMatchObject({ to: `/${kind}`, tab: "billing" });
  });

  it.each(OTHER_ROLES)("has no Billing menu entry for the %s", (role) => {
    expect(billingItem(kind, role)).toBeUndefined();
  });

  it("has content on the page for every tab the address can open", () => {
    const source = page(file);
    const missing = tabs.filter((tab) => !source.includes(`<TabsContent value="${tab}"`));
    expect(missing).toEqual([]);
  });
});

describe("wholesaler page features", () => {
  const source = page("wholesaler.tsx");

  it("shows how many units in stock are past their expiry date", () => {
    expect(source).toContain('.select("*, expired_stock" as "*")');
    expect(source).toContain("expiredNote(p.stock, p.expired_stock)");
  });

  it("puts the supplier's saved identity on bulk-printed pick and pack slips", () => {
    expect(source).toContain("loadDocumentIdentity(wholesaler.id)");
    expect(source).toContain("wholesaler: bulkIssuer");
  });
});
