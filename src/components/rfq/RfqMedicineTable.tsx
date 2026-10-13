import { memo, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Combine,
  Plus,
  Search,
  SlidersHorizontal,
  Trash2,
  X,
} from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { MedicationPicker } from "./MedicationPicker";
import { TablePager } from "./TablePager";
import {
  RFQ_MAX_LINES,
  RFQ_PAGE_SIZES,
  RFQ_UNITS,
  appendLines,
  applyToLines,
  blankLine,
  firstIssueIndex,
  mergeDuplicateLines,
  pageOf,
  removeLines,
  summarize,
  visibleIndices,
  type LineFilter,
  type RfqLine,
} from "@/lib/rfq-lines";

const selectBase =
  "h-9 rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-50";
const selectClass = `${selectBase} w-full`;

type RowProps = {
  line: RfqLine;
  position: number;
  issue?: string;
  checked: boolean;
  disabled: boolean;
  onUpdate: (uid: string, patch: Partial<RfqLine>) => void;
  onToggle: (uid: string, on: boolean) => void;
  onRemove: (uid: string) => void;
};

const Row = memo(function Row({
  line,
  position,
  issue,
  checked,
  disabled,
  onUpdate,
  onToggle,
  onRemove,
}: RowProps) {
  const named = Boolean(line.productName.trim());
  const flags = [
    !line.partialAllowed && "No partial supply",
    line.alternativesAllowed && "Alternatives",
    line.coldChainRequired && "Cold chain",
    (line.specialHandling.trim() || line.notes.trim()) && "Notes",
  ].filter(Boolean) as string[];
  return (
    <TableRow
      data-state={checked ? "selected" : undefined}
      className={issue ? "bg-destructive/5" : undefined}
    >
      <TableCell className="w-10 align-top">
        <Checkbox
          aria-label={`Select line ${position}`}
          checked={checked}
          disabled={disabled}
          onCheckedChange={(v) => onToggle(line.uid, v === true)}
        />
      </TableCell>
      <TableCell className="w-12 align-top pt-4 text-xs tabular-nums text-muted-foreground">
        {position}
      </TableCell>
      <TableCell className="min-w-[280px] align-top">
        <div className="flex items-start gap-2">
          <span
            className="pt-2"
            title={line.masterProductId ? "Matched to the catalogue" : "Not matched"}
          >
            {issue ? (
              <AlertTriangle className="h-4 w-4 text-destructive" aria-label="Needs attention" />
            ) : line.masterProductId ? (
              <CheckCircle2
                className="h-4 w-4 text-success"
                aria-label="Matched to the catalogue"
              />
            ) : named ? (
              <AlertTriangle className="h-4 w-4 text-warning" aria-label="Not in the catalogue" />
            ) : (
              <span className="block h-4 w-4" />
            )}
          </span>
          <div className="min-w-0 flex-1">
            <MedicationPicker
              value={line.productName}
              onChange={(productName) => onUpdate(line.uid, { productName, masterProductId: null })}
              onSelect={(p) => onUpdate(line.uid, { masterProductId: p.id })}
              placeholder="Medicine name"
            />
            {issue ? (
              <p className="mt-1 text-xs text-destructive">{issue}</p>
            ) : named && !line.masterProductId ? (
              <p className="mt-1 text-xs text-muted-foreground">
                Not matched to the catalogue. Pick a suggestion, or allow alternatives.
              </p>
            ) : null}
          </div>
        </div>
      </TableCell>
      <TableCell className="w-28 align-top">
        <Input
          aria-label={`Quantity for line ${position}`}
          type="number"
          min="1"
          step="1"
          inputMode="numeric"
          className="tabular-nums"
          value={line.quantity}
          disabled={disabled}
          onChange={(e) => onUpdate(line.uid, { quantity: e.target.value })}
        />
      </TableCell>
      <TableCell className="w-28 align-top">
        <select
          aria-label={`Unit for line ${position}`}
          className={selectClass}
          value={line.unit}
          disabled={disabled}
          onChange={(e) => onUpdate(line.uid, { unit: e.target.value })}
        >
          {RFQ_UNITS.map((u) => (
            <option key={u} value={u}>
              {u}
            </option>
          ))}
        </select>
      </TableCell>
      <TableCell className="w-28 align-top">
        <Input
          aria-label={`Minimum shelf life in days for line ${position}`}
          type="number"
          min="0"
          inputMode="numeric"
          className="tabular-nums"
          value={line.shelfLifeDays}
          disabled={disabled}
          onChange={(e) => onUpdate(line.uid, { shelfLifeDays: Number(e.target.value) })}
        />
      </TableCell>
      <TableCell className="w-44 align-top">
        <Popover>
          <PopoverTrigger asChild>
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-9 w-full justify-start gap-2 font-normal"
              disabled={disabled}
              aria-label={`Options for line ${position}`}
            >
              <SlidersHorizontal className="h-3.5 w-3.5 shrink-0" />
              <span className="truncate text-xs">
                {flags.length ? flags.join(" · ") : "Options"}
              </span>
            </Button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-80 space-y-3">
            <p className="text-sm font-medium">Line {position} options</p>
            {(
              [
                ["partialAllowed", "Allow partial supply"],
                ["alternativesAllowed", "Allow alternatives"],
                ["coldChainRequired", "Cold chain required"],
              ] as const
            ).map(([key, text]) => (
              <label key={key} className="flex items-center gap-2 text-sm">
                <Checkbox
                  checked={line[key]}
                  onCheckedChange={(v) => onUpdate(line.uid, { [key]: v === true })}
                />
                {text}
              </label>
            ))}
            <label className="block space-y-1 text-sm">
              <span className="text-muted-foreground">Required storage or handling</span>
              <Input
                value={line.specialHandling}
                onChange={(e) => onUpdate(line.uid, { specialHandling: e.target.value })}
              />
            </label>
            <label className="block space-y-1 text-sm">
              <span className="text-muted-foreground">Brand, strength, pack or other notes</span>
              <Input
                value={line.notes}
                onChange={(e) => onUpdate(line.uid, { notes: e.target.value })}
              />
            </label>
          </PopoverContent>
        </Popover>
      </TableCell>
      <TableCell className="w-10 align-top">
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-9 w-9 text-muted-foreground hover:text-destructive"
          aria-label={`Remove line ${position}`}
          disabled={disabled}
          onClick={() => onRemove(line.uid)}
        >
          <Trash2 className="h-4 w-4" />
        </Button>
      </TableCell>
    </TableRow>
  );
});

/** The medicine list of an RFQ: quick add, search and filter, paging, bulk edits and duplicate clean-up. */
export function RfqMedicineTable({
  lines,
  onChange,
  issues,
  disabled = false,
  tools,
}: {
  lines: RfqLine[];
  onChange: (next: RfqLine[]) => void;
  issues: Map<number, string>;
  disabled?: boolean;
  /** Extra "add medicines" actions (import, history, catalogue) shown beside the quick-add bar. */
  tools?: ReactNode;
}) {
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<LineFilter>("all");
  const [page, setPage] = useState(0);
  const [size, setSize] = useState<number>(RFQ_PAGE_SIZES[0]);
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set());
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [bulkShelf, setBulkShelf] = useState("90");

  const linesRef = useRef(lines);
  linesRef.current = lines;
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  const view = useMemo(
    () => visibleIndices(lines, issues, { search, filter }),
    [lines, issues, search, filter],
  );
  const paged = pageOf(view, page, size);
  const stats = summarize(lines, issues);
  const duplicates = useMemo(
    () => [...issues.values()].filter((m) => m.startsWith("Duplicate")).length,
    [issues],
  );

  // Selection never outlives its lines.
  useEffect(() => {
    setSelected((current) => {
      if (!current.size) return current;
      const live = new Set(lines.map((l) => l.uid));
      const next = new Set([...current].filter((uid) => live.has(uid)));
      return next.size === current.size ? current : next;
    });
  }, [lines]);

  const update = useCallback((uid: string, patch: Partial<RfqLine>) => {
    onChangeRef.current(linesRef.current.map((l) => (l.uid === uid ? { ...l, ...patch } : l)));
  }, []);
  const toggle = useCallback((uid: string, on: boolean) => {
    setSelected((current) => {
      const next = new Set(current);
      if (on) next.add(uid);
      else next.delete(uid);
      return next;
    });
  }, []);
  const removeOne = useCallback((uid: string) => {
    onChangeRef.current(linesRef.current.filter((l) => l.uid !== uid));
  }, []);

  const pageUids = paged.rows.map((i) => lines[i].uid);
  const allOnPage = pageUids.length > 0 && pageUids.every((uid) => selected.has(uid));
  const someOnPage = pageUids.some((uid) => selected.has(uid));
  const allMatchingSelected = view.length > 0 && view.every((i) => selected.has(lines[i].uid));

  const bulk = (patch: Partial<Omit<RfqLine, "uid">>) => {
    onChange(applyToLines(lines, selected, patch));
    toast.success(`Updated ${selected.size} line${selected.size === 1 ? "" : "s"}.`);
  };

  // Quick add
  const [qName, setQName] = useState("");
  const [qMaster, setQMaster] = useState<string | null>(null);
  const [qQty, setQQty] = useState("1");
  const [qUnit, setQUnit] = useState<string>("pack");
  const [pickerKey, setPickerKey] = useState(0);
  const addOne = () => {
    const name = qName.trim();
    const qty = Number(qQty);
    if (!name) return toast.error("Enter a medicine name first.");
    if (!Number.isSafeInteger(qty) || qty <= 0)
      return toast.error("Enter a whole quantity of at least 1.");
    if (lines.length >= RFQ_MAX_LINES)
      return toast.error(`An RFQ holds at most ${RFQ_MAX_LINES} medicines.`);
    const added = {
      ...blankLine(),
      productName: name,
      masterProductId: qMaster,
      quantity: String(qty),
      unit: qUnit,
    };
    const { lines: next, merged } = mergeDuplicateLines(appendLines(lines, [added]).lines);
    onChange(next);
    if (merged) toast.success(`${name} was already listed: quantity added to that line.`);
    setSearch("");
    setFilter("all");
    setPage(Math.ceil(next.length / size) - 1);
    setQName("");
    setQMaster(null);
    setQQty("1");
    setPickerKey((k) => k + 1);
  };

  const showIssues = () => {
    setSearch("");
    setFilter("attention");
    setPage(0);
  };

  return (
    <div className="space-y-4">
      <form
        className="flex flex-wrap items-end gap-2 rounded-lg border bg-muted/30 p-3"
        onSubmit={(e) => {
          e.preventDefault();
          addOne();
        }}
      >
        <div className="min-w-[240px] flex-1 space-y-1">
          <label className="text-xs font-medium text-muted-foreground">Add a medicine</label>
          <MedicationPicker
            key={pickerKey}
            value={qName}
            onChange={(v) => {
              setQName(v);
              setQMaster(null);
            }}
            onSelect={(p) => setQMaster(p.id)}
          />
        </div>
        <div className="w-24 space-y-1">
          <label className="text-xs font-medium text-muted-foreground" htmlFor="rfq-quick-qty">
            Quantity
          </label>
          <Input
            id="rfq-quick-qty"
            type="number"
            min="1"
            step="1"
            inputMode="numeric"
            value={qQty}
            onChange={(e) => setQQty(e.target.value)}
          />
        </div>
        <div className="w-28 space-y-1">
          <label className="text-xs font-medium text-muted-foreground" htmlFor="rfq-quick-unit">
            Unit
          </label>
          <select
            id="rfq-quick-unit"
            className={selectClass}
            value={qUnit}
            onChange={(e) => setQUnit(e.target.value)}
          >
            {RFQ_UNITS.map((u) => (
              <option key={u} value={u}>
                {u}
              </option>
            ))}
          </select>
        </div>
        <Button type="submit" disabled={disabled} className="gap-1">
          <Plus className="h-4 w-4" /> Add
        </Button>
        {tools && <div className="flex flex-wrap items-center gap-2 sm:ml-auto">{tools}</div>}
      </form>

      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="secondary" className="tabular-nums">
          {stats.total} / {RFQ_MAX_LINES} medicines
        </Badge>
        {stats.total > 0 && (
          <>
            <Badge variant="outline" className="gap-1 tabular-nums">
              <CheckCircle2 className="h-3 w-3 text-success" /> {stats.matched} matched
            </Badge>
            {stats.unmatched > 0 && (
              <Badge variant="outline" className="gap-1 tabular-nums">
                <AlertTriangle className="h-3 w-3 text-warning" /> {stats.unmatched} not in
                catalogue
              </Badge>
            )}
            {stats.coldChain > 0 && (
              <Badge variant="outline" className="tabular-nums">
                {stats.coldChain} cold chain
              </Badge>
            )}
          </>
        )}
        {stats.withIssues > 0 && (
          <button
            type="button"
            onClick={showIssues}
            className="inline-flex items-center gap-1 rounded-md border border-destructive/40 bg-destructive/10 px-2.5 py-0.5 text-xs font-semibold text-destructive hover:bg-destructive/15"
          >
            <AlertTriangle className="h-3 w-3" /> {stats.withIssues} need attention · show
          </button>
        )}
        {duplicates > 0 && (
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="h-7 gap-1 text-xs"
            disabled={disabled}
            onClick={() => {
              const { lines: next, merged } = mergeDuplicateLines(lines);
              onChange(next);
              toast.success(`Combined ${merged} duplicate line${merged === 1 ? "" : "s"}.`);
            }}
          >
            <Combine className="h-3.5 w-3.5" /> Combine duplicates
          </Button>
        )}
      </div>

      {lines.length === 0 ? (
        <div className="rounded-lg border border-dashed px-6 py-12 text-center">
          <p className="font-medium">No medicines yet</p>
          <p className="mx-auto mt-1 max-w-md text-sm text-muted-foreground">
            Add a medicine above, import a spreadsheet, or pick from what you have bought before. An
            RFQ can hold up to {RFQ_MAX_LINES} medicines.
          </p>
        </div>
      ) : (
        <div className="overflow-hidden rounded-lg border">
          <div className="flex flex-wrap items-center gap-2 border-b bg-muted/30 p-2">
            <div className="relative min-w-[200px] flex-1 sm:max-w-xs">
              <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
              <Input
                aria-label="Search this list"
                placeholder="Search this list"
                className="pl-8"
                value={search}
                onChange={(e) => {
                  setSearch(e.target.value);
                  setPage(0);
                }}
              />
            </div>
            <select
              aria-label="Show"
              className={`${selectBase} w-44`}
              value={filter}
              onChange={(e) => {
                setFilter(e.target.value as LineFilter);
                setPage(0);
              }}
            >
              <option value="all">All medicines</option>
              <option value="attention">Needs attention</option>
              <option value="unmatched">Not in catalogue</option>
            </select>
            {(search || filter !== "all") && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="gap-1"
                onClick={() => {
                  setSearch("");
                  setFilter("all");
                  setPage(0);
                }}
              >
                <X className="h-3.5 w-3.5" /> Clear
              </Button>
            )}
            <span className="ml-auto text-xs text-muted-foreground tabular-nums">
              {view.length === lines.length
                ? `${lines.length} lines`
                : `${view.length} of ${lines.length} lines`}
            </span>
          </div>

          {selected.size > 0 && (
            <div className="flex flex-wrap items-center gap-2 border-b bg-primary/5 px-3 py-2 text-sm">
              <span className="font-medium tabular-nums">{selected.size} selected</span>
              {!allMatchingSelected && view.length > selected.size && (
                <button
                  type="button"
                  className="text-xs text-primary underline"
                  onClick={() => setSelected(new Set(view.map((i) => lines[i].uid)))}
                >
                  Select all {view.length} in this view
                </button>
              )}
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button type="button" variant="outline" size="sm" disabled={disabled}>
                    Change…
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start" className="w-56">
                  <DropdownMenuLabel>Unit</DropdownMenuLabel>
                  {RFQ_UNITS.map((u) => (
                    <DropdownMenuItem key={u} onSelect={() => bulk({ unit: u })}>
                      Set unit to {u}
                    </DropdownMenuItem>
                  ))}
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onSelect={() => bulk({ partialAllowed: true })}>
                    Allow partial supply
                  </DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => bulk({ partialAllowed: false })}>
                    Require full supply
                  </DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => bulk({ alternativesAllowed: true })}>
                    Allow alternatives
                  </DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => bulk({ alternativesAllowed: false })}>
                    Do not allow alternatives
                  </DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => bulk({ coldChainRequired: true })}>
                    Cold chain required
                  </DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => bulk({ coldChainRequired: false })}>
                    Cold chain not required
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
              <div className="flex items-center gap-1">
                <Input
                  aria-label="Minimum shelf life in days for the selected lines"
                  type="number"
                  min="0"
                  className="h-8 w-20 tabular-nums"
                  value={bulkShelf}
                  onChange={(e) => setBulkShelf(e.target.value)}
                />
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  disabled={disabled || bulkShelf === "" || Number(bulkShelf) < 0}
                  onClick={() => bulk({ shelfLifeDays: Number(bulkShelf) })}
                >
                  Set shelf life
                </Button>
              </div>
              {confirmRemove ? (
                <>
                  <Button
                    type="button"
                    variant="destructive"
                    size="sm"
                    disabled={disabled}
                    onClick={() => {
                      const n = selected.size;
                      onChange(removeLines(lines, selected));
                      setSelected(new Set());
                      setConfirmRemove(false);
                      toast.success(`Removed ${n} line${n === 1 ? "" : "s"}.`);
                    }}
                  >
                    Remove {selected.size} for good
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    onClick={() => setConfirmRemove(false)}
                  >
                    Keep them
                  </Button>
                </>
              ) : (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="gap-1 text-destructive hover:text-destructive"
                  disabled={disabled}
                  onClick={() => setConfirmRemove(true)}
                >
                  <Trash2 className="h-3.5 w-3.5" /> Remove
                </Button>
              )}
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="ml-auto"
                onClick={() => {
                  setSelected(new Set());
                  setConfirmRemove(false);
                }}
              >
                Clear selection
              </Button>
            </div>
          )}

          <div className="overflow-x-auto">
            <Table className="min-w-[860px]">
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead className="w-10">
                    <Checkbox
                      aria-label="Select all lines on this page"
                      checked={allOnPage ? true : someOnPage ? "indeterminate" : false}
                      disabled={disabled || !pageUids.length}
                      onCheckedChange={(v) =>
                        setSelected((current) => {
                          const next = new Set(current);
                          for (const uid of pageUids) {
                            if (v === true) next.add(uid);
                            else next.delete(uid);
                          }
                          return next;
                        })
                      }
                    />
                  </TableHead>
                  <TableHead className="w-12">#</TableHead>
                  <TableHead>Medicine</TableHead>
                  <TableHead className="w-28">Quantity</TableHead>
                  <TableHead className="w-28">Unit</TableHead>
                  <TableHead className="w-28" title="Minimum remaining shelf life, in days">
                    Shelf life (days)
                  </TableHead>
                  <TableHead className="w-44">Options</TableHead>
                  <TableHead className="w-10">
                    <span className="sr-only">Remove</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {paged.rows.length === 0 ? (
                  <TableRow>
                    <TableCell
                      colSpan={8}
                      className="py-10 text-center text-sm text-muted-foreground"
                    >
                      No medicines match.{" "}
                      <button
                        type="button"
                        className="text-primary underline"
                        onClick={() => {
                          setSearch("");
                          setFilter("all");
                        }}
                      >
                        Show all
                      </button>
                    </TableCell>
                  </TableRow>
                ) : (
                  paged.rows.map((i) => (
                    <Row
                      key={lines[i].uid}
                      line={lines[i]}
                      position={i + 1}
                      issue={issues.get(i)}
                      checked={selected.has(lines[i].uid)}
                      disabled={disabled}
                      onUpdate={update}
                      onToggle={toggle}
                      onRemove={removeOne}
                    />
                  ))
                )}
              </TableBody>
            </Table>
          </div>

          <TablePager paged={paged} size={size} onSize={setSize} onPage={setPage} />
        </div>
      )}
      {stats.withIssues > 0 && firstIssueIndex(issues) >= 0 && filter === "all" && !search && (
        <p className="text-xs text-muted-foreground">
          First problem is on line {firstIssueIndex(issues) + 1}.
        </p>
      )}
    </div>
  );
}
