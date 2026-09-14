import { useRef, useState } from "react";
import { Printer, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { supabase } from "@/integrations/supabase/client";
import { useSession } from "@/hooks/use-session";
import { printableOrderSchema, renderOrderPrint } from "@/lib/order-print";

// Fetch fresh private data on each open. Context changes unmount the preview and clear its document.
export function OrderPrintButton({ orderId }: { orderId: string }) {
  const { user, business } = useSession();
  if (!user || !business) return null;
  return (
    <ScopedOrderPrint
      key={`${user.id}:${business.id}:${orderId}`}
      orderId={orderId}
      businessId={business.id}
    />
  );
}

function ScopedOrderPrint({ orderId, businessId }: { orderId: string; businessId: string }) {
  const [html, setHtml] = useState("");
  const [loading, setLoading] = useState(false);
  const [ready, setReady] = useState(false);
  const frame = useRef<HTMLIFrameElement>(null);
  async function openPreview() {
    setLoading(true);
    setReady(false);
    try {
      const { data, error } = await supabase.rpc("get_order_print", {
        _business_id: businessId,
        _order_id: orderId,
      });
      if (error)
        throw new Error("This order is not available for printing in your current workspace.");
      setHtml(renderOrderPrint(printableOrderSchema.parse(data)));
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Unable to load this order.");
    } finally {
      setLoading(false);
    }
  }
  return (
    <>
      <Button variant="outline" size="sm" disabled={loading} onClick={() => void openPreview()}>
        {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Printer className="h-4 w-4" />}{" "}
        Print Order
      </Button>
      <Dialog
        open={Boolean(html)}
        onOpenChange={(open) => {
          if (!open) {
            setHtml("");
            setReady(false);
          }
        }}
      >
        <DialogContent className="max-w-4xl">
          <DialogHeader>
            <DialogTitle>Print Order</DialogTitle>
            <DialogDescription>
              Review the order, then print or save it as a PDF. Printing does not change the order.
            </DialogDescription>
          </DialogHeader>
          <iframe
            ref={frame}
            title="DrugXone order print preview"
            srcDoc={html}
            sandbox="allow-same-origin allow-modals"
            referrerPolicy="no-referrer"
            className="h-[65vh] w-full rounded border bg-white"
            onLoad={() => setReady(true)}
          />
          <Button
            disabled={!ready}
            onClick={() => {
              frame.current?.contentWindow?.focus();
              frame.current?.contentWindow?.print();
            }}
          >
            <Printer className="h-4 w-4" /> Print / Save PDF
          </Button>
        </DialogContent>
      </Dialog>
    </>
  );
}
