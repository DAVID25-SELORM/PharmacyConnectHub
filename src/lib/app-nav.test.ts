import { describe, expect, it } from "vitest";
import {
  bottomBarItems,
  buildNavGroups,
  findActiveItem,
  navHref,
  navKindFor,
  validWorkspaceTab,
  type NavContext,
} from "@/lib/app-nav";

const ids = (ctx: NavContext) =>
  buildNavGroups(ctx)
    .flatMap((group) => group.items)
    .map((item) => item.id);

const wholesaler = (staffRole: string, isPlatformAdmin = false): NavContext => ({
  kind: "wholesaler",
  staffRole,
  isPlatformAdmin,
});
const pharmacy = (staffRole: string): NavContext => ({
  kind: "pharmacy",
  staffRole,
  isPlatformAdmin: false,
});

describe("wholesaler navigation follows the same permissions as the old tabs", () => {
  it("shows everything to an owner", () => {
    expect(ids(wholesaler("owner"))).toEqual(
      expect.arrayContaining([
        "orders",
        "products",
        "customers",
        "discounts",
        "insights",
        "batches",
        "returns",
        "credit",
        "online-payments",
        "accounting",
        "rfqs",
        "reports",
        "contacts",
        "audit",
        "team",
        "settings",
      ]),
    );
  });

  it("hides management tabs from a cashier", () => {
    const shown = ids(wholesaler("cashier"));
    expect(shown).toEqual(expect.arrayContaining(["orders", "products", "customers", "returns"]));
    expect(shown).not.toContain("insights");
    expect(shown).not.toContain("discounts");
    expect(shown).not.toContain("credit");
    expect(shown).not.toContain("contacts");
  });

  it("gives finance credit and payments but no batches", () => {
    const shown = ids(wholesaler("finance"));
    expect(shown).toEqual(expect.arrayContaining(["credit", "online-payments"]));
    expect(shown).not.toContain("batches");
  });

  it("gives an assistant only the basics", () => {
    const shown = ids(wholesaler("assistant"));
    expect(shown).toEqual(expect.arrayContaining(["orders", "products"]));
    for (const hidden of ["customers", "returns", "batches", "credit", "insights"]) {
      expect(shown).not.toContain(hidden);
    }
  });

  it("adds the admin console only for platform admins", () => {
    expect(ids(wholesaler("owner", true))).toContain("admin");
    expect(ids(wholesaler("owner", false))).not.toContain("admin");
  });
});

describe("pharmacy navigation", () => {
  it("keeps the buying screens and hospitals use them too", () => {
    expect(ids(pharmacy("cashier"))).toEqual(
      expect.arrayContaining([
        "catalog",
        "lists",
        "orders",
        "rfqs",
        "procurement",
        "inventory",
        "returns",
        "statements",
        "reports",
        "team",
        "settings",
      ]),
    );
  });

  it("limits credit, billing, contacts and audit to the roles that had them", () => {
    const cashier = ids(pharmacy("cashier"));
    for (const hidden of ["credit", "billing", "contacts", "audit", "accounting"]) {
      expect(cashier).not.toContain(hidden);
    }
    const owner = ids(pharmacy("owner"));
    for (const shown of ["credit", "billing", "contacts", "audit", "accounting"]) {
      expect(owner).toContain(shown);
    }
  });
});

describe("admin navigation", () => {
  it("lists the platform screens and offers the workspace only when there is one", () => {
    const withWorkspace = buildNavGroups({
      kind: "admin",
      isPlatformAdmin: true,
      hasWorkspace: true,
    });
    const all = withWorkspace.flatMap((group) => group.items.map((item) => item.to));
    expect(all).toEqual(
      expect.arrayContaining([
        "/admin",
        "/admin/verification",
        "/admin/activity",
        "/admin/payments",
        "/admin/billing",
        "/admin/reports",
        "/admin/staff",
        "/admin/privacy",
        "/security",
        "/dashboard",
      ]),
    );
    expect(
      buildNavGroups({ kind: "admin", isPlatformAdmin: true })
        .flatMap((group) => group.items)
        .map((item) => item.to),
    ).not.toContain("/dashboard");
  });
});

describe("account security stays reachable", () => {
  // The header's Security link is hidden when this navigation shows, so every set must carry it:
  // it is where two-step verification is set up.
  it("is in every navigation set, for every role", () => {
    for (const role of ["owner", "manager", "cashier", "assistant", "finance", "accountant"]) {
      expect(ids(wholesaler(role))).toContain("security");
      expect(ids(pharmacy(role))).toContain("security");
    }
    expect(ids({ kind: "admin", isPlatformAdmin: true })).toContain("security");
  });
});

describe("finding the screen the person is on", () => {
  const groups = buildNavGroups(wholesaler("owner"));
  const pharmacyGroups = buildNavGroups(pharmacy("owner"));

  it("opens on the page's first tab when the address has none", () => {
    expect(findActiveItem(groups, "/wholesaler", "", "wholesaler")?.id).toBe("orders");
    expect(findActiveItem(pharmacyGroups, "/pharmacy", "", "pharmacy")?.id).toBe("catalog");
  });

  it("follows ?tab= and ignores unknown tabs", () => {
    expect(findActiveItem(groups, "/wholesaler", "?tab=products", "wholesaler")?.id).toBe(
      "products",
    );
    expect(findActiveItem(groups, "/wholesaler", "?tab=online-payments", "wholesaler")?.id).toBe(
      "online-payments",
    );
    expect(findActiveItem(groups, "/wholesaler", "?tab=nonsense", "wholesaler")?.id).toBe("orders");
    expect(findActiveItem(pharmacyGroups, "/pharmacy", "?tab=credit", "pharmacy")?.id).toBe(
      "credit",
    );
  });

  it("matches separate pages and ignores a trailing slash", () => {
    expect(findActiveItem(groups, "/wholesaler/rfqs", "", "wholesaler")?.id).toBe("rfqs");
    expect(findActiveItem(groups, "/wholesaler/reports/", "", "wholesaler")?.id).toBe("reports");
    expect(findActiveItem(groups, "/dashboard", "", "wholesaler")?.id).toBe("dashboard");
  });

  it("finds nothing on a page that is not in the navigation", () => {
    expect(findActiveItem(groups, "/notifications", "", "wholesaler")).toBeNull();
  });
});

describe("phone bottom bar", () => {
  it("picks four screens in order of use", () => {
    expect(
      bottomBarItems(buildNavGroups(wholesaler("owner")), "wholesaler").map((item) => item.id),
    ).toEqual(["dashboard", "orders", "products", "customers"]);
    expect(
      bottomBarItems(buildNavGroups(pharmacy("owner")), "pharmacy").map((item) => item.id),
    ).toEqual(["catalog", "orders", "inventory", "rfqs"]);
  });

  it("skips screens the person may not see", () => {
    const items = bottomBarItems(buildNavGroups(wholesaler("assistant")), "wholesaler");
    expect(items.map((item) => item.id)).not.toContain("customers");
    expect(items.length).toBeLessThanOrEqual(4);
  });
});

describe("addresses and kinds", () => {
  it("builds the link for a tab screen and for a page screen", () => {
    const all = buildNavGroups(wholesaler("owner")).flatMap((group) => group.items);
    expect(navHref(all.find((item) => item.id === "orders")!)).toBe("/wholesaler?tab=orders");
    expect(navHref(all.find((item) => item.id === "rfqs")!)).toBe("/wholesaler/rfqs");
  });

  it("validates workspace tabs", () => {
    expect(validWorkspaceTab("wholesaler", "online-payments")).toBe("online-payments");
    expect(validWorkspaceTab("wholesaler", "catalog")).toBe("orders");
    expect(validWorkspaceTab("pharmacy", null)).toBe("catalog");
    expect(validWorkspaceTab("pharmacy", "billing")).toBe("billing");
  });

  it("chooses the navigation set from the page and the business", () => {
    expect(navKindFor("/admin/activity", "wholesaler")).toBe("admin");
    expect(navKindFor("/admin", undefined)).toBe("admin");
    expect(navKindFor("/wholesaler", "wholesaler")).toBe("wholesaler");
    expect(navKindFor("/pharmacy/inventory", "pharmacy")).toBe("pharmacy");
    expect(navKindFor("/dashboard", undefined)).toBeNull();
  });

  it("keeps a menu on the Security page, including for an admin with no business", () => {
    expect(navKindFor("/security", "pharmacy")).toBe("pharmacy");
    expect(navKindFor("/security", "wholesaler", true)).toBe("wholesaler");
    expect(navKindFor("/security", undefined, true)).toBe("admin");
    expect(navKindFor("/security", undefined, false)).toBeNull();
    expect(navKindFor("/dashboard", undefined, true)).toBeNull();
    const groups = buildNavGroups({ kind: "admin", isPlatformAdmin: true });
    expect(findActiveItem(groups, "/security", "", "admin")?.id).toBe("security");
  });
});
