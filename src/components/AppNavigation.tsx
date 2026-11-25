import { useEffect, useMemo, useState } from "react";
import { useNavigate, useRouterState } from "@tanstack/react-router";
import {
  Activity,
  BarChart3,
  Boxes,
  Building2,
  Calculator,
  ClipboardList,
  CreditCard,
  FileQuestion,
  FileText,
  Hospital,
  HelpCircle,
  LayoutDashboard,
  ListChecks,
  Lock,
  LogOut,
  MoreHorizontal,
  PackageSearch,
  PanelLeftClose,
  PanelLeftOpen,
  Pill,
  PlusCircle,
  ReceiptText,
  ScrollText,
  Settings,
  ShieldCheck,
  ShoppingCart,
  Store,
  Tag,
  TrendingUp,
  Undo2,
  UserCheck,
  UserCog,
  Users,
  Wallet,
  type LucideIcon,
} from "lucide-react";
import logo from "@/assets/logo.jpg";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { useSession } from "@/hooks/use-session";
import {
  bottomBarItems,
  buildNavGroups,
  findActiveItem,
  navHref,
  navKindFor,
  type NavGroup,
  type NavIcon,
  type NavItem,
} from "@/lib/app-nav";
import { businessKindLabel, isHospitalOrClinic } from "@/lib/business-kind";
import { cn } from "@/lib/utils";

const ICONS: Record<NavIcon, LucideIcon> = {
  dashboard: LayoutDashboard,
  orders: ReceiptText,
  products: Pill,
  customers: Users,
  discounts: Tag,
  insights: TrendingUp,
  batches: Boxes,
  returns: Undo2,
  credit: Wallet,
  payments: CreditCard,
  accounting: Calculator,
  rfqs: FileQuestion,
  reports: BarChart3,
  contacts: ClipboardList,
  audit: ScrollText,
  team: UserCog,
  settings: Settings,
  security: ShieldCheck,
  privacy: Lock,
  admin: ShieldCheck,
  catalog: Pill,
  lists: ListChecks,
  procurement: ShoppingCart,
  inventory: PackageSearch,
  statements: FileText,
  billing: CreditCard,
  verification: UserCheck,
  activity: Activity,
};

export type NavTone = "wholesaler" | "pharmacy" | "clinic" | "admin";

const TONE_CLASS: Record<NavTone, string> = {
  wholesaler: "border-violet-200 bg-violet-100 text-violet-800",
  pharmacy: "border-blue-200 bg-blue-100 text-blue-800",
  clinic: "border-emerald-200 bg-emerald-100 text-emerald-800",
  admin: "border-amber-200 bg-amber-100 text-amber-800",
};

const TONE_ICON: Record<NavTone, LucideIcon> = {
  wholesaler: Building2,
  pharmacy: Store,
  clinic: Hospital,
  admin: ShieldCheck,
};

const WIDE_KEY = "drugxone-nav-wide";

/** Wide by default on a computer, slim on a tablet; the choice is remembered on this device. */
function useNavWide() {
  const [wide, setWide] = useState(() => {
    if (typeof window === "undefined") return true;
    try {
      const saved = window.localStorage.getItem(WIDE_KEY);
      if (saved === "1") return true;
      if (saved === "0") return false;
    } catch {
      // Storage can be blocked; fall back to the screen size.
    }
    return window.innerWidth >= 1024;
  });
  const toggle = () =>
    setWide((current) => {
      const next = !current;
      try {
        window.localStorage.setItem(WIDE_KEY, next ? "1" : "0");
      } catch {
        // Not remembering the choice is fine.
      }
      return next;
    });
  return [wide, toggle] as const;
}

function isPlainClick(event: React.MouseEvent) {
  return !(event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0);
}

type ViewProps = {
  groups: NavGroup[];
  bottom: NavItem[];
  activeId: string | null;
  workspaceName: string;
  kindLabel: string;
  tone: NavTone;
  wide: boolean;
  onToggleWide: () => void;
  onGo: (item: NavItem) => void;
  onGoPath: (path: string) => void;
  onSignOut: () => void;
  showAddBusiness: boolean;
};

/**
 * The navigation itself, with no knowledge of the router or the session, so it can be shown and
 * tested on its own. Phone: a bottom bar plus a More sheet. Tablet and computer: a left rail
 * that expands to show labels.
 */
export function AppNavigationView({
  groups,
  bottom,
  activeId,
  workspaceName,
  kindLabel,
  tone,
  wide,
  onToggleWide,
  onGo,
  onGoPath,
  onSignOut,
  showAddBusiness,
}: ViewProps) {
  const [moreOpen, setMoreOpen] = useState(false);
  const ToneIcon = TONE_ICON[tone];
  const bottomIds = new Set(bottom.map((item) => item.id));
  const activeInMore = activeId !== null && !bottomIds.has(activeId);

  // Tells the page layout how much room the rail takes (see styles.css).
  useEffect(() => {
    const root = document.documentElement;
    root.dataset.appNav = wide ? "wide" : "slim";
    return () => {
      delete root.dataset.appNav;
    };
  }, [wide]);

  const link = (
    item: NavItem,
    className: string,
    children: React.ReactNode,
    after?: () => void,
  ) => (
    <a
      key={item.id}
      href={navHref(item)}
      aria-current={item.id === activeId ? "page" : undefined}
      title={item.label}
      className={className}
      onClick={(event) => {
        if (!isPlainClick(event)) return;
        event.preventDefault();
        onGo(item);
        after?.();
      }}
    >
      {children}
    </a>
  );

  return (
    <>
      {/* Tablet and computer: left rail */}
      <aside
        aria-label="Main navigation"
        data-testid="nav-rail"
        className={cn(
          "fixed inset-y-0 left-0 z-30 hidden flex-col border-r border-border bg-card transition-[width] duration-200 motion-reduce:transition-none md:flex",
          wide ? "w-64" : "w-[4.5rem]",
        )}
      >
        <div className={cn("flex items-center gap-2 px-3 pb-2 pt-3", wide ? "" : "flex-col")}>
          <button
            type="button"
            onClick={() => onGoPath("/dashboard")}
            className="flex min-w-0 flex-1 items-center gap-2 rounded-xl p-1 text-left"
            aria-label="Go to dashboard"
          >
            <img src={logo} alt="" className="h-9 w-9 shrink-0 rounded-xl object-contain" />
            {wide && (
              <span className="truncate font-display text-base font-bold">
                Drug<span className="text-primary">xone</span>
              </span>
            )}
          </button>
          <button
            type="button"
            onClick={onToggleWide}
            aria-label={wide ? "Collapse navigation" : "Expand navigation"}
            aria-expanded={wide}
            className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl text-muted-foreground hover:bg-muted hover:text-foreground"
          >
            {wide ? <PanelLeftClose className="h-4 w-4" /> : <PanelLeftOpen className="h-4 w-4" />}
          </button>
        </div>

        <div
          className={cn(
            "mx-3 mb-2 flex items-center gap-2 rounded-2xl border border-border bg-muted/50 p-2",
            wide ? "" : "justify-center",
          )}
          title={`${workspaceName} · ${kindLabel}`}
        >
          <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary text-primary-foreground">
            <ToneIcon className="h-4 w-4" aria-hidden="true" />
          </span>
          {wide && (
            <span className="flex min-w-0 flex-col items-start gap-1">
              <span className="max-w-full truncate text-sm font-semibold leading-none">
                {workspaceName}
              </span>
              <span
                className={cn(
                  "rounded-full border px-2 py-0.5 text-[11px] font-semibold leading-none",
                  TONE_CLASS[tone],
                )}
              >
                {kindLabel}
              </span>
            </span>
          )}
        </div>

        <nav className="min-h-0 flex-1 overflow-y-auto px-3 pb-2">
          {groups.map((navGroup) => (
            <div key={navGroup.id} className="mb-1">
              {wide ? (
                <div className="px-3 pb-1 pt-3 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
                  {navGroup.label}
                </div>
              ) : (
                <div className="mx-3 my-2 border-t border-border" aria-hidden="true" />
              )}
              {navGroup.items.map((item) => {
                const Icon = ICONS[item.icon];
                const active = item.id === activeId;
                return link(
                  item,
                  cn(
                    "flex min-h-10 items-center gap-3 rounded-xl px-3 py-2 text-sm transition-colors",
                    wide ? "" : "justify-center px-0",
                    active
                      ? "bg-primary/10 font-semibold text-primary"
                      : "font-medium text-muted-foreground hover:bg-muted hover:text-foreground",
                  ),
                  <>
                    <Icon className="h-[18px] w-[18px] shrink-0" aria-hidden="true" />
                    {wide ? (
                      <span className="truncate">{item.label}</span>
                    ) : (
                      <span className="sr-only">{item.label}</span>
                    )}
                  </>,
                );
              })}
            </div>
          ))}
        </nav>

        <div className="space-y-1 border-t border-border p-3">
          {showAddBusiness && (
            <button
              type="button"
              onClick={() => onGoPath("/add-business")}
              title="Add business"
              className={cn(
                "flex min-h-10 w-full items-center gap-3 rounded-xl px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-muted hover:text-foreground",
                wide ? "" : "justify-center px-0",
              )}
            >
              <PlusCircle className="h-[18px] w-[18px] shrink-0" aria-hidden="true" />
              {wide ? <span>Add business</span> : <span className="sr-only">Add business</span>}
            </button>
          )}
          <button
            type="button"
            onClick={() => onGoPath("/help")}
            title="Help"
            className={cn(
              "flex min-h-10 w-full items-center gap-3 rounded-xl px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-muted hover:text-foreground",
              wide ? "" : "justify-center px-0",
            )}
          >
            <HelpCircle className="h-[18px] w-[18px] shrink-0" aria-hidden="true" />
            {wide ? <span>Help</span> : <span className="sr-only">Help</span>}
          </button>
          <button
            type="button"
            onClick={onSignOut}
            title="Sign out"
            className={cn(
              "flex min-h-10 w-full items-center gap-3 rounded-xl px-3 py-2 text-sm font-medium text-muted-foreground hover:bg-muted hover:text-foreground",
              wide ? "" : "justify-center px-0",
            )}
          >
            <LogOut className="h-[18px] w-[18px] shrink-0" aria-hidden="true" />
            {wide ? <span>Sign out</span> : <span className="sr-only">Sign out</span>}
          </button>
        </div>
      </aside>

      {/* Phone: bottom bar */}
      <nav
        aria-label="Main navigation"
        data-testid="nav-bottom"
        className="fixed inset-x-0 bottom-0 z-40 grid auto-cols-fr grid-flow-col border-t border-border bg-card/95 px-1 pt-1 backdrop-blur-xl md:hidden"
        style={{ paddingBottom: "max(0.5rem, env(safe-area-inset-bottom, 0px))" }}
      >
        {bottom.map((item) => {
          const Icon = ICONS[item.icon];
          const active = item.id === activeId;
          return link(
            item,
            cn(
              "flex min-h-[3.25rem] min-w-0 flex-col items-center justify-center gap-0.5 rounded-xl text-[11px] font-semibold",
              active ? "text-primary" : "text-muted-foreground",
            ),
            <>
              <span
                className={cn(
                  "flex h-7 w-12 items-center justify-center rounded-full",
                  active ? "bg-primary/10" : "",
                )}
              >
                <Icon className="h-5 w-5" aria-hidden="true" />
              </span>
              <span className="max-w-full truncate px-0.5">{item.short ?? item.label}</span>
            </>,
          );
        })}
        <button
          type="button"
          onClick={() => setMoreOpen(true)}
          aria-haspopup="dialog"
          aria-expanded={moreOpen}
          className={cn(
            "flex min-h-[3.25rem] min-w-0 flex-col items-center justify-center gap-0.5 rounded-xl text-[11px] font-semibold",
            activeInMore ? "text-primary" : "text-muted-foreground",
          )}
        >
          <span
            className={cn(
              "flex h-7 w-12 items-center justify-center rounded-full",
              activeInMore ? "bg-primary/10" : "",
            )}
          >
            <MoreHorizontal className="h-5 w-5" aria-hidden="true" />
          </span>
          <span>More</span>
        </button>
      </nav>

      {/* Phone: everything else */}
      <Sheet open={moreOpen} onOpenChange={setMoreOpen}>
        <SheetContent
          side="bottom"
          className="max-h-[85vh] overflow-y-auto rounded-t-3xl px-4 pb-6 pt-4 md:hidden"
        >
          <SheetHeader className="mb-1 text-left">
            <SheetTitle className="font-display text-lg">{workspaceName}</SheetTitle>
          </SheetHeader>
          {groups.map((navGroup) => (
            <div key={navGroup.id}>
              <div className="pb-2 pt-4 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
                {navGroup.label}
              </div>
              <div className="grid grid-cols-3 gap-2">
                {navGroup.items.map((item) => {
                  const Icon = ICONS[item.icon];
                  const active = item.id === activeId;
                  return link(
                    item,
                    cn(
                      "flex min-h-[4.75rem] flex-col items-center justify-center gap-1.5 rounded-2xl border px-1.5 py-2 text-center text-xs font-semibold",
                      active
                        ? "border-primary bg-primary/10 text-primary"
                        : "border-border bg-muted/50 text-foreground",
                    ),
                    <>
                      <Icon className="h-5 w-5" aria-hidden="true" />
                      <span className="leading-tight">{item.short ?? item.label}</span>
                    </>,
                    () => setMoreOpen(false),
                  );
                })}
              </div>
            </div>
          ))}
          <div className="mt-5 grid grid-cols-2 gap-2">
            {showAddBusiness && (
              <button
                type="button"
                onClick={() => {
                  setMoreOpen(false);
                  onGoPath("/add-business");
                }}
                className="flex min-h-11 items-center justify-center gap-2 rounded-xl border border-border text-sm font-semibold"
              >
                <PlusCircle className="h-4 w-4" aria-hidden="true" /> Add business
              </button>
            )}
            <button
              type="button"
              onClick={() => {
                setMoreOpen(false);
                onGoPath("/help");
              }}
              className="flex min-h-11 items-center justify-center gap-2 rounded-xl border border-border text-sm font-semibold"
            >
              <HelpCircle className="h-4 w-4" aria-hidden="true" /> Help
            </button>
            <button
              type="button"
              onClick={() => {
                setMoreOpen(false);
                onSignOut();
              }}
              className="flex min-h-11 items-center justify-center gap-2 rounded-xl border border-border text-sm font-semibold"
            >
              <LogOut className="h-4 w-4" aria-hidden="true" /> Sign out
            </button>
          </div>
        </SheetContent>
      </Sheet>
    </>
  );
}

/** What the page header shows in the top bar for the current screen. */
export function useActiveNavLabel(isPlatformAdmin: boolean) {
  const { business } = useSession();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  return useMemo(() => {
    const kind = navKindFor(pathname, business?.type, isPlatformAdmin);
    if (!kind || typeof window === "undefined") return null;
    const groups = buildNavGroups({
      kind,
      staffRole: business?.staff_role,
      isPlatformAdmin,
      hasWorkspace: Boolean(business),
    });
    return findActiveItem(groups, pathname, window.location.search, kind)?.label ?? null;
  }, [pathname, business, isPlatformAdmin]);
}

/** True when the navigation shows for this page, so the header can drop what the nav now covers. */
export function useHasAppNavigation(showNav: boolean, isPlatformAdmin = false) {
  const { business } = useSession();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const kind = navKindFor(pathname, business?.type, isPlatformAdmin);
  return kind === "admin" || (showNav && kind !== null);
}

export function AppNavigation({
  isPlatformAdmin,
  onSignOut,
}: {
  isPlatformAdmin: boolean;
  onSignOut: () => void;
}) {
  const navigate = useNavigate();
  const { business, businesses } = useSession();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const [wide, toggleWide] = useNavWide();
  const [, setTick] = useState(0);

  // Re-read the address when the page changes its own ?tab= (back button, in-page links).
  useEffect(() => {
    const refresh = () => setTick((tick) => tick + 1);
    window.addEventListener("popstate", refresh);
    return () => window.removeEventListener("popstate", refresh);
  }, []);

  const kind = navKindFor(pathname, business?.type, isPlatformAdmin);
  const groups = useMemo(
    () =>
      kind
        ? buildNavGroups({
            kind,
            staffRole: business?.staff_role,
            isPlatformAdmin,
            hasWorkspace: Boolean(business),
          })
        : [],
    [kind, business, isPlatformAdmin],
  );

  if (!kind) return null;

  const search = typeof window === "undefined" ? "" : window.location.search;
  const active = findActiveItem(groups, pathname, search, kind);
  const tone: NavTone =
    kind === "admin"
      ? "admin"
      : business && isHospitalOrClinic(business)
        ? "clinic"
        : kind === "wholesaler"
          ? "wholesaler"
          : "pharmacy";

  const goPath = (path: string) => {
    void navigate({ to: path } as never);
  };

  const go = async (item: NavItem) => {
    await navigate({
      to: item.to,
      ...(item.tab ? { search: { tab: item.tab } } : {}),
    } as never);
    // The workspace pages keep their open tab in step with the address on popstate.
    window.dispatchEvent(new PopStateEvent("popstate"));
  };

  return (
    <AppNavigationView
      groups={groups}
      bottom={bottomBarItems(groups, kind)}
      activeId={active?.id ?? null}
      workspaceName={kind === "admin" ? "Platform admin" : (business?.name ?? "Drugxone")}
      kindLabel={kind === "admin" ? "Admin" : business ? businessKindLabel(business) : ""}
      tone={tone}
      wide={wide}
      onToggleWide={toggleWide}
      onGo={(item) => void go(item)}
      onGoPath={goPath}
      onSignOut={onSignOut}
      showAddBusiness={kind !== "admin" && businesses.length > 0 && Boolean(business)}
    />
  );
}
