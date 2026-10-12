import { createFileRoute } from "@tanstack/react-router";
import { DashboardHeader } from "@/components/DashboardShell";
import { AdminNav } from "@/components/admin/AdminNav";
import { AdminBillingOrganizationsSection } from "@/components/billing/AdminBillingOrganizationsSection";
import { AdminBillingOverviewSection } from "@/components/billing/AdminBillingOverviewSection";
import { AdminBillingPlansSection } from "@/components/billing/AdminBillingPlansSection";
import { AdminBillingReconciliationSection } from "@/components/billing/AdminBillingReconciliationSection";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

export const Route = createFileRoute("/admin/billing")({
  head: () => ({ meta: [{ title: "Platform Billing - Drugxone" }] }),
  component: AdminBillingPage,
});

function AdminBillingPage() {
  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Platform Billing" isAdmin={true} />
      <AdminNav />
      <main className="mx-auto max-w-7xl space-y-6 px-4 py-8 sm:px-6 lg:px-8">
        <div>
          <h1 className="font-display text-2xl font-bold">Platform Billing</h1>
          <p className="text-sm text-muted-foreground">
            Subscriptions, platform fees and what DrugXOne earns. Read-only: figures come straight
            from the billing records.
          </p>
        </div>
        <Tabs defaultValue="overview" className="w-full">
          <TabsList className="mb-4 h-auto max-w-full justify-start overflow-x-auto [&>button]:shrink-0">
            <TabsTrigger value="overview">Overview</TabsTrigger>
            <TabsTrigger value="organizations">Organizations</TabsTrigger>
            <TabsTrigger value="plans">Plans</TabsTrigger>
            <TabsTrigger value="reconciliation">Reconciliation</TabsTrigger>
          </TabsList>
          <TabsContent value="overview">
            <AdminBillingOverviewSection />
          </TabsContent>
          <TabsContent value="organizations">
            <AdminBillingOrganizationsSection />
          </TabsContent>
          <TabsContent value="plans">
            <AdminBillingPlansSection />
          </TabsContent>
          <TabsContent value="reconciliation">
            <AdminBillingReconciliationSection />
          </TabsContent>
        </Tabs>
      </main>
    </div>
  );
}
