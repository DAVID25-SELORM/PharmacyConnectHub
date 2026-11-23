import { useCallback, useEffect, useState } from "react";
import { Database } from "lucide-react";
import { toast } from "sonner";
import { Link } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { confirmAction } from "@/lib/confirm-action";
import {
  REQUEST_KIND_LABEL,
  REQUEST_STATUS_LABEL,
  downloadTextFile,
  exportFilename,
  exportMyData,
  listMyDataRequests,
  requestDataAction,
  type MyDataRequest,
} from "@/lib/privacy";

/** Download everything held about you, or ask for it to be deleted. */
export function YourDataCard() {
  const [requests, setRequests] = useState<MyDataRequest[]>([]);
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState("");

  const load = useCallback(async () => setRequests(await listMyDataRequests()), []);
  useEffect(() => {
    void load();
  }, [load]);

  const download = async () => {
    setBusy(true);
    const result = await exportMyData();
    setBusy(false);
    if (!result.ok) {
      toast.error(result.message);
      return;
    }
    downloadTextFile(exportFilename(), result.json);
    toast.success("Your data was downloaded.");
  };

  const askToDelete = async () => {
    const ok = await confirmAction(
      "Ask Drugxone to delete your personal data? Your sign-in will stop working once it is done. Business records the law requires us to keep stay, without your name.",
    );
    if (!ok) return;
    setBusy(true);
    const message = await requestDataAction("deletion", reason);
    setBusy(false);
    if (message) {
      toast.error(message);
      return;
    }
    setReason("");
    toast.success("Request received. We will reply within 30 days.");
    await load();
  };

  const openDeletion = requests.some(
    (r) => r.kind === "deletion" && (r.status === "open" || r.status === "in_progress"),
  );

  return (
    <Card className="space-y-4 p-5">
      <div className="flex items-start gap-3">
        <Database className="mt-0.5 h-5 w-5 text-muted-foreground" aria-hidden="true" />
        <div>
          <h2 className="font-semibold">Your data</h2>
          <p className="text-sm text-muted-foreground">
            See what we hold about you, or ask us to delete it. Read how we use it in the{" "}
            <Link to="/privacy" className="text-primary underline">
              Privacy Notice
            </Link>
            .
          </p>
        </div>
      </div>

      <div>
        <Button variant="outline" disabled={busy} onClick={() => void download()}>
          Download my data
        </Button>
        <p className="mt-1 text-xs text-muted-foreground">
          A file with your account, profile, businesses you own, staff memberships and the privacy
          choices you made.
        </p>
      </div>

      <div className="space-y-2 border-t pt-4">
        <Label htmlFor="delete-reason">Delete my data</Label>
        <Textarea
          id="delete-reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Optional: tell us why"
          maxLength={1000}
          disabled={openDeletion}
          rows={2}
        />
        <Button
          variant="outline"
          disabled={busy || openDeletion}
          onClick={() => void askToDelete()}
        >
          {openDeletion ? "Deletion request in progress" : "Ask for my data to be deleted"}
        </Button>
        <p className="text-xs text-muted-foreground">
          If you own a business, it has to be handed over or closed first. Records the law requires
          us to keep (such as invoices) stay, without your name.
        </p>
      </div>

      {requests.length > 0 && (
        <div className="space-y-2 border-t pt-4">
          <h3 className="text-sm font-medium">Your requests</h3>
          <ul className="space-y-2 text-sm">
            {requests.map((request) => (
              <li key={request.id} className="rounded-md border px-3 py-2">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span>{REQUEST_KIND_LABEL[request.kind]}</span>
                  <span className="text-xs font-medium">
                    {REQUEST_STATUS_LABEL[request.status]}
                  </span>
                </div>
                <p className="text-xs text-muted-foreground">
                  Sent {new Date(request.created_at).toLocaleDateString()}
                </p>
                {request.resolution_note && (
                  <p className="mt-1 text-xs">{request.resolution_note}</p>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}
    </Card>
  );
}
