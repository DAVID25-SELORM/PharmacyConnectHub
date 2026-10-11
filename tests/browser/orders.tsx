import React from "react";
import { createRoot } from "react-dom/client";
import { createRootRoute, createRouter, RouterProvider } from "@tanstack/react-router";
import { OrdersView } from "../../src/routes/pharmacy";
import { DashboardHeader } from "../../src/components/DashboardShell";
import { Button } from "../../src/components/ui/button";
import "../../src/styles.css";
const order = {
  id: "fixture",
  pharmacy_id: "fixture",
  order_number: "ORD-FIXTURE",
  status: "delivered",
  total_ghs: 27,
  payment_method: "cod",
  payment_status: "paid",
  is_credit_order: true,
  created_at: "2026-10-01",
  return_eligible: true,
  return_deadline: "2026-10-31",
  item_count: 1,
  unit_count: 10,
  wholesaler: { name: "Fixture Supplier" },
  order_items: [],
};
function Fixture() {
  return (
    <>
      <DashboardHeader subtitle="Pharmacy workspace" showNav rightSlot={<Button>Cart</Button>} />
      <main className="max-w-7xl mx-auto p-4">
        <h1 className="text-2xl mb-4">Fixture pharmacy</h1>
        <OrdersView
          {...({
            orders: [order],
            totalCount: 1,
            counts: { active: 0, awaiting: 0, transit: 0, delivered: 1 },
            loading: false,
            error: null,
            loadOrders: async () => {},
            loadOrderDetail: async () => null,
            wholesalers: [],
            onRequestReturn: () => {},
            onReorder: async () => {},
          } as any)}
        />
      </main>
    </>
  );
}
const route = createRootRoute({ component: Fixture });
const router = createRouter({ routeTree: route });
createRoot(document.getElementById("root")!).render(<RouterProvider router={router} />);
