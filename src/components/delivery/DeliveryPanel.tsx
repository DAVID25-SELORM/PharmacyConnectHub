import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { supabase } from "@/integrations/supabase/client";
import {
  canRecordDispatch,
  canRecordProof,
  hasDispatchDetails,
  hasProof,
  toDateTimeLocal,
  type Delivery,
} from "@/lib/delivery";
import { formatReportDateTime } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block text-muted-foreground">{label}</span>
      {children}
    </label>
  );
}

/** Delivery details and proof of delivery for one order. The wholesaler edits; the pharmacy reads. */
export function DeliveryPanel({
  orderId,
  status,
  side,
  canEdit,
}: {
  orderId: string;
  status: string;
  side: "pharmacy" | "wholesaler";
  canEdit: boolean;
}) {
  const [delivery, setDelivery] = useState<Delivery | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [editing, setEditing] = useState<"dispatch" | "proof" | null>(null);
  const [saving, setSaving] = useState(false);

  const [driverName, setDriverName] = useState("");
  const [driverPhone, setDriverPhone] = useState("");
  const [reference, setReference] = useState("");
  const [expected, setExpected] = useState("");
  const [receivedBy, setReceivedBy] = useState("");
  const [receivedAt, setReceivedAt] = useState("");
  const [note, setNote] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await rpc("get_order_delivery", { p_order_id: orderId });
    if (rpcError) setError(true);
    else setDelivery((data ?? {}) as Delivery);
    setLoading(false);
  }, [orderId]);

  useEffect(() => {
    void load();
  }, [load]);

  const startEditing = (mode: "dispatch" | "proof") => {
    setDriverName(delivery?.driver_name ?? "");
    setDriverPhone(delivery?.driver_phone ?? "");
    setReference(delivery?.delivery_reference ?? "");
    setExpected(toDateTimeLocal(delivery?.expected_delivery_at));
    setReceivedBy(delivery?.received_by_name ?? "");
    setReceivedAt(
      toDateTimeLocal(delivery?.received_at) || toDateTimeLocal(new Date().toISOString()),
    );
    setNote(delivery?.delivery_note ?? "");
    setEditing(mode);
  };

  const save = async () => {
    setSaving(true);
    const result =
      editing === "dispatch"
        ? await rpc("record_order_dispatch_details", {
            p_order_id: orderId,
            p_driver_name: driverName.trim() || null,
            p_driver_phone: driverPhone.trim() || null,
            p_reference: reference.trim() || null,
            p_expected_at: expected ? new Date(expected).toISOString() : null,
          })
        : await rpc("record_order_proof_of_delivery", {
            p_order_id: orderId,
            p_received_by: receivedBy.trim(),
            p_received_at: receivedAt ? new Date(receivedAt).toISOString() : null,
            p_note: note.trim() || null,
          });
    setSaving(false);
    if (result.error)
      return toast.error(result.error.message || "We couldn't save the delivery details.");
    toast.success(editing === "dispatch" ? "Delivery details saved." : "Proof of delivery saved.");
    setEditing(null);
    void load();
  };

  const showDispatchButton = side === "wholesaler" && canEdit && canRecordDispatch(status);
  const showProofButton = side === "wholesaler" && canEdit && canRecordProof(status);
  const nothingToShow =
    !loading &&
    !error &&
    !hasDispatchDetails(delivery) &&
    !hasProof(delivery) &&
    !showDispatchButton &&
    !showProofButton;
  if (nothingToShow) return null;

  return (
    <section className="mt-4 rounded-xl border border-border p-3 text-sm" aria-label="Delivery">
      <h4 className="font-semibold">Delivery</h4>
      {loading ? (
        <p className="mt-2 text-muted-foreground" role="status">
          Loading delivery details...
        </p>
      ) : error ? (
        <p role="alert" className="mt-2">
          We couldn&apos;t load the delivery details.{" "}
          <button type="button" className="text-primary underline" onClick={() => void load()}>
            Try again
          </button>
        </p>
      ) : editing ? (
        <div className="mt-3 space-y-3">
          {editing === "dispatch" ? (
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Driver / rider name">
                <Input
                  value={driverName}
                  maxLength={100}
                  onChange={(event) => setDriverName(event.target.value)}
                />
              </Field>
              <Field label="Driver phone">
                <Input
                  value={driverPhone}
                  maxLength={30}
                  inputMode="tel"
                  onChange={(event) => setDriverPhone(event.target.value)}
                />
              </Field>
              <Field label="Delivery reference">
                <Input
                  value={reference}
                  maxLength={60}
                  onChange={(event) => setReference(event.target.value)}
                />
              </Field>
              <Field label="Expected delivery">
                <Input
                  type="datetime-local"
                  value={expected}
                  onChange={(event) => setExpected(event.target.value)}
                />
              </Field>
            </div>
          ) : (
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Received by (name)">
                <Input
                  value={receivedBy}
                  maxLength={100}
                  onChange={(event) => setReceivedBy(event.target.value)}
                />
              </Field>
              <Field label="Received at">
                <Input
                  type="datetime-local"
                  value={receivedAt}
                  onChange={(event) => setReceivedAt(event.target.value)}
                />
              </Field>
              <div className="sm:col-span-2">
                <Field label="Note (optional)">
                  <Textarea
                    value={note}
                    maxLength={500}
                    onChange={(event) => setNote(event.target.value)}
                  />
                </Field>
              </div>
            </div>
          )}
          <div className="flex gap-2">
            <Button size="sm" variant="hero" disabled={saving} onClick={() => void save()}>
              {saving ? "Saving..." : "Save"}
            </Button>
            <Button size="sm" variant="outline" disabled={saving} onClick={() => setEditing(null)}>
              Cancel
            </Button>
          </div>
        </div>
      ) : (
        <div className="mt-2 space-y-2">
          {hasDispatchDetails(delivery) && (
            <dl className="grid gap-x-6 gap-y-1 sm:grid-cols-2">
              {delivery?.driver_name && (
                <div>
                  <dt className="text-muted-foreground">Driver</dt>
                  <dd>{delivery.driver_name}</dd>
                </div>
              )}
              {delivery?.driver_phone && (
                <div>
                  <dt className="text-muted-foreground">Driver phone</dt>
                  <dd>
                    <a
                      className="text-primary underline"
                      href={`tel:${delivery.driver_phone.replace(/[^0-9+]/g, "")}`}
                    >
                      {delivery.driver_phone}
                    </a>
                  </dd>
                </div>
              )}
              {delivery?.delivery_reference && (
                <div>
                  <dt className="text-muted-foreground">Reference</dt>
                  <dd>{delivery.delivery_reference}</dd>
                </div>
              )}
              {delivery?.expected_delivery_at && (
                <div>
                  <dt className="text-muted-foreground">Expected</dt>
                  <dd>{formatReportDateTime(delivery.expected_delivery_at)}</dd>
                </div>
              )}
            </dl>
          )}
          {hasProof(delivery) && (
            <p>
              <span className="text-muted-foreground">Delivered to </span>
              <span className="font-medium">{delivery?.received_by_name}</span>
              <span className="text-muted-foreground">
                {" "}
                · received {formatReportDateTime(delivery?.received_at)}
              </span>
              {delivery?.delivery_note && (
                <span className="block text-muted-foreground">{delivery.delivery_note}</span>
              )}
            </p>
          )}
          {!hasDispatchDetails(delivery) && !hasProof(delivery) && (
            <p className="text-muted-foreground">No delivery details recorded yet.</p>
          )}
          {(showDispatchButton || showProofButton) && (
            <div className="flex flex-wrap gap-2">
              {showDispatchButton && (
                <Button size="sm" variant="outline" onClick={() => startEditing("dispatch")}>
                  {hasDispatchDetails(delivery) ? "Edit delivery details" : "Add delivery details"}
                </Button>
              )}
              {showProofButton && (
                <Button size="sm" variant="outline" onClick={() => startEditing("proof")}>
                  {hasProof(delivery) ? "Edit proof of delivery" : "Record proof of delivery"}
                </Button>
              )}
            </div>
          )}
        </div>
      )}
    </section>
  );
}
