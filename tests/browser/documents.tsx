import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import { OrderPrintActions } from "../../src/components/order-print";
import "../../src/styles.css";
function Fixture() {
  const [count, setCount] = useState(5);
  return (
    <main>
      <div className="no-print">
        <h1>A4 document verification - synthetic data only</h1>
        <label>
          Product count{" "}
          <select value={count} onChange={(e) => setCount(Number(e.target.value))}>
            {[1, 5, 20, 50, 100].map((n) => (
              <option key={n}>{n}</option>
            ))}
          </select>
        </label>
      </div>
      <OrderPrintActions
        wholesaler
        order={{
          order_number: "QA-INVOICE-001",
          created_at: "2026-10-12",
          status: "delivered",
          payment_status: "unpaid",
          payment_method: "cod",
          total_ghs: count * 12.5,
          subtotal_ghs: count * 12.5,
          delivery_fee_ghs: 0,
          pharmacy: { name: "Example Pharmacy", address: "Recorded customer address" },
          wholesaler: {
            name: "Example Distribution Limited",
            address: "Recorded supplier address, Accra",
            phone: "000 000 0000",
            branding: { footer_note: "Thank you for your business." },
          },
          order_items: Array.from({ length: count }, (_, i) => ({
            product_name: `Item ${String(i + 1).padStart(3, "0")} - Long pharmaceutical product name for layout verification`,
            strength: "300 mg",
            form: "Tablet",
            pack_size: "100 tablets",
            quantity: 1,
            unit_price_ghs: 12.5,
          })),
        }}
      />
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<Fixture />);
