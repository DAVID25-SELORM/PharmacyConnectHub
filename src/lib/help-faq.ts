export type HelpRole = "pharmacy" | "wholesaler";
export type HelpCategory =
  | "getting-started"
  | "orders"
  | "payments"
  | "receipts"
  | "fulfilment"
  | "inventory"
  | "account";

export const helpCategories: Array<{ id: HelpCategory; label: string }> = [
  { id: "getting-started", label: "Getting Started" },
  { id: "orders", label: "Orders" },
  { id: "payments", label: "Payments" },
  { id: "receipts", label: "Receipts" },
  { id: "fulfilment", label: "Delivery & Fulfilment" },
  { id: "inventory", label: "Inventory" },
  { id: "account", label: "Account & Security" },
];

export type HelpFaq = {
  id: string;
  category: HelpCategory;
  roles: Array<HelpRole | "all">;
  question: string;
  answer: string;
  keywords: string[];
};

export const helpFaqs: HelpFaq[] = [
  { id: "register", category: "getting-started", roles: ["all"], question: "How do I register my business?", answer: "Create an account, choose Pharmacy or Wholesaler, complete your business profile and submit the requested verification details. Access is enabled after review.", keywords: ["signup", "onboarding", "verification"] },
  { id: "pending-approval", category: "getting-started", roles: ["all"], question: "Why is my account still pending approval?", answer: "Business documents and profile details may still be under review. Keep your contact details up to date and contact support if the status remains pending longer than expected.", keywords: ["approval", "documents", "pending"] },
  { id: "place-order", category: "orders", roles: ["pharmacy"], question: "How do pharmacies place an order?", answer: "Browse the catalogue, compare available wholesaler offers, add products to your cart and complete checkout. Your order then appears in Orders with its fulfilment timeline.", keywords: ["cart", "checkout", "buy"] },
  { id: "order-history", category: "orders", roles: ["all"], question: "Where can I see my previous orders?", answer: "Open your dashboard and select the Orders or My orders view. Choose an order to see its items, status and available receipt actions.", keywords: ["history", "previous"] },
  { id: "cancel-order", category: "orders", roles: ["pharmacy"], question: "Can I cancel an order?", answer: "Cancellation depends on the order's current fulfilment stage and the available action on the order. Contact the wholesaler promptly if cancellation is urgent.", keywords: ["cancel"] },
  { id: "order-pending", category: "orders", roles: ["pharmacy"], question: "Why is my order still pending?", answer: "The wholesaler may still need to accept and process the order. The status timeline will update as fulfilment progresses.", keywords: ["pending", "accepted"] },
  { id: "payment-status", category: "payments", roles: ["all"], question: "How do I know whether my payment was successful?", answer: "Check the payment status shown on the order. For cash on delivery, payment may remain pending until the wholesaler confirms receipt.", keywords: ["paid", "COD", "cash"] },
  { id: "receipt-location", category: "receipts", roles: ["all"], question: "Where can I find my receipt?", answer: "Open Orders, select the relevant order, and use its receipt or print action when available.", keywords: ["receipt", "order"] },
  { id: "receipt-email", category: "receipts", roles: ["all"], question: "What if my receipt email fails?", answer: "An email delivery failure does not remove the in-app order or receipt. Open the order again to view, print or retry the receipt action when available.", keywords: ["receipt", "email", "failed"] },
  { id: "picking", category: "fulfilment", roles: ["all"], question: "What does Picking mean?", answer: "The wholesaler is selecting the ordered products from warehouse stock. It does not mean the order has been dispatched yet.", keywords: ["picking", "warehouse"] },
  { id: "packed", category: "fulfilment", roles: ["all"], question: "What does Packed mean?", answer: "The products have been picked and prepared for dispatch or pickup.", keywords: ["packed"] },
  { id: "dispatched", category: "fulfilment", roles: ["all"], question: "What does Dispatched mean?", answer: "The order has left the wholesaler for delivery or pickup. Follow the order timeline for later updates.", keywords: ["delivery", "dispatched"] },
  { id: "missing-item", category: "fulfilment", roles: ["pharmacy"], question: "What should I do if an item is missing?", answer: "Contact the wholesaler using the order reference and contact Drugxone support if the issue cannot be resolved.", keywords: ["missing", "shortage"] },
  { id: "add-inventory", category: "inventory", roles: ["wholesaler"], question: "How do I add products to my inventory?", answer: "Open the Inventory area in the wholesaler dashboard and add or import your product listings there.", keywords: ["products", "stock", "import"] },
  { id: "locations", category: "inventory", roles: ["wholesaler"], question: "How do warehouse locations work?", answer: "Locations are arranged as Warehouse → Zone → Rack → Shelf → Bin. They are optional and help staff sort Pick & Pack Sheets efficiently.", keywords: ["warehouse", "zone", "rack", "shelf", "bin", "pick"] },
  { id: "forgot-password", category: "account", roles: ["all"], question: "I forgot my password. What should I do?", answer: "Use the Forgot password link on the sign-in page and follow the email instructions to reset access.", keywords: ["password", "reset", "login"] },
  { id: "staff-access", category: "account", roles: ["all"], question: "Why do I not have access to a feature?", answer: "Access depends on your organisation, role and permissions. Ask the business owner to confirm your staff access if something is unavailable.", keywords: ["staff", "permissions", "access"] },
];
