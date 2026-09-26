export type NotificationRow = {
  id: string;
  type: string;
  title: string;
  body: string;
  read: boolean;
  link: string | null;
  created_at: string;
};

export const NOTIFICATIONS_CHANGED_EVENT = "drugxone:notifications-changed";

export function announceNotificationsChanged() {
  if (typeof window !== "undefined") window.dispatchEvent(new Event(NOTIFICATIONS_CHANGED_EVENT));
}

export type NotificationGroup =
  | "orders"
  | "payments"
  | "returns"
  | "delivery"
  | "stock"
  | "account";

const GROUP_TYPES: Record<NotificationGroup, string[]> = {
  orders: ["new_order", "order_status"],
  payments: ["payment_update"],
  returns: ["return_requested", "return_update"],
  delivery: ["delivery_update"],
  stock: ["low_stock"],
  account: ["business_approved", "business_rejected", "verification_pending"],
};

export const NOTIFICATION_FILTERS: Array<{ value: string; label: string }> = [
  { value: "", label: "All" },
  { value: "unread", label: "Unread" },
  { value: "orders", label: "Orders" },
  { value: "payments", label: "Payments" },
  { value: "returns", label: "Returns" },
  { value: "delivery", label: "Delivery" },
  { value: "stock", label: "Stock" },
  { value: "account", label: "Account" },
];

export function typesForGroup(group: string): string[] | null {
  return (GROUP_TYPES as Record<string, string[]>)[group] ?? null;
}

export function groupOf(type: string): NotificationGroup | null {
  for (const [group, types] of Object.entries(GROUP_TYPES)) {
    if (types.includes(type)) return group as NotificationGroup;
  }
  return null;
}

/** Only same-site paths are ever followed, whatever a row in the database says. */
export function safeInternalLink(link: string | null | undefined): string | null {
  if (!link) return null;
  if (!link.startsWith("/") || link.startsWith("//") || link.includes("\\")) return null;
  return link;
}

export function timeAgoShort(iso: string, now = Date.now()) {
  const minutes = Math.floor((now - new Date(iso).getTime()) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

type Router = { history: { push: (href: string) => void } };

/** Opens an in-app link. A different tab of the page we are already on needs a real load. */
export function openInternalLink(router: Router, link: string | null | undefined) {
  const safe = safeInternalLink(link);
  if (!safe) return;
  const target = new URL(safe, window.location.origin);
  if (target.pathname === window.location.pathname) window.location.assign(safe);
  else router.history.push(safe);
}
