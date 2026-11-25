import { canViewAccounting } from "@/lib/accounting";

/**
 * The one navigation model behind the phone bottom bar, the tablet rail and the computer sidebar.
 * It lists the same screens the old tab strips and header links reached, with the same
 * permission rules, so a person sees exactly the destinations they could reach before.
 */

export type NavIcon =
  | "dashboard"
  | "orders"
  | "products"
  | "customers"
  | "discounts"
  | "insights"
  | "batches"
  | "returns"
  | "credit"
  | "payments"
  | "accounting"
  | "rfqs"
  | "reports"
  | "contacts"
  | "audit"
  | "team"
  | "settings"
  | "security"
  | "privacy"
  | "admin"
  | "catalog"
  | "lists"
  | "procurement"
  | "inventory"
  | "statements"
  | "billing"
  | "verification"
  | "activity";

export type NavItem = {
  id: string;
  label: string;
  /** Short label for the phone bottom bar. */
  short?: string;
  icon: NavIcon;
  to: string;
  /** Set for a screen that is a tab of a workspace page, reached with ?tab=. */
  tab?: string;
};

export type NavGroup = { id: string; label: string; items: NavItem[] };

export type NavContext = {
  kind: "wholesaler" | "pharmacy" | "admin";
  staffRole?: string;
  isPlatformAdmin: boolean;
  /** Admin area users who also have a business get a way back to it. */
  hasWorkspace?: boolean;
};

/** The tab a workspace page opens on when the address has no valid ?tab=. */
export const DEFAULT_TAB = { wholesaler: "orders", pharmacy: "catalog" } as const;

export const WHOLESALER_TABS = [
  "orders",
  "products",
  "insights",
  "batches",
  "returns",
  "customers",
  "discounts",
  "credit",
  "online-payments",
] as const;

export const PHARMACY_TABS = [
  "catalog",
  "lists",
  "orders",
  "returns",
  "statements",
  "credit",
  "billing",
] as const;

function present<T>(items: Array<T | false | null | undefined>): T[] {
  return items.filter((item): item is T => Boolean(item));
}

function group(id: string, label: string, items: NavItem[]): NavGroup | null {
  return items.length > 0 ? { id, label, items } : null;
}

function wholesalerGroups(ctx: NavContext): NavGroup[] {
  const role = ctx.staffRole;
  // Same rules as the wholesaler page's own tabs.
  const canManageProducts = role === "owner" || role === "manager";
  const canProcessOrders = role !== "assistant";
  const canUpdateStatus = role !== "assistant" && role !== "finance";
  const canRecordCredit =
    role === "owner" || role === "manager" || role === "finance" || role === "accountant";
  const canSeeAccounting = canViewAccounting("wholesaler", role);
  const canSeeAudit = role === "owner" || role === "manager" || role === "accountant";

  const ws = "/wholesaler";
  return present([
    group("overview", "Overview", [
      { id: "dashboard", label: "Dashboard", icon: "dashboard", to: "/dashboard" },
    ]),
    group(
      "sell",
      "Sell",
      present<NavItem>([
        {
          id: "orders",
          label: "Incoming orders",
          short: "Orders",
          icon: "orders",
          to: ws,
          tab: "orders",
        },
        {
          id: "products",
          label: "My products",
          short: "Products",
          icon: "products",
          to: ws,
          tab: "products",
        },
        canProcessOrders && {
          id: "customers",
          label: "Customers",
          icon: "customers",
          to: ws,
          tab: "customers",
        },
        canManageProducts && {
          id: "discounts",
          label: "Customer discounts",
          short: "Discounts",
          icon: "discounts",
          to: ws,
          tab: "discounts",
        },
      ]),
    ),
    group(
      "stock",
      "Stock",
      present<NavItem>([
        canManageProducts && {
          id: "insights",
          label: "Stock insights",
          short: "Insights",
          icon: "insights",
          to: ws,
          tab: "insights",
        },
        canUpdateStatus && {
          id: "batches",
          label: "Batches",
          icon: "batches",
          to: ws,
          tab: "batches",
        },
        canProcessOrders && {
          id: "returns",
          label: "Returns",
          icon: "returns",
          to: ws,
          tab: "returns",
        },
      ]),
    ),
    group(
      "money",
      "Money",
      present<NavItem>([
        canRecordCredit && {
          id: "credit",
          label: "Credit",
          icon: "credit",
          to: ws,
          tab: "credit",
        },
        canRecordCredit && {
          id: "online-payments",
          label: "Online payments",
          short: "Payments",
          icon: "payments",
          to: ws,
          tab: "online-payments",
        },
        canSeeAccounting && {
          id: "accounting",
          label: "Accounting",
          icon: "accounting",
          to: "/wholesaler/accounting",
        },
      ]),
    ),
    group(
      "work",
      "Work",
      present<NavItem>([
        { id: "rfqs", label: "RFQs", icon: "rfqs", to: "/wholesaler/rfqs" },
        { id: "reports", label: "Reports", icon: "reports", to: "/wholesaler/reports" },
        canManageProducts && {
          id: "contacts",
          label: "Contacts / CRM",
          short: "Contacts",
          icon: "contacts",
          to: "/wholesaler/contacts",
        },
        canSeeAudit && { id: "audit", label: "Audit log", icon: "audit", to: "/wholesaler/audit" },
      ]),
    ),
    group("account", "Account", accountItems(ctx)),
  ]);
}

function pharmacyGroups(ctx: NavContext): NavGroup[] {
  const role = ctx.staffRole;
  const canSeeAccounting = canViewAccounting("pharmacy", role);
  const canSeeBilling =
    role === "owner" || role === "manager" || role === "finance" || role === "accountant";
  const canSeeAudit = role === "owner" || role === "manager" || role === "accountant";
  const canSeeContacts = role === "owner" || role === "manager";

  const ws = "/pharmacy";
  return present([
    group("overview", "Overview", [
      { id: "dashboard", label: "Dashboard", icon: "dashboard", to: "/dashboard" },
    ]),
    group("buy", "Buy", [
      {
        id: "catalog",
        label: "Browse catalogue",
        short: "Browse",
        icon: "catalog",
        to: ws,
        tab: "catalog",
      },
      {
        id: "lists",
        label: "Reorder lists",
        short: "Lists",
        icon: "lists",
        to: ws,
        tab: "lists",
      },
      { id: "orders", label: "My orders", short: "Orders", icon: "orders", to: ws, tab: "orders" },
      { id: "rfqs", label: "RFQs", icon: "rfqs", to: "/pharmacy/rfqs" },
      {
        id: "procurement",
        label: "External purchases",
        short: "Purchases",
        icon: "procurement",
        to: "/pharmacy/procurement",
      },
    ]),
    group("stock", "Stock", [
      { id: "inventory", label: "Inventory", icon: "inventory", to: "/pharmacy/inventory" },
      { id: "returns", label: "Returns", icon: "returns", to: ws, tab: "returns" },
    ]),
    group(
      "money",
      "Money",
      present<NavItem>([
        { id: "statements", label: "Statements", icon: "statements", to: ws, tab: "statements" },
        canSeeAccounting && {
          id: "credit",
          label: "Credit",
          icon: "credit",
          to: ws,
          tab: "credit",
        },
        canSeeBilling && {
          id: "billing",
          label: "Billing",
          icon: "billing",
          to: ws,
          tab: "billing",
        },
        canSeeAccounting && {
          id: "accounting",
          label: "Accounting",
          icon: "accounting",
          to: "/pharmacy/accounting",
        },
      ]),
    ),
    group(
      "work",
      "Work",
      present<NavItem>([
        { id: "reports", label: "Reports", icon: "reports", to: "/pharmacy/reports" },
        canSeeContacts && {
          id: "contacts",
          label: "Contacts / CRM",
          short: "Contacts",
          icon: "contacts",
          to: "/pharmacy/contacts",
        },
        canSeeAudit && { id: "audit", label: "Audit log", icon: "audit", to: "/pharmacy/audit" },
      ]),
    ),
    group("account", "Account", accountItems(ctx)),
  ]);
}

function adminGroups(ctx: NavContext): NavGroup[] {
  return present([
    group("review", "Review", [
      { id: "admin", label: "Businesses", icon: "admin", to: "/admin" },
      {
        id: "verification",
        label: "Verification queue",
        short: "Verification",
        icon: "verification",
        to: "/admin/verification",
      },
    ]),
    group("platform", "Platform", [
      { id: "activity", label: "Activity", icon: "activity", to: "/admin/activity" },
      { id: "payments", label: "Payments", icon: "payments", to: "/admin/payments" },
      { id: "billing", label: "Billing", icon: "billing", to: "/admin/billing" },
      { id: "reports", label: "Reports", icon: "reports", to: "/admin/reports" },
      { id: "team", label: "Platform team", short: "Team", icon: "team", to: "/admin/staff" },
      {
        id: "privacy",
        label: "Privacy requests",
        short: "Privacy",
        icon: "privacy",
        to: "/admin/privacy",
      },
    ]),
    group("account", "Account", [
      { id: "security", label: "Security", icon: "security", to: "/security" },
    ]),
    ctx.hasWorkspace
      ? group("workspace", "My workspace", [
          { id: "dashboard", label: "Dashboard", icon: "dashboard", to: "/dashboard" },
        ])
      : null,
  ]);
}

/** Team and settings for every workspace, plus the admin console for platform admins. */
function accountItems(ctx: NavContext): NavItem[] {
  return present<NavItem>([
    { id: "team", label: "Team", icon: "team", to: "/staff" },
    { id: "settings", label: "Settings", icon: "settings", to: "/settings" },
    { id: "security", label: "Security", icon: "security", to: "/security" },
    ctx.isPlatformAdmin && { id: "admin", label: "Admin console", icon: "admin", to: "/admin" },
  ]);
}

export function buildNavGroups(ctx: NavContext): NavGroup[] {
  if (ctx.kind === "admin") return adminGroups(ctx);
  return ctx.kind === "wholesaler" ? wholesalerGroups(ctx) : pharmacyGroups(ctx);
}

/** The four screens on the phone bottom bar; everything else is under More. */
const BOTTOM_PREFERENCE: Record<NavContext["kind"], string[]> = {
  wholesaler: ["dashboard", "orders", "products", "customers", "credit"],
  pharmacy: ["catalog", "orders", "inventory", "rfqs", "dashboard"],
  admin: ["admin", "verification", "activity", "payments"],
};

export function bottomBarItems(groups: NavGroup[], kind: NavContext["kind"]): NavItem[] {
  const all = groups.flatMap((g) => g.items);
  const picked: NavItem[] = [];
  for (const id of BOTTOM_PREFERENCE[kind]) {
    const item = all.find((candidate) => candidate.id === id);
    if (item && !picked.includes(item)) picked.push(item);
    if (picked.length === 4) break;
  }
  return picked;
}

function normalisePath(path: string) {
  return path.length > 1 ? path.replace(/\/+$/, "") : path;
}

/** The screen the person is on, from the address. Tab screens are told apart by ?tab=. */
export function findActiveItem(
  groups: NavGroup[],
  pathname: string,
  search: string,
  kind: NavContext["kind"],
): NavItem | null {
  const path = normalisePath(pathname);
  const params = new URLSearchParams(search);
  const all = groups.flatMap((g) => g.items);
  const onPage = all.filter((item) => normalisePath(item.to) === path);
  if (onPage.length === 0) return null;

  const tabbed = onPage.filter((item) => item.tab);
  if (tabbed.length > 0) {
    const defaultTab = kind === "pharmacy" ? DEFAULT_TAB.pharmacy : DEFAULT_TAB.wholesaler;
    const requested = params.get("tab");
    const wanted = tabbed.some((item) => item.tab === requested) ? requested : defaultTab;
    return tabbed.find((item) => item.tab === wanted) ?? tabbed[0];
  }
  return onPage[0];
}

/** The address for a screen, for the link's href. */
export function navHref(item: NavItem): string {
  return item.tab ? `${item.to}?tab=${encodeURIComponent(item.tab)}` : item.to;
}

/** Which of the three navigation sets to show for the page the person is on. */
export function navKindFor(pathname: string, businessType: "pharmacy" | "wholesaler" | undefined) {
  if (pathname === "/admin" || pathname.startsWith("/admin/")) return "admin" as const;
  if (businessType === "wholesaler") return "wholesaler" as const;
  if (businessType === "pharmacy") return "pharmacy" as const;
  return null;
}

/** The tab to open for a ?tab= value; anything unknown opens the page's first tab. */
export function validWorkspaceTab(kind: "wholesaler" | "pharmacy", value: string | null): string {
  const tabs: readonly string[] = kind === "wholesaler" ? WHOLESALER_TABS : PHARMACY_TABS;
  return value !== null && tabs.includes(value) ? value : DEFAULT_TAB[kind];
}
