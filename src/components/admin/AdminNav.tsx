import { Link, useRouterState } from "@tanstack/react-router";
import { Activity, BarChart3, ClipboardCheck, LayoutDashboard, ShieldCheck } from "lucide-react";

const ITEMS = [
  { to: "/admin", label: "Dashboard", icon: LayoutDashboard, exact: true },
  { to: "/admin/verification", label: "Verification", icon: ClipboardCheck, exact: false },
  { to: "/admin/activity", label: "Activity", icon: Activity, exact: false },
  { to: "/admin/reports", label: "Reports", icon: BarChart3, exact: false },
  { to: "/admin/staff", label: "Platform Team", icon: ShieldCheck, exact: false },
] as const;

/** Single admin navigation shared by the dashboard, activity log and platform team pages. */
export function AdminNav() {
  const pathname = useRouterState({ select: (state) => state.location.pathname });

  return (
    <nav aria-label="Admin sections" className="border-b border-border bg-background">
      <div className="mx-auto flex max-w-7xl gap-1 overflow-x-auto px-4 sm:px-6 lg:px-8">
        {ITEMS.map((item) => {
          const active = item.exact ? pathname === item.to : pathname.startsWith(item.to);
          const Icon = item.icon;
          return (
            <Link
              key={item.to}
              to={item.to}
              activeOptions={{ exact: item.exact }}
              aria-current={active ? "page" : undefined}
              className={`inline-flex items-center gap-2 whitespace-nowrap border-b-2 px-3 py-3 text-sm font-medium transition-colors ${
                active
                  ? "border-primary text-foreground"
                  : "border-transparent text-muted-foreground hover:text-foreground"
              }`}
            >
              <Icon className="h-4 w-4" aria-hidden="true" />
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
