import { createFileRoute } from "@tanstack/react-router";
import { DashboardHeader } from "@/components/DashboardShell";
import { AdminNav } from "@/components/admin/AdminNav";
import { AdminBillingInvoicesSection } from "@/components/billing/AdminBillingInvoicesSection";
import { AdminBillingOrganizationsSection } from "@/components/billing/AdminBillingOrganizationsSection";
import { AdminBillingOverviewSection } from "@/components/billing/AdminBillingOverviewSection";
import { AdminBillingRolloutSection } from "@/components/billing/AdminBillingRolloutSection";
import { BillingSetup } from "@/components/billing/BillingSetup";
import { AdminBillingPromotionsSection } from "@/components/billing/AdminBillingPromotionsSection";
import { PricingPlans } from "@/components/billing/PricingPlans";
import { AdminBillingReconciliationSection } from "@/components/billing/AdminBillingReconciliationSection";
import { useState } from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

export const Route = createFileRoute("/admin/billing")({
  head: () => ({ meta: [{ title: "Platform Billing - Drugxone" }] }),
  component: AdminBillingPage,
});

function AdminBillingPage() {
  const [tab, setTab] = useState("setup");
  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Platform Billing" isAdmin={true} />
      <AdminNav />
      <main className="mx-auto max-w-7xl space-y-6 px-4 py-8 sm:px-6 lg:px-8">
        <div>
          <h1 className="font-display text-2xl font-bold">Platform Billing</h1>
          <p className="text-sm text-muted-foreground">
            Subscriptions, platform fees and what DrugXOne earns. Start with Setup: it walks through
            pricing, invoices, the shadow test and the first pilot businesses. Every change needs a
            reason and is audited.
          </p>
        </div>
        <Tabs value={tab} onValueChange={setTab} className="w-full">
          <TabsList className="mb-4 h-auto max-w-full justify-start overflow-x-auto [&>button]:shrink-0">
            <TabsTrigger value="setup">Setup</TabsTrigger>
            <TabsTrigger value="overview">Overview</TabsTrigger>
            <TabsTrigger value="organizations">Organizations</TabsTrigger>
            <TabsTrigger value="invoices">Invoices</TabsTrigger>
            <TabsTrigger value="plans">Pricing & Plans</TabsTrigger>
            <TabsTrigger value="promotions">Promotions</TabsTrigger>
            <TabsTrigger value="rollout">Go live</TabsTrigger>
            <TabsTrigger value="reconciliation">Reconciliation</TabsTrigger>
          </TabsList>
          <TabsContent value="setup">
            <BillingSetup />
          </TabsContent>
          <TabsContent value="overview">
            <AdminBillingOverviewSection />
          </TabsContent>
          <TabsContent value="organizations">
            <AdminBillingOrganizationsSection />
          </TabsContent>
          <TabsContent value="invoices">
            <AdminBillingInvoicesSection />
          </TabsContent>
          <TabsContent value="plans">
            <PricingPlans onOpenTab={setTab} />
          </TabsContent>
          <TabsContent value="promotions">
            <AdminBillingPromotionsSection />
          </TabsContent>
          <TabsContent value="rollout">
            <AdminBillingRolloutSection onOpenSetup={() => setTab("setup")} />
          </TabsContent>
          <TabsContent value="reconciliation">
            <AdminBillingReconciliationSection />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}
