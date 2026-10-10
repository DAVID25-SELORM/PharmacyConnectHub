import { useCallback, useEffect, useState } from "react";
import { CheckCircle2, Loader2, XCircle } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { formatGHS } from "@/lib/format";
import {
  PAYOUT_STATUS_LABELS,
  fetchPayoutAccounts,
  fetchProviderBanks,
  fetchReadiness,
  fetchServerChecks,
  fetchSettlementReport,
  formatBasisPoints,
  registerPayoutAccount,
  setPayoutAccountActive,
  type PayoutOverview,
  type PayoutSupplier,
  type ProviderBank,
  type Readiness,
  type ServerChecks,
  type SettlementRow,
} from "@/lib/payments-admin";

const accountClass = (status: string) =>
  status === "active"
    ? "bg-success/15 text-success border-success/30"
    : status === "failed"
      ? "bg-destructive/15 text-destructive border-destructive/30"
      : "bg-muted text-muted-foreground border-border";

const ITEM_LABELS: Record<string, string> = {
  split_on: "Each payment is split to the supplier's own account",
  cap_set: "A limit for one online payment is set",
  reconciler_alive: "The reconciler is running",
  live_payout_account: "A supplier has an active live settlement account",
  split_refunds_confirmed: "Refunds of split payments are confirmed with Paystack",
  no_critical_alerts: "No critical payment alert is open",
  daily_comparison_ran: "The daily comparison ran",
  no_unknown_refunds: "No refund is in doubt",
};

const SERVER_LABELS: Record<string, string> = {
  mode_set: "Payment mode is set",
  key_present: "A Paystack key is set",
  key_matches_mode: "The key matches the mode",
  live_switch: "The live switch is on (live mode only)",
  cron_secret: "The scheduler's secret is set",
  site_address: "The site address is set",
  no_local_stand_in: "No local stand-in is configured",
};

function Tick({ ok }: { ok: boolean }) {
  return ok ? (
    <CheckCircle2 className="h-4 w-4 shrink-0 text-success" aria-label="met" />
  ) : (
    <XCircle className="h-4 w-4 shrink-0 text-destructive" aria-label="not met" />
  );
}

export function SettlementSection() {
  const [overview, setOverview] = useState<PayoutOverview | null>(null);
  const [readiness, setReadiness] = useState<Readiness | null>(null);
  const [serverChecks, setServerChecks] = useState<ServerChecks | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState<PayoutSupplier | null>(null);
  const [banks, setBanks] = useState<ProviderBank[] | null>(null);
  const [banksError, setBanksError] = useState<string | null>(null);
  const [businessName, setBusinessName] = useState("");
  const [bankCode, setBankCode] = useState("");
  const [accountNumber, setAccountNumber] = useState("");
  const [saving, setSaving] = useState(false);
  const [days, setDays] = useState("7");
  const [report, setReport] = useState<SettlementRow[] | null>(null);
  const [reportError, setReportError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [accounts, ready] = await Promise.all([fetchPayoutAccounts(), fetchReadiness()]);
      setOverview(accounts);
      setReadiness(ready);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load settlement.");
    }
    fetchServerChecks()
      .then(setServerChecks)
      .catch(() => setServerChecks(null));
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const loadReport = useCallback(async () => {
    try {
      const to = new Date();
      const from = new Date(to.getTime() - Number(days) * 24 * 60 * 60 * 1000);
      setReport((await fetchSettlementReport(from, to)).suppliers);
      setReportError(null);
    } catch (e) {
      setReportError(e instanceof Error ? e.message : "Could not load the report.");
    }
  }, [days]);

  useEffect(() => {
    void loadReport();
  }, [loadReport]);

  const openAdd = (supplier: PayoutSupplier) => {
    setAdding(supplier);
    setBusinessName(supplier.name);
    setBankCode("");
    setAccountNumber("");
    setBanksError(null);
    if (!banks) {
      fetchProviderBanks()
        .then(setBanks)
        .catch((e) => setBanksError(e instanceof Error ? e.message : "Could not read the banks."));
    }
  };

  const save = async () => {
    if (!adding) return;
    setSaving(true);
    try {
      await registerPayoutAccount({
        wholesalerId: adding.wholesaler_id,
        businessName,
        bankCode,
        accountNumber,
      });
      toast.success("The settlement account was created.");
      setAdding(null);
      setAccountNumber("");
      await load();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not create the account.");
      await load();
    } finally {
      setSaving(false);
    }
  };

  const toggle = async (accountId: string, active: boolean) => {
    try {
      await setPayoutAccountActive(accountId, active);
      toast.success(active ? "Switched on." : "Switched off.");
      await load();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not change the account.");
    }
  };

  const settings = overview?.settings;
  const bankName = (code: string) => banks?.find((b) => b.code === code)?.name ?? code;
  const canSave =
    businessName.trim().length >= 2 && bankCode !== "" && /^[0-9\s-]{6,24}$/.test(accountNumber);

  return (
    <section aria-labelledby="settlement-heading" className="space-y-4" data-testid="settlement">
      <h2 id="settlement-heading" className="font-display text-lg font-bold">
        Settlement and going live
      </h2>
      {error && (
        <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
          {error}
        </Card>
      )}
      {!overview && !error && <Skeleton className="h-32" />}

      {readiness && (
        <Card className="space-y-3 p-4" data-testid="readiness">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="font-semibold">Ready for live money?</h3>
            <Badge
              variant="outline"
              className={
                readiness.ready_for_live
                  ? "border-success/30 bg-success/15 text-success"
                  : "border-destructive/30 bg-destructive/15 text-destructive"
              }
              data-testid="ready-badge"
            >
              {readiness.ready_for_live ? "Ready" : "Not ready"}
            </Badge>
          </div>
          <ul className="space-y-1.5 text-sm">
            {readiness.items.map((item) => (
              <li key={item.key} className="flex items-start gap-2" data-testid="readiness-item">
                <Tick ok={item.ok} />
                <span>
                  {ITEM_LABELS[item.key] ?? item.key}
                  {!item.blocking && (
                    <span className="ml-1 text-xs text-muted-foreground">(advice)</span>
                  )}
                  {!item.ok && (
                    <span className="block text-xs text-muted-foreground">{item.detail}</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
          {serverChecks && (
            <>
              <h4 className="pt-2 text-sm font-semibold">This server</h4>
              <ul className="space-y-1.5 text-sm">
                {serverChecks.checks.map((check) => (
                  <li key={check.key} className="flex items-start gap-2" data-testid="server-item">
                    <Tick ok={check.ok} />
                    <span>
                      {SERVER_LABELS[check.key] ?? check.key}
                      {!check.ok && (
                        <span className="block text-xs text-muted-foreground">{check.detail}</span>
                      )}
                    </span>
                  </li>
                ))}
              </ul>
            </>
          )}
          {settings && (
            <p
              className="border-t pt-2 text-xs text-muted-foreground"
              data-testid="settlement-settings"
            >
              Settings (changed only in the SQL Editor, see docs/payments/switches): split{" "}
              <strong>{settings.split_mode === "subaccount" ? "to each supplier" : "off"}</strong>,
              commission <strong>{formatBasisPoints(settings.platform_fee_bps)}</strong>, the{" "}
              <strong>{settings.fee_bearer === "subaccount" ? "supplier" : "platform"}</strong>{" "}
              bears the provider&apos;s fee, limit per payment{" "}
              <strong>
                {settings.max_order_ghs === null ? "none" : formatGHS(settings.max_order_ghs)}
              </strong>
              .
            </p>
          )}
        </Card>
      )}

      {overview && (
        <Card className="space-y-3 p-4" data-testid="payout-accounts">
          <h3 className="font-semibold">Supplier settlement accounts</h3>
          <p className="text-xs text-muted-foreground">
            Where each supplier&apos;s share of an online payment settles. Only the last four digits
            of an account number are ever kept. An account is made for the mode the server is in (
            {settings?.mode} mode now).
          </p>
          {overview.suppliers.length === 0 && (
            <p className="text-sm text-muted-foreground">No suppliers yet.</p>
          )}
          <ul className="divide-y">
            {overview.suppliers.map((supplier) => {
              const inUse = supplier.accounts.find(
                (a) => a.status === "active" || a.status === "pending",
              );
              return (
                <li
                  key={supplier.wholesaler_id}
                  className="space-y-2 py-3"
                  data-testid="payout-supplier"
                >
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">{supplier.name}</span>
                    {!inUse && (
                      <Button size="sm" variant="outline" onClick={() => openAdd(supplier)}>
                        Add settlement account
                      </Button>
                    )}
                  </div>
                  {supplier.accounts.map((account) => (
                    <div
                      key={account.id}
                      className="flex flex-wrap items-center gap-2 text-sm"
                      data-testid="payout-account"
                    >
                      <Badge variant="outline" className={accountClass(account.status)}>
                        {PAYOUT_STATUS_LABELS[account.status]}
                      </Badge>
                      <Badge variant="outline">{account.mode}</Badge>
                      <span>
                        {account.business_name} · {bankName(account.bank_code)} · ending{" "}
                        {account.last4}
                      </span>
                      {account.failure_reason && (
                        <span className="text-xs text-destructive">{account.failure_reason}</span>
                      )}
                      {account.status === "active" && (
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => void toggle(account.id, false)}
                        >
                          Switch off
                        </Button>
                      )}
                      {account.status === "inactive" && !inUse && (
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => void toggle(account.id, true)}
                        >
                          Switch on
                        </Button>
                      )}
                    </div>
                  ))}
                </li>
              );
            })}
          </ul>
        </Card>
      )}

      <Card className="space-y-3 p-4" data-testid="settlement-report">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="font-semibold">What should settle</h3>
          <Select value={days} onValueChange={setDays}>
            <SelectTrigger className="h-8 w-40 text-xs" aria-label="Period">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="1">Last 24 hours</SelectItem>
              <SelectItem value="7">Last 7 days</SelectItem>
              <SelectItem value="30">Last 30 days</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <p className="text-xs text-muted-foreground">
          For comparing with Paystack&apos;s own settlement report. Before Paystack&apos;s fees; an
          estimate, not a payout.
        </p>
        {reportError && <p className="text-sm text-destructive">{reportError}</p>}
        {report && report.length === 0 && (
          <p className="text-sm text-muted-foreground">No payments were received in this period.</p>
        )}
        {report && report.length > 0 && (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs text-muted-foreground">
                  <th className="py-1 pr-3">Supplier</th>
                  <th className="py-1 pr-3">Mode</th>
                  <th className="py-1 pr-3 text-right">Received</th>
                  <th className="py-1 pr-3 text-right">Platform share</th>
                  <th className="py-1 pr-3 text-right">Refunded</th>
                  <th className="py-1 pr-3 text-right">To settle</th>
                  <th className="py-1 text-right">Not split</th>
                </tr>
              </thead>
              <tbody>
                {report.map((row) => (
                  <tr
                    key={`${row.wholesaler_id}-${row.mode}`}
                    className="border-t"
                    data-testid="settlement-row"
                  >
                    <td className="py-1.5 pr-3">{row.name}</td>
                    <td className="py-1.5 pr-3">{row.mode}</td>
                    <td className="py-1.5 pr-3 text-right">{formatGHS(row.received_ghs)}</td>
                    <td className="py-1.5 pr-3 text-right">{formatGHS(row.platform_share_ghs)}</td>
                    <td className="py-1.5 pr-3 text-right">{formatGHS(row.refunded_ghs)}</td>
                    <td className="py-1.5 pr-3 text-right font-medium">
                      {formatGHS(row.to_settle_ghs)}
                    </td>
                    <td
                      className={`py-1.5 text-right ${row.not_split_ghs > 0 ? "font-medium text-destructive" : ""}`}
                    >
                      {formatGHS(row.not_split_ghs)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <Dialog open={adding !== null} onOpenChange={(o) => !o && !saving && setAdding(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Add a settlement account for {adding?.name}</DialogTitle>
            <DialogDescription>
              The account number goes to Paystack once and is not kept here; only its last four
              digits are shown afterwards. Check it carefully: money settles to this account.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1">
              <Label htmlFor="payout-name">Account name (business name)</Label>
              <Input
                id="payout-name"
                value={businessName}
                maxLength={120}
                onChange={(e) => setBusinessName(e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="payout-bank">Bank or mobile money operator</Label>
              <Select value={bankCode} onValueChange={setBankCode}>
                <SelectTrigger id="payout-bank">
                  <SelectValue placeholder={banks ? "Choose…" : "Loading…"} />
                </SelectTrigger>
                <SelectContent>
                  {(banks ?? []).map((bank) => (
                    <SelectItem key={bank.code} value={bank.code}>
                      {bank.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {banksError && <p className="text-xs text-destructive">{banksError}</p>}
            </div>
            <div className="space-y-1">
              <Label htmlFor="payout-number">Account number</Label>
              <Input
                id="payout-number"
                inputMode="numeric"
                autoComplete="off"
                value={accountNumber}
                maxLength={24}
                onChange={(e) => setAccountNumber(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" disabled={saving} onClick={() => setAdding(null)}>
              Cancel
            </Button>
            <Button disabled={saving || !canSave} onClick={() => void save()}>
              {saving ? (
                <>
                  <Loader2 className="mr-1 h-4 w-4 animate-spin" aria-hidden="true" /> Creating…
                </>
              ) : (
                "Create account"
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  );
}
