import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { ChevronDown, ChevronUp, Download, Package, Plus } from "lucide-react";
import { WorkspaceGate } from "@/components/WorkspaceGate";
import { DashboardHeader } from "@/components/DashboardShell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { AdjustStockDialog } from "@/components/pharmacy-inventory/AdjustStockDialog";
import { BulkImportInventoryDialog } from "@/components/pharmacy-inventory/BulkImportInventoryDialog";
import { InventoryItemFormDialog } from "@/components/pharmacy-inventory/InventoryItemFormDialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import { EXPIRING_SOON_DAYS, daysUntil } from "@/lib/dashboard";
import { formatGHS } from "@/lib/format";
import { downloadCsv, downloadPdf, downloadXlsx, formatReportDate, formatReportDateTime, reportFilename, rowsToCsv } from "@/lib/reports";
import {
  inventoryItemsToExportSheet,
  inventoryItemsToPdfSheet,
  isLowStock,
  ITEM_TYPE_LABELS,
  ITEM_TYPE_OPTIONS,
  MOVEMENT_REASON_LABELS,
  type PharmacyInventoryItem,
  type PharmacyInventoryMovement,
  type PharmacyItemType,
} from "@/lib/pharmacy-inventory";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export const Route = createFileRoute("/pharmacy_/inventory")({
  head: () => ({ meta: [{ title: "Inventory - Drugxone" }] }),
  // Dashboard links arrive as ?filter=low|expiring.
  validateSearch: (search: Record<string, unknown>): { filter?: "low" | "expiring" } =>
    search.filter === "low" || search.filter === "expiring" ? { filter: search.filter } : {},
  component: () => (
    <WorkspaceGate>
      <PharmacyInventoryPage />
    </WorkspaceGate>
  ),
});

function PharmacyInventoryPage() {
  const { business } = useSession();
  const { filter: initialFilter } = Route.useSearch();
  const [items, setItems] = useState<PharmacyInventoryItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [showInactive, setShowInactive] = useState(false);
  const [lowStockOnly, setLowStockOnly] = useState(initialFilter === "low");
  const [expiringOnly, setExpiringOnly] = useState(initialFilter === "expiring");
  const [typeFilter, setTypeFilter] = useState<PharmacyItemType | "all">("all");
  const [formItem, setFormItem] = useState<PharmacyInventoryItem | null | "new">(null);
  const [adjustItem, setAdjustItem] = useState<PharmacyInventoryItem | null>(null);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [movements, setMovements] = useState<PharmacyInventoryMovement[]>([]);
  const [movementsLoading, setMovementsLoading] = useState(false);
  const [exporting, setExporting] = useState(false);

  const load = useCallback(async () => {
    if (!business) return;
    setLoading(true);
    const { data } = await db
      .from("pharmacy_inventory_items")
      .select("*")
      .eq("pharmacy_id", business.id)
      .order("name");
    setItems((data as PharmacyInventoryItem[] | null) ?? []);
    setLoading(false);
  }, [business]);

  useEffect(() => {
    void load();
  }, [load]);

  const loadMovements = async (itemId: string) => {
    setMovementsLoading(true);
    const { data } = await db
      .from("pharmacy_inventory_movements")
      .select("*")
      .eq("item_id", itemId)
      .order("created_at", { ascending: false })
      .limit(20);
    setMovements((data as PharmacyInventoryMovement[] | null) ?? []);
    setMovementsLoading(false);
  };

  const toggleExpand = async (item: PharmacyInventoryItem) => {
    if (expandedId === item.id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(item.id);
    await loadMovements(item.id);
  };

  if (!business) return null;

  const canManage =
    business.staff_role === "owner" ||
    business.staff_role === "manager" ||
    business.staff_role === "cashier" ||
    business.staff_role === "warehouse";
  const canImport = business.staff_role === "owner" || business.staff_role === "manager";

  const visibleItems = items
    .filter((i) => showInactive || i.active)
    .filter((i) => !lowStockOnly || isLowStock(i) || i.stock <= 0)
    .filter((i) => !expiringOnly || (i.expiry_date !== null && daysUntil(i.expiry_date) <= EXPIRING_SOON_DAYS))
    .filter((i) => typeFilter === "all" || i.item_type === typeFilter)
    .filter((i) => {
      const q = search.trim().toLowerCase();
      if (!q) return true;
      return (
        i.name.toLowerCase().includes(q) ||
        (i.brand ?? "").toLowerCase().includes(q) ||
        (i.category ?? "").toLowerCase().includes(q) ||
        (i.barcode ?? "").toLowerCase().includes(q) ||
        (i.manufacturer ?? "").toLowerCase().includes(q) ||
        (i.supplier ?? "").toLowerCase().includes(q)
      );
    });

  const lowStockCount = items.filter((i) => i.active && isLowStock(i)).length;

  // Exports whatever is currently on screen, so active search/type/low-stock/inactive filters are
  // preserved rather than always dumping the full inventory.
  const exportInventory = async (format: "csv" | "xlsx" | "pdf") => {
    if (visibleItems.length === 0 || exporting) return;
    setExporting(true);
    try {
      if (format === "pdf") {
        const sheet = inventoryItemsToPdfSheet(visibleItems);
        await downloadPdf(reportFilename("inventory", "pdf"), `${business.name} — Inventory`, [sheet]);
      } else {
        const sheet = inventoryItemsToExportSheet(visibleItems);
        if (format === "xlsx") await downloadXlsx(reportFilename("inventory", "xlsx"), [sheet]);
        else downloadCsv(reportFilename("inventory", "csv"), rowsToCsv(sheet.headers, sheet.rows));
      }
    } finally {
      setExporting(false);
    }
  };

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Inventory" showNav={true} />
      <main className="mx-auto max-w-5xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="font-display text-2xl font-bold">Inventory</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Your own stock on hand, tracked independently of marketplace orders.
              {lowStockCount > 0 && (
                <span className="ml-1 font-medium text-destructive">
                  {lowStockCount} item{lowStockCount === 1 ? "" : "s"} at or below reorder level.
                </span>
              )}
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button type="button" variant="outline" disabled={visibleItems.length === 0 || exporting}>
                  <Download className="mr-1.5 h-4 w-4" />
                  {exporting ? "Exporting..." : "Export"}
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onClick={() => void exportInventory("csv")}>Export as CSV</DropdownMenuItem>
                <DropdownMenuItem onClick={() => void exportInventory("xlsx")}>Export as Excel</DropdownMenuItem>
                <DropdownMenuItem onClick={() => void exportInventory("pdf")}>Export as PDF</DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
            {canImport && <BulkImportInventoryDialog pharmacyId={business.id} reload={load} />}
            {canManage && (
              <Button type="button" onClick={() => setFormItem("new")}>
                <Plus className="mr-1.5 h-4 w-4" />
                Add item
              </Button>
            )}
          </div>
        </div>

        <div className="mt-6 flex flex-wrap items-center gap-2">
          <Input
            className="max-w-xs"
            placeholder="Search by name, brand, category, barcode..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <Select value={typeFilter} onValueChange={(v) => setTypeFilter(v as PharmacyItemType | "all")}>
            <SelectTrigger className="w-[180px]">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All item types</SelectItem>
              {ITEM_TYPE_OPTIONS.map((opt) => (
                <SelectItem key={opt.value} value={opt.value}>
                  {opt.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Button type="button" size="sm" variant={lowStockOnly ? "secondary" : "ghost"} onClick={() => setLowStockOnly((v) => !v)}>
            Low stock only
          </Button>
          <Button type="button" size="sm" variant={expiringOnly ? "secondary" : "ghost"} onClick={() => setExpiringOnly((v) => !v)}>
            Expiring soon
          </Button>
          <Button type="button" size="sm" variant={showInactive ? "secondary" : "ghost"} onClick={() => setShowInactive((v) => !v)}>
            Show inactive
          </Button>
        </div>

        <div className="mt-4 space-y-2">
          {loading ? (
            <>
              <Skeleton className="h-16 w-full" />
              <Skeleton className="h-16 w-full" />
            </>
          ) : visibleItems.length === 0 ? (
            <Card className="flex flex-col items-center gap-2 p-10 text-center text-muted-foreground">
              <Package className="h-8 w-8" />
              <p>{items.length === 0 ? "No inventory tracked yet. Add an item or bulk upload to get started." : "No items match this filter."}</p>
            </Card>
          ) : (
            <ul className="divide-y divide-border rounded-xl border border-border text-sm">
              {visibleItems.map((item) => {
                const expanded = expandedId === item.id;
                const low = isLowStock(item);
                return (
                  <li key={item.id} className="p-3">
                    <div className="flex flex-wrap items-center justify-between gap-3">
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="font-medium">{item.name}</span>
                          <Badge variant="outline" className="whitespace-nowrap">
                            {ITEM_TYPE_LABELS[item.item_type]}
                          </Badge>
                          {!item.active && (
                            <Badge variant="secondary" className="border bg-muted text-muted-foreground">
                              Inactive
                            </Badge>
                          )}
                          {low && (
                            <Badge variant="secondary" className="border bg-destructive/15 text-destructive border-destructive/30">
                              Low stock
                            </Badge>
                          )}
                        </div>
                        <div className="text-muted-foreground">
                          {[item.brand, item.category, item.form, item.pack_size].filter(Boolean).join(" · ") || "—"}
                          {item.expiry_date && ` · expires ${formatReportDate(item.expiry_date)}`}
                        </div>
                      </div>
                      <div className="flex items-center gap-4">
                        <div className="text-right">
                          <div className="font-display text-lg font-bold">{item.stock}</div>
                          <div className="text-xs text-muted-foreground">
                            {item.reorder_level !== null ? `reorder at ${item.reorder_level}` : "no reorder level"}
                          </div>
                        </div>
                        {item.unit_cost_ghs !== null && (
                          <div className="text-right text-muted-foreground">{formatGHS(item.unit_cost_ghs)}/unit</div>
                        )}
                        {canManage && (
                          <div className="flex gap-1">
                            <Button type="button" size="sm" variant="outline" onClick={() => setAdjustItem(item)}>
                              Adjust
                            </Button>
                            <Button type="button" size="sm" variant="ghost" onClick={() => setFormItem(item)}>
                              Edit
                            </Button>
                          </div>
                        )}
                        <Button type="button" size="sm" variant="ghost" onClick={() => void toggleExpand(item)} aria-expanded={expanded}>
                          {expanded ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                        </Button>
                      </div>
                    </div>

                    {expanded && (
                      <div className="mt-3 rounded-lg border border-border bg-muted/20 p-3">
                        {movementsLoading ? (
                          <Skeleton className="h-10 w-full" />
                        ) : movements.length === 0 ? (
                          <p className="text-xs text-muted-foreground">No stock movements yet.</p>
                        ) : (
                          <ul className="space-y-1.5">
                            {movements.map((m) => (
                              <li key={m.id} className="flex items-center justify-between gap-3 text-xs">
                                <span className="text-muted-foreground">
                                  {formatReportDateTime(m.created_at)} · {m.kind.replace(/_/g, " ")}
                                  {m.reason ? ` · ${MOVEMENT_REASON_LABELS[m.reason]}` : ""}
                                  {m.note ? ` · ${m.note}` : ""}
                                </span>
                                <span className={m.quantity_delta > 0 ? "text-success" : "text-destructive"}>
                                  {m.quantity_delta > 0 ? "+" : ""}
                                  {m.quantity_delta} → {m.stock_after}
                                </span>
                              </li>
                            ))}
                          </ul>
                        )}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </main>

      <InventoryItemFormDialog
        pharmacyId={business.id}
        item={formItem === "new" ? null : formItem}
        open={formItem !== null}
        onOpenChange={(open) => !open && setFormItem(null)}
        onSaved={() => void load()}
      />
      <AdjustStockDialog
        item={adjustItem}
        open={adjustItem !== null}
        onOpenChange={(open) => !open && setAdjustItem(null)}
        onAdjusted={() => {
          void load();
          if (adjustItem && expandedId === adjustItem.id) void loadMovements(adjustItem.id);
        }}
      />
    </div>
  );
}
