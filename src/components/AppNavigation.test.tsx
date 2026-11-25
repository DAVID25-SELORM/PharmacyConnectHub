// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

vi.mock("@/hooks/use-session", () => ({ useSession: () => ({ business: null, businesses: [] }) }));
vi.mock("@tanstack/react-router", () => ({
  useNavigate: () => vi.fn(),
  useRouterState: () => "/wholesaler",
}));

import { AppNavigationView } from "./AppNavigation";
import { buildNavGroups, bottomBarItems, type NavItem } from "@/lib/app-nav";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;
const groups = buildNavGroups({ kind: "wholesaler", staffRole: "owner", isPlatformAdmin: false });

function mount(props: Partial<Parameters<typeof AppNavigationView>[0]> = {}) {
  const onGo = vi.fn();
  const onGoPath = vi.fn();
  const onSignOut = vi.fn();
  act(() => {
    root.render(
      <AppNavigationView
        groups={groups}
        bottom={bottomBarItems(groups, "wholesaler")}
        activeId="orders"
        workspaceName="Ideal Pharma"
        kindLabel="Wholesaler"
        tone="wholesaler"
        wide
        onToggleWide={vi.fn()}
        onGo={onGo}
        onGoPath={onGoPath}
        onSignOut={onSignOut}
        showAddBusiness
        {...props}
      />,
    );
  });
  return { onGo, onGoPath, onSignOut };
}

beforeEach(() => {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
});
afterEach(() => {
  act(() => root.unmount());
  host.remove();
  document.body.innerHTML = "";
});

it("marks the current screen in the rail and in the bottom bar", () => {
  mount();
  const rail = document.querySelector('[data-testid="nav-rail"]')!;
  const bottom = document.querySelector('[data-testid="nav-bottom"]')!;
  expect(rail.querySelector('[aria-current="page"]')?.getAttribute("href")).toBe(
    "/wholesaler?tab=orders",
  );
  expect(bottom.querySelector('[aria-current="page"]')?.textContent).toContain("Orders");
});

it("shows the group names and labels when wide, and only icons when slim", () => {
  mount({ wide: true });
  const rail = document.querySelector('[data-testid="nav-rail"]')!;
  expect(rail.textContent).toContain("Sell");
  expect(rail.textContent).toContain("Incoming orders");
  expect(document.documentElement.dataset.appNav).toBe("wide");

  mount({ wide: false });
  expect(document.documentElement.dataset.appNav).toBe("slim");
  // Labels stay available to screen readers.
  expect(rail.querySelector("a")?.textContent).toContain("Dashboard");
  expect(rail.querySelector("a .truncate")).toBeNull();
});

it("goes to a screen on a normal click but lets a modified click open a new tab", () => {
  const { onGo } = mount();
  const link = document.querySelector<HTMLAnchorElement>(
    '[data-testid="nav-rail"] a[href="/wholesaler?tab=products"]',
  )!;
  act(() => {
    link.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
  });
  expect(onGo).toHaveBeenCalledTimes(1);
  expect((onGo.mock.calls[0][0] as NavItem).id).toBe("products");

  act(() => {
    link.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ctrlKey: true }),
    );
  });
  expect(onGo).toHaveBeenCalledTimes(1);
});

it("keeps help, add business and sign out in the rail", () => {
  const { onGoPath, onSignOut } = mount();
  const rail = document.querySelector('[data-testid="nav-rail"]')!;
  const byTitle = (title: string) =>
    rail.querySelector<HTMLButtonElement>(`button[title="${title}"]`)!;
  act(() => byTitle("Help").click());
  act(() => byTitle("Add business").click());
  act(() => byTitle("Sign out").click());
  expect(onGoPath).toHaveBeenCalledWith("/help");
  expect(onGoPath).toHaveBeenCalledWith("/add-business");
  expect(onSignOut).toHaveBeenCalledTimes(1);
});

it("puts every screen under More on a phone", () => {
  mount({ activeId: "audit" });
  const bottom = document.querySelector('[data-testid="nav-bottom"]')!;
  const more = Array.from(bottom.querySelectorAll("button")).find((b) => b.textContent === "More")!;
  expect(more.className).toContain("text-primary");
  act(() => more.click());
  const dialog = document.querySelector('[role="dialog"]')!;
  expect(dialog.textContent).toContain("Audit log");
  expect(dialog.textContent).toContain(
    "Customer discounts".replace("Customer discounts", "Discounts"),
  );
  expect(dialog.textContent).toContain("Sign out");
});
