import { useEffect, useState } from "react";
import {
  AlertTriangle,
  BookOpen,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  History,
  Upload,
} from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ProcurementCatalogue } from "@/components/procurement/ProcurementCatalogue";
import { medicineLabel } from "@/lib/procurement-catalogue";
import { rfqCall, rfqDb } from "@/lib/enterprise-rfq";
import { rfqRows } from "@/lib/rfq-bulk";
import { RFQ_MAX_LINES, blankLine, type RfqLine } from "@/lib/rfq-lines";

type Tool = "import" | "history" | "catalogue" | null;
type History = { master_product_id: string; product_name: string; quantity: number };
const HISTORY_PAGE = 25;

const TEMPLATE =
  "Medicine,Quantity,Notes\nParacetamol 500mg Tablets,20,\nAmoxicillin 500mg Capsules,10,Brand preferred\n";

/** The three ways to add many medicines at once: a spreadsheet, past purchases, or the catalogue. */
export function RfqAddTools({
  businessId,
  onAdd,
  onError,
  disabled = false,
}: {
  businessId: string;
  /** Receives new lines; the parent appends them and enforces the per-RFQ limit. */
  onAdd: (lines: RfqLine[]) => void;
  onError: (message: string) => void;
  disabled?: boolean;
}) {
  const [tool, setTool] = useState<Tool>(null);
  const close = () => setTool(null);
  return (
    <>
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="gap-1.5"
        disabled={disabled}
        onClick={() => setTool("import")}
      >
        <Upload className="h-4 w-4" /> Import spreadsheet
      </Button>
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="gap-1.5"
        disabled={disabled}
        onClick={() => setTool("history")}
      >
        <History className="h-4 w-4" /> Past purchases
      </Button>
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="gap-1.5"
        disabled={disabled}
        onClick={() => setTool("catalogue")}
      >
        <BookOpen className="h-4 w-4" /> Catalogue
      </Button>
      {tool === "import" && <ImportDialog onClose={close} onAdd={onAdd} />}
      {tool === "history" && (
        <HistoryDialog businessId={businessId} onClose={close} onAdd={onAdd} onError={onError} />
      )}
      {tool === "catalogue" && (
        <CatalogueDialog businessId={businessId} onClose={close} onAdd={onAdd} />
      )}
    </>
  );
}

function ImportDialog({
  onClose,
  onAdd,
}: {
  onClose: () => void;
  onAdd: (lines: RfqLine[]) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  const [preview, setPreview] = useState<RfqLine[] | null>(null);

  const read = async (file: File) => {
    setBusy(true);
    setProblem("");
    try {
      if (!/\.(xlsx|xls|csv|tsv)$/i.test(file.name) || file.size > 5 * 1024 * 1024)
        throw new Error("Use an Excel or CSV file up to 5 MB.");
      const XLSX = await import("xlsx");
      const book = XLSX.read(await file.arrayBuffer());
      const rows = rfqRows(
        XLSX.utils.sheet_to_json(book.Sheets[book.SheetNames[0]], { header: 1 }),
      );
      if (rows.length > RFQ_MAX_LINES) throw new Error(`Maximum ${RFQ_MAX_LINES} rows per RFQ.`);
      const mapped: RfqLine[] = [];
      for (let start = 0; start < rows.length; start += 50) {
        const batch = rows.slice(start, start + 50);
        const { data, error } = await rfqDb
          .from("master_products")
          .select("id,name")
          .eq("active", true)
          .in("name", [...new Set(batch.map((row) => row.productName))]);
        if (error) throw new Error(error.message);
        for (const row of batch) {
          const matches = (data as { id: string; name: string }[]).filter(
            (p) => p.name === row.productName,
          );
          mapped.push({
            ...blankLine(),
            ...row,
            masterProductId: matches.length === 1 ? matches[0].id : null,
            notes: [
              row.notes,
              matches.length > 1
                ? "Ambiguous catalogue name: choose the exact strength, form and pack."
                : matches.length === 0
                  ? "Unmatched catalogue name: review identity."
                  : "",
            ]
              .filter(Boolean)
              .join(" "),
          });
        }
      }
      setPreview(mapped);
    } catch (e) {
      setProblem((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const matched = preview?.filter((l) => l.masterProductId).length ?? 0;
  const download = () => {
    const url = URL.createObjectURL(new Blob([TEMPLATE], { type: "text/csv" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = "rfq-medicines-template.csv";
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>Import medicines from a spreadsheet</DialogTitle>
          <DialogDescription>
            Excel or CSV, up to 5 MB and {RFQ_MAX_LINES} rows. Use the column headings Medicine and
            Quantity, and optionally Notes. Nothing is added until you confirm.
          </DialogDescription>
        </DialogHeader>
        {!preview ? (
          <div className="space-y-3">
            <label className="flex cursor-pointer flex-col items-center gap-2 rounded-lg border border-dashed px-6 py-10 text-center hover:bg-muted/40">
              <Upload className="h-6 w-6 text-muted-foreground" />
              <span className="text-sm font-medium">
                {busy ? "Reading the file…" : "Choose a spreadsheet"}
              </span>
              <span className="text-xs text-muted-foreground">.xlsx, .xls, .csv or .tsv</span>
              <Input
                type="file"
                accept=".xlsx,.xls,.csv,.tsv"
                className="sr-only"
                disabled={busy}
                onChange={(e) => {
                  if (e.target.files?.[0]) void read(e.target.files[0]);
                  e.target.value = "";
                }}
              />
            </label>
            {problem && (
              <p role="alert" className="text-sm text-destructive">
                {problem}
              </p>
            )}
            <button type="button" className="text-xs text-primary underline" onClick={download}>
              Download a blank template
            </button>
          </div>
        ) : (
          <div className="space-y-3">
            <div className="flex flex-wrap items-center gap-2">
              <Badge variant="secondary" className="tabular-nums">
                {preview.length} rows
              </Badge>
              <Badge variant="outline" className="gap-1 tabular-nums">
                <CheckCircle2 className="h-3 w-3 text-success" /> {matched} matched
              </Badge>
              {preview.length - matched > 0 && (
                <Badge variant="outline" className="gap-1 tabular-nums">
                  <AlertTriangle className="h-3 w-3 text-warning" /> {preview.length - matched} need
                  review
                </Badge>
              )}
              <span className="text-xs text-muted-foreground">
                Catalogue identities need review; no substitutions are inferred.
              </span>
            </div>
            <div className="max-h-72 overflow-auto rounded-md border">
              <Table>
                <TableHeader>
                  <TableRow className="bg-muted/40 hover:bg-muted/40">
                    <TableHead className="w-12">#</TableHead>
                    <TableHead>Medicine</TableHead>
                    <TableHead className="w-24">Quantity</TableHead>
                    <TableHead className="w-40">Catalogue</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {preview.slice(0, 200).map((l, i) => (
                    <TableRow key={l.uid}>
                      <TableCell className="text-xs tabular-nums text-muted-foreground">
                        {i + 1}
                      </TableCell>
                      <TableCell>{l.productName}</TableCell>
                      <TableCell className="tabular-nums">{l.quantity}</TableCell>
                      <TableCell className="text-xs">
                        {l.masterProductId ? (
                          "Matched"
                        ) : (
                          <span className="text-warning-foreground">Needs review</span>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            {preview.length > 200 && (
              <p className="text-xs text-muted-foreground">
                Showing the first 200 of {preview.length} rows.
              </p>
            )}
          </div>
        )}
        <DialogFooter>
          {preview && (
            <Button type="button" variant="ghost" onClick={() => setPreview(null)}>
              Choose another file
            </Button>
          )}
          <Button type="button" variant="outline" onClick={onClose}>
            {preview ? "Discard" : "Cancel"}
          </Button>
          {preview && (
            <Button
              type="button"
              onClick={() => {
                onAdd(preview);
                onClose();
              }}
            >
              Add {preview.length} medicines to the list
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function HistoryDialog({
  businessId,
  onClose,
  onAdd,
  onError,
}: {
  businessId: string;
  onClose: () => void;
  onAdd: (lines: RfqLine[]) => void;
  onError: (message: string) => void;
}) {
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<History[]>([]);
  const [loading, setLoading] = useState(true);
  const [picked, setPicked] = useState<Map<string, History>>(new Map());
  useEffect(() => {
    let active = true;
    setLoading(true);
    void rfqCall<History[]>("rfq_purchase_history", {
      p_pharmacy_id: businessId,
      p_offset: page * HISTORY_PAGE,
    })
      .then((data) => active && setRows(data))
      .catch((e) => active && onError(e.message))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [businessId, page, onError]);
  const key = (h: History) => h.master_product_id;
  const allOnPage = rows.length > 0 && rows.every((h) => picked.has(key(h)));
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>Add from past purchases</DialogTitle>
          <DialogDescription>
            Medicines you have ordered before, with the quantity you last bought.
          </DialogDescription>
        </DialogHeader>
        <div className="max-h-80 overflow-auto rounded-md border">
          <Table>
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead className="w-10">
                  <Checkbox
                    aria-label="Select all on this page"
                    checked={allOnPage}
                    onCheckedChange={(v) =>
                      setPicked((current) => {
                        const next = new Map(current);
                        for (const h of rows) {
                          if (v === true) next.set(key(h), h);
                          else next.delete(key(h));
                        }
                        return next;
                      })
                    }
                  />
                </TableHead>
                <TableHead>Medicine</TableHead>
                <TableHead className="w-32">Last quantity</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={3} className="py-8 text-center text-sm text-muted-foreground">
                    {loading ? "Loading…" : "No purchases found."}
                  </TableCell>
                </TableRow>
              ) : (
                rows.map((h) => (
                  <TableRow key={key(h)}>
                    <TableCell>
                      <Checkbox
                        aria-label={`Select ${h.product_name}`}
                        checked={picked.has(key(h))}
                        onCheckedChange={(v) =>
                          setPicked((current) => {
                            const next = new Map(current);
                            if (v === true) next.set(key(h), h);
                            else next.delete(key(h));
                            return next;
                          })
                        }
                      />
                    </TableCell>
                    <TableCell>{h.product_name}</TableCell>
                    <TableCell className="tabular-nums">{h.quantity}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </div>
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          <span className="tabular-nums">{picked.size} selected</span>
          <div className="ml-auto flex items-center gap-1">
            <Button
              type="button"
              variant="outline"
              size="icon"
              className="h-8 w-8"
              aria-label="Previous page"
              disabled={!page}
              onClick={() => setPage((p) => p - 1)}
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <span className="px-1 tabular-nums">Page {page + 1}</span>
            <Button
              type="button"
              variant="outline"
              size="icon"
              className="h-8 w-8"
              aria-label="Next page"
              disabled={rows.length < HISTORY_PAGE}
              onClick={() => setPage((p) => p + 1)}
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            type="button"
            disabled={!picked.size}
            onClick={() => {
              onAdd(
                [...picked.values()].map((h) => ({
                  ...blankLine(),
                  productName: h.product_name,
                  masterProductId: h.master_product_id,
                  quantity: String(h.quantity > 0 ? h.quantity : 1),
                })),
              );
              onClose();
            }}
          >
            Add {picked.size || ""} selected
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function CatalogueDialog({
  businessId,
  onClose,
  onAdd,
}: {
  businessId: string;
  onClose: () => void;
  onAdd: (lines: RfqLine[]) => void;
}) {
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Add from your catalogue</DialogTitle>
          <DialogDescription>
            Your private catalogue and the shared master catalogue. Each medicine you add appears in
            the list; keep adding, then close this window.
          </DialogDescription>
        </DialogHeader>
        <ProcurementCatalogue
          businessId={businessId}
          onAdd={(entry) => {
            const units = { packs: "pack", boxes: "box", bottles: "bottle" } as Record<
              string,
              string
            >;
            onAdd([
              {
                ...blankLine(),
                productName: medicineLabel(entry.data),
                masterProductId: entry.source === "master" ? entry.id : null,
                unit: units[entry.data.unit] || "unit",
                notes: [
                  entry.data.notes,
                  !["packs", "boxes", "bottles"].includes(entry.data.unit)
                    ? `Each unit means one ${entry.data.unit || "piece"}.`
                    : "",
                ]
                  .filter(Boolean)
                  .join(" "),
              },
            ]);
            toast.success(`Added ${medicineLabel(entry.data)}.`);
          }}
        />
        <DialogFooter>
          <Button type="button" onClick={onClose}>
            Done
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
