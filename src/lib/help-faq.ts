export type HelpRole = "pharmacy" | "wholesaler" | "admin";
export type HelpCategory =
  | "getting-started"
  | "orders"
  | "payments"
  | "receipts"
  | "fulfilment"
  | "inventory"
  | "account"
  | "credit"
  | "returns"
  | "quotations"
  | "reports"
  | "administration";

export const helpCategories: Array<{ id: HelpCategory; label: string }> = [
  { id: "getting-started", label: "Getting Started" },
  { id: "orders", label: "Orders" },
  { id: "payments", label: "Payments" },
  { id: "receipts", label: "Receipts" },
  { id: "fulfilment", label: "Delivery & Fulfilment" },
  { id: "inventory", label: "Inventory" },
  { id: "account", label: "Account & Security" },
  { id: "credit", label: "Credit Accounts" },
  { id: "returns", label: "Returns" },
  { id: "quotations", label: "Quotations" },
  { id: "reports", label: "Reports & Statements" },
  { id: "administration", label: "Platform Administration" },
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
  {
    id: "pharmacy-representatives",
    category: "account",
    roles: ["pharmacy"],
    question: "How do I manage supplier and medical representatives?",
    answer:
      "Pharmacy owners and managers can open Contacts / CRM to add representatives, link companies and products, record visits or calls, and schedule follow-ups. You can mark follow-ups completed and export filtered contacts to Excel or PDF. Records and their activity history are private to your pharmacy's owners and managers. Archive keeps history. Samples recorded in a visit do not change inventory, and follow-ups do not send external messages.",
    keywords: ["CRM", "representatives", "contacts", "visits", "follow-ups", "companies"],
  },
  {
    id: "register",
    category: "getting-started",
    roles: ["all"],
    question: "How do I register my business?",
    answer:
      "Create an account, choose Pharmacy or Wholesaler, complete your business profile and submit the requested verification details. Access is enabled after review.",
    keywords: ["signup", "onboarding", "verification"],
  },
  {
    id: "pending-approval",
    category: "getting-started",
    roles: ["all"],
    question: "Why is my account still pending approval?",
    answer:
      "Business documents and profile details may still be under review. Keep your contact details up to date and contact support if the status remains pending longer than expected.",
    keywords: ["approval", "documents", "pending"],
  },
  {
    id: "required-documents",
    category: "getting-started",
    roles: ["all"],
    question: "What documents are required for verification?",
    answer:
      "Pharmacies upload a Pharmacy Council License and Business Registration. Wholesalers upload a Wholesale Pharmacy License, FDA Certificate and Business Registration. Upload them from the Verification page after you sign in.",
    keywords: ["documents", "licence", "license", "upload"],
  },
  {
    id: "rejected-verification",
    category: "getting-started",
    roles: ["all"],
    question: "Why was my verification rejected, and how do I replace a document?",
    answer:
      "Some information or documents need to be updated before your account can be approved. Sign in, open the Verification page, read the review feedback and use Replace on the affected document. Marketplace features stay locked until your business is approved.",
    keywords: ["rejected", "replace", "resubmit", "document"],
  },
  {
    id: "after-approval",
    category: "getting-started",
    roles: ["all"],
    question: "What happens after my business is approved?",
    answer:
      "Your DrugXOne workspace opens the next time you sign in or refresh your verification status. You do not need a new account.",
    keywords: ["approved", "workspace", "access"],
  },
  {
    id: "place-order",
    category: "orders",
    roles: ["pharmacy"],
    question: "How do pharmacies place an order?",
    answer:
      "Browse the catalogue, compare supplier offers and add products to your cart. At checkout, classify each item as NHIS, Cash/private or Other and choose a payment method for each supplier. Review the totals, delivery charges and minimum quantities before placing the order. Orders appear in My orders.",
    keywords: ["cart", "checkout", "buy"],
  },
  {
    id: "order-history",
    category: "orders",
    roles: ["all"],
    question: "Where can I see my previous orders?",
    answer:
      "Open your dashboard and select the Orders or My orders view. Choose an order to see its items, status and available receipt actions.",
    keywords: ["history", "previous"],
  },
  {
    id: "cancel-order",
    category: "orders",
    roles: ["pharmacy"],
    question: "Can I cancel an order?",
    answer:
      "Open the order and use Cancel when it is available. Cancellation is limited to eligible early fulfilment stages; once picking or later fulfilment has started, contact the wholesaler. A submitted return request is a separate process and does not cancel the original order.",
    keywords: ["cancel"],
  },
  {
    id: "order-pending",
    category: "orders",
    roles: ["pharmacy"],
    question: "Why is my order still pending?",
    answer:
      "The wholesaler may still need to accept and process the order. The status timeline will update as fulfilment progresses.",
    keywords: ["pending", "accepted"],
  },
  {
    id: "payment-status",
    category: "payments",
    roles: ["all"],
    question: "How do I know whether my payment was successful?",
    answer:
      "Check the payment status on the order. Choosing cash on delivery, bank transfer, mobile money, cheque or Other does not record a payment. The order remains unpaid until an authorised wholesaler team member records or confirms the payment. Delivery status and payment status are separate.",
    keywords: ["paid", "COD", "cash"],
  },
  {
    id: "receipt-location",
    category: "receipts",
    roles: ["all"],
    question: "Where can I find my receipt?",
    answer:
      "Open Orders, select the relevant order, and use its receipt or print action when available.",
    keywords: ["receipt", "order"],
  },
  {
    id: "receipt-email",
    category: "receipts",
    roles: ["all"],
    question: "What if my receipt email fails?",
    answer:
      "An email delivery failure does not remove the in-app order or receipt. Open the order again to view, print or retry the receipt action when available.",
    keywords: ["receipt", "email", "failed"],
  },
  {
    id: "picking",
    category: "fulfilment",
    roles: ["all"],
    question: "What does Picking mean?",
    answer:
      "The wholesaler is selecting the ordered products from warehouse stock. It does not mean the order has been dispatched yet.",
    keywords: ["picking", "warehouse"],
  },
  {
    id: "packed",
    category: "fulfilment",
    roles: ["all"],
    question: "What does Packed mean?",
    answer: "The products have been picked and prepared for dispatch or pickup.",
    keywords: ["packed"],
  },
  {
    id: "dispatched",
    category: "fulfilment",
    roles: ["all"],
    question: "What does Dispatched mean?",
    answer:
      "The order has left the wholesaler for delivery or pickup. Follow the order timeline for later updates.",
    keywords: ["delivery", "dispatched"],
  },
  {
    id: "missing-item",
    category: "fulfilment",
    roles: ["pharmacy"],
    question: "What should I do if an item is missing?",
    answer:
      "Check the delivered items against the order. Use the available return/request action for eligible items and include the affected quantities and reason. Contact the wholesaler with the order reference for shortages or delivery issues; contact platform support if the issue cannot be resolved.",
    keywords: ["missing", "shortage"],
  },
  {
    id: "add-inventory",
    category: "inventory",
    roles: ["wholesaler"],
    question: "How do I add products to my inventory?",
    answer:
      "In the wholesaler dashboard, open My products to add a product manually or import a file or pasted table. Review product names, prices, quantities and any import warnings before saving.",
    keywords: ["products", "stock", "import"],
  },
  {
    id: "locations",
    category: "inventory",
    roles: ["wholesaler"],
    question: "How do warehouse locations work?",
    answer:
      "Warehouse locations use Warehouse, Zone, Rack, Shelf and Bin fields. These optional fields help staff locate products and organise Pick & Pack Sheets.",
    keywords: ["warehouse", "zone", "rack", "shelf", "bin", "pick"],
  },
  {
    id: "forgot-password",
    category: "account",
    roles: ["all"],
    question: "I forgot my password. What should I do?",
    answer:
      "Use the Forgot password link on the sign-in page and follow the email instructions to reset access.",
    keywords: ["password", "reset", "login"],
  },
  {
    id: "staff-access",
    category: "account",
    roles: ["all"],
    question: "Why do I not have access to a feature?",
    answer:
      "Access depends on your organisation, role and permissions. Ask the business owner to confirm your staff access if something is unavailable.",
    keywords: ["staff", "permissions", "access"],
  },
  {
    id: "workspace-switch",
    category: "getting-started",
    roles: ["all"],
    question: "Can I use more than one business workspace?",
    answer:
      "Use the business/workspace selector to switch between businesses you own or have staff access to. Check the active business before ordering, changing stock or recording payments. Business approval and staff permissions apply separately to each workspace.",
    keywords: ["workspace", "switch", "multiple", "organisation"],
  },
  {
    id: "split-orders",
    category: "orders",
    roles: ["pharmacy"],
    question: "Why did one checkout create several orders?",
    answer:
      "A cart containing products from different wholesalers is split into supplier orders under the same purchase. Each supplier has its own payment method, delivery charges, credit account and fulfilment timeline.",
    keywords: ["suppliers", "procurement", "split", "cart"],
  },
  {
    id: "classification",
    category: "orders",
    roles: ["pharmacy"],
    question: "What are NHIS, Cash/private and Other used for?",
    answer:
      "These labels classify why you are buying each item. Choose one for every checkout line. They are separate from the payment method: an NHIS-classified item can still be paid for using an available settlement method.",
    keywords: ["nhis", "classification", "cash private", "category"],
  },
  {
    id: "checkout-changes",
    category: "orders",
    roles: ["pharmacy"],
    question: "Why did checkout reject my cart or change its total?",
    answer:
      "Checkout checks current product availability, stock, minimum quantities, supplier minimum order values, discounts, delivery charges and credit availability. Review the message, update the cart and check the final total before trying again. Saved or displayed estimates do not reserve prices or stock.",
    keywords: ["minimum", "stock", "price", "delivery fee", "discount"],
  },
  {
    id: "checkout-retry",
    category: "orders",
    roles: ["pharmacy"],
    question: "What should I do if checkout times out?",
    answer:
      "Check My orders before starting another purchase. The checkout retry mechanism protects a retry of the same pending submission from creating duplicate orders. Do not assume a timeout means the order failed, and contact support with the order reference if you are unsure.",
    keywords: ["timeout", "retry", "duplicate", "network"],
  },
  {
    id: "saved-carts",
    category: "orders",
    roles: ["pharmacy"],
    question: "How do saved carts and reorder lists work?",
    answer:
      "Use the cart saving and Reorder lists controls to keep items for a later purchase. When you resume or reorder, review current availability, quantities and prices before checkout. Saving a list or cart does not place an order or reserve stock.",
    keywords: ["saved cart", "reorder", "list", "repeat"],
  },
  {
    id: "payment-methods",
    category: "payments",
    roles: ["all"],
    question: "Which payment methods are supported?",
    answer:
      "Checkout offers cash on delivery, bank transfer, mobile money, cheque and Other. Credit requires a usable supplier credit account. Pay now (online) is disabled because online payment collection is not available. Arrange offline payment details with the supplier.",
    keywords: ["momo", "bank transfer", "cheque", "pay now", "online"],
  },
  {
    id: "change-payment",
    category: "payments",
    roles: ["pharmacy"],
    question: "Can I change the payment method after ordering?",
    answer:
      "Use the payment-method change action when the order allows it. Eligible unpaid, non-credit orders can switch between supported offline methods before delivery or cancellation. This action cannot turn an existing order into a credit order or mark it paid.",
    keywords: ["settlement", "change method", "unpaid"],
  },
  {
    id: "record-credit-payment",
    category: "payments",
    roles: ["wholesaler"],
    question: "How do I record a payment against credit invoices?",
    answer:
      "Open Credit and use Record a payment. Select the pharmacy, enter the amount and payment details, and allocate the payment to the appropriate invoices using the form. Only authorised finance roles can record payments. Record money actually received; saving a record does not transfer funds.",
    keywords: ["partial", "allocation", "record payment", "invoice"],
  },
  {
    id: "partial-payment",
    category: "payments",
    roles: ["all"],
    question: "Does a partial payment free up credit?",
    answer:
      "Recorded credit payments reduce the ledger balance, including partial payments. Available credit is calculated from the approved limit and current ledger exposure. Refresh credit status after a payment has been recorded; an unrecorded bank transfer does not change the displayed balance.",
    keywords: ["partial", "ledger", "available", "balance"],
  },
  {
    id: "credit-direct",
    category: "credit",
    roles: ["wholesaler"],
    question: "How do I choose pharmacies as credit clients?",
    answer:
      "Wholesaler owners and managers can open Credit ? Credit clients, choose a verified pharmacy, set a total credit limit in GHS and payment terms in days, and select Approve credit client. Approval applies only to that pharmacy?s purchases from your business. An internal note is optional.",
    keywords: ["approve", "client", "pharmacy", "limit", "terms"],
  },
  {
    id: "credit-eligibility",
    category: "credit",
    roles: ["pharmacy"],
    question: "Why can I see Credit but not select it?",
    answer:
      "Credit is visible even when unavailable. The explanation shows whether you need supplier approval, have insufficient available credit, or have a suspended or blocked account. Platform permission to request credit does not itself approve borrowing.",
    keywords: ["disabled", "missing credit", "approval", "not available"],
  },
  {
    id: "credit-request",
    category: "credit",
    roles: ["pharmacy"],
    question: "How do I request an ongoing credit account?",
    answer:
      "If the platform admin has enabled credit requests for your pharmacy, an owner or manager can use Request an ongoing credit account in the checkout supplier section. Enter the total limit you want and submit. The supplier decides whether to approve it and sets the final limit and payment days.",
    keywords: ["request", "ongoing", "west point", "apply"],
  },
  {
    id: "credit-request-not-order",
    category: "credit",
    roles: ["all"],
    question: "Does requesting or approving credit place an order?",
    answer:
      "No. A credit request is an application for an ongoing account, not an order. It does not reserve stock, charge the pharmacy or create an invoice. After approval, the pharmacy refreshes credit status, selects Credit and places its order. Stock, prices and available credit are checked at checkout.",
    keywords: ["pending", "stock", "reservation", "invoice", "order"],
  },
  {
    id: "credit-review",
    category: "credit",
    roles: ["wholesaler"],
    question: "How do I accept or reject a credit account request?",
    answer:
      "Owners and managers open Credit ? Credit account requests. Review the pharmacy?s outstanding balance and payment history, enter the approved total limit and payment days, and provide a reason shared with the pharmacy. Choose Approve ongoing account or Reject request. The new limit replaces an existing limit; rejection leaves existing terms unchanged.",
    keywords: ["accept", "reject", "reason", "approve", "request"],
  },
  {
    id: "credit-approved",
    category: "credit",
    roles: ["pharmacy"],
    question: "What happens after my credit request is approved?",
    answer:
      "You receive a notification. At checkout, use Refresh credit status, then select Credit if the order fits within your available balance. The account is ongoing, so later orders within the available limit do not need another account application. Each order still follows the supplier?s normal order acceptance process.",
    keywords: ["notification", "refresh", "approved", "ongoing"],
  },
  {
    id: "credit-increase",
    category: "credit",
    roles: ["pharmacy"],
    question: "Can I request a higher credit limit?",
    answer:
      "When requests are enabled for your pharmacy, use the checkout credit request form to ask for a new total limit. Enter the total account limit you want, not just the extra amount. The supplier may approve a different limit or reject the request. Suspended and blocked accounts must be discussed with the supplier directly.",
    keywords: ["increase", "over limit", "total limit"],
  },
  {
    id: "credit-expiry",
    category: "credit",
    roles: ["all"],
    question: "How long does a credit request remain pending?",
    answer:
      "Requests expire after seven days. An expired request cannot be approved. An eligible pharmacy can submit again; a repeat submission while a request is still pending returns the existing request. Use the refresh controls to check the latest status and decision reason.",
    keywords: ["expiry", "seven days", "duplicate", "pending"],
  },
  {
    id: "credit-edit",
    category: "credit",
    roles: ["wholesaler"],
    question: "How do I change a client?s credit terms?",
    answer:
      "Open Credit ? Credit clients and select Edit terms, or choose the existing client in the pharmacy selector. Update the limit, payment days or internal note and save. Changing account terms does not rewrite the agreed payment-term snapshot on existing credit orders.",
    keywords: ["edit", "terms", "due date", "snapshot"],
  },
  {
    id: "credit-restrictions",
    category: "credit",
    roles: ["all"],
    question: "What do suspended, blocked and revoked credit mean?",
    answer:
      "Suspended and blocked accounts cannot place new credit orders; existing invoices stay payable. A wholesaler owner or manager can reactivate the account with a reason. Revoking closes the credit line for new orders. A request for credit cannot override a suspended or blocked status.",
    keywords: ["suspend", "block", "revoke", "reactivate"],
  },
  {
    id: "credit-cancel-balance",
    category: "credit",
    roles: ["all"],
    question: "What happens to credit when a partially paid credit order is cancelled?",
    answer:
      "An eligible cancellation releases the invoice charges through the credit ledger. Amounts already paid remain as pharmacy account credit with that supplier, rather than being automatically refunded. Check the ledger or statement and contact the supplier if you need to discuss repayment.",
    keywords: ["cancel", "partially paid", "account credit", "refund"],
  },
  {
    id: "credit-overdue",
    category: "credit",
    roles: ["all"],
    question: "Where do I see outstanding and overdue credit?",
    answer:
      "Open Credit. Pharmacies see accounts payable and credit invoices; wholesalers see accounts receivable and credit invoices. Use invoice balances, due dates and ageing information to follow up. An overdue invoice is still payable and is separate from order fulfilment status.",
    keywords: ["overdue", "ageing", "aging", "payable", "receivable"],
  },
  {
    id: "credit-corrections",
    category: "credit",
    roles: ["wholesaler"],
    question: "How should incorrect credit entries or disputed invoices be handled?",
    answer:
      "Use the available adjustment, reversal or dispute controls in Credit, subject to your role, and record a clear reason. Review the invoice and ledger before changing anything. Cancellation credits cannot be reversed through the normal reversal action. Contact support if the available controls cannot resolve the issue.",
    keywords: ["adjustment", "reversal", "dispute", "write off", "credit note"],
  },
  {
    id: "receipt-payment",
    category: "receipts",
    roles: ["all"],
    question: "Does a receipt or printed order prove payment?",
    answer:
      "Check the payment status and recorded payments alongside the document. Creating, viewing, printing or emailing an order document does not collect money or change the payment status.",
    keywords: ["print", "receipt", "proof", "paid"],
  },
  {
    id: "fulfilment-flow",
    category: "fulfilment",
    roles: ["all"],
    question: "How does an order move through fulfilment?",
    answer:
      "The normal timeline is Pending, Accepted, Picking, Packed, Ready for dispatch, Dispatched and Delivered. Authorised wholesaler staff update the available actions at each stage. Delivered describes fulfilment; it does not automatically mean the order has been paid.",
    keywords: ["timeline", "accepted", "ready for dispatch", "delivered"],
  },
  {
    id: "pick-pack",
    category: "fulfilment",
    roles: ["wholesaler"],
    question: "How do I prepare a Pick & Pack Sheet?",
    answer:
      "Open an order and use the available Pick & Pack print action. Check quantities and warehouse locations while picking, then update the order?s fulfilment stage as work is completed. Printing a sheet does not update stock or mark the order delivered.",
    keywords: ["pick sheet", "pack", "print", "warehouse"],
  },
  {
    id: "request-return",
    category: "returns",
    roles: ["pharmacy"],
    question: "How do I request a return?",
    answer:
      "Use the available return action for an eligible order, select the affected items and quantities, and provide the reason. Track the request in Returns. You can cancel an unreviewed request where that action is available. A return requires supplier review.",
    keywords: ["return", "damaged", "wrong item", "quantity"],
  },
  {
    id: "review-return",
    category: "returns",
    roles: ["wholesaler"],
    question: "How do wholesalers process returns?",
    answer:
      "Open Returns to review the request, inspect returned items and resolve the accepted quantities. Record the inspection outcome and whether accepted items should return to stock. Available resolutions include refund, account credit, replacement, or no action when nothing is accepted.",
    keywords: ["inspect", "review", "restock", "replacement"],
  },
  {
    id: "return-refund",
    category: "returns",
    roles: ["all"],
    question: "Does resolving a return automatically send a refund?",
    answer:
      "No. Refund and credit resolutions appear on the statement, but paying a refund out is handled outside DrugXOne. Agree payment arrangements with the supplier. A replacement resolution does not itself move money.",
    keywords: ["refund", "payout", "statement", "credit"],
  },
  {
    id: "import-products",
    category: "inventory",
    roles: ["wholesaler"],
    question: "Which product import formats can I use?",
    answer:
      "Use CSV, TSV, TXT, Excel (XLSX or XLS), a selectable-text PDF table, or a pasted table. The template headers give the most reliable results. Review the preview and correct warnings before importing; a scanned image PDF may not contain a usable table.",
    keywords: ["csv", "xlsx", "pdf", "excel", "upload", "template"],
  },
  {
    id: "pharmacy-inventory",
    category: "inventory",
    roles: ["pharmacy"],
    question: "Is my pharmacy inventory the same as the marketplace catalogue?",
    answer:
      "No. Your Inventory area tracks your own business?s stock. The marketplace catalogue shows products offered by wholesalers. Use the pharmacy inventory add, import and adjustment controls to maintain your stock records; check the active workspace before saving changes.",
    keywords: ["inventory", "own stock", "catalogue", "import"],
  },
  {
    id: "batches-expiry",
    category: "inventory",
    roles: ["wholesaler"],
    question: "Where do I manage batches and expiry dates?",
    answer:
      "Use Batches for batch records and expiry information, and Stock insights for available inventory summaries. Keep product quantities and batch details accurate. Access to these controls depends on your staff role.",
    keywords: ["batch", "expiry", "stock insights"],
  },
  {
    id: "discounts-delivery",
    category: "orders",
    roles: ["wholesaler"],
    question: "Where do I set discounts, minimum orders and delivery fees?",
    answer:
      "Use Customer discounts to manage order terms and the available product/customer discount controls. Configure minimum order value, delivery fee and free-delivery threshold where applicable. Pharmacies see estimates at checkout; the order is validated against the current terms when submitted.",
    keywords: ["discount", "minimum", "delivery", "free delivery"],
  },
  {
    id: "rfq-pharmacy",
    category: "quotations",
    roles: ["pharmacy"],
    question: "How do I request quotations from suppliers?",
    answer:
      "Open Requests for quotation, create your item list and choose the suppliers you want to approach. Review the returned quotations and compare the offers before using the available acceptance action. Follow the confirmation shown in the quotation workflow.",
    keywords: ["rfq", "quote", "compare", "supplier"],
  },
  {
    id: "rfq-wholesaler",
    category: "quotations",
    roles: ["wholesaler"],
    question: "Where do I respond to requests for quotation?",
    answer:
      "Open Requests for quotation to view requests available to your business. Open the request, review the requested items and submit your offer using the quotation form. Follow the request status and any deadlines shown.",
    keywords: ["rfq", "offer", "quote", "respond"],
  },
  {
    id: "statements",
    category: "reports",
    roles: ["pharmacy"],
    question: "Where can I view supplier statements?",
    answer:
      "Open Statements in your pharmacy workspace, select the supplier and period, and review the entries and balances. Use the available export or print actions. A statement records activity; it does not itself pay an invoice.",
    keywords: ["statement", "balance", "export", "print"],
  },
  {
    id: "reports",
    category: "reports",
    roles: ["all"],
    question: "How do I use reports and exports?",
    answer:
      "Open Reports from your workspace navigation and choose the available date range and filters. Check the active business, period and report definition before comparing figures or exporting. Access and report options depend on your role.",
    keywords: ["reports", "export", "date range", "analytics"],
  },
  {
    id: "audit",
    category: "reports",
    roles: ["all"],
    question: "Where can I trace changes made by staff?",
    answer:
      "Use the Audit log in your business workspace if your role permits access. Filter the activity and open an entry to inspect the recorded actor, time and change details. Platform admins use Activity for platform-level review.",
    keywords: ["audit", "actor", "activity", "history"],
  },
  {
    id: "team",
    category: "account",
    roles: ["all"],
    question: "How do I add or change team access?",
    answer:
      "An authorised business administrator can use the team/staff area to add team members and manage the available roles and access controls. Choose the correct business workspace and the least access needed for the person?s work. Platform Team is separate from business staff.",
    keywords: ["staff", "team", "roles", "invite"],
  },
  {
    id: "role-differences",
    category: "account",
    roles: ["all"],
    question: "Why can one staff member approve credit while another can only record payments?",
    answer:
      "Permissions are role-specific. Credit account approval, limits and status changes are restricted to owners and managers. Payment recording is available to authorised finance roles. Warehouse fulfilment access does not grant credit approval or payment permissions.",
    keywords: ["manager", "owner", "finance", "accountant", "warehouse"],
  },
  {
    id: "notifications",
    category: "account",
    roles: ["all"],
    question: "Where do I find updates about requests and orders?",
    answer:
      "Open Notifications and follow the relevant entry to the workspace. Credit request decisions include the supplier?s reason. If a screen is already open, use its refresh action or reload to see recent changes. Only users with access to the relevant business can act on its records.",
    keywords: ["notifications", "refresh", "updates"],
  },
  {
    id: "admin-verify",
    category: "administration",
    roles: ["admin"],
    question: "How do I approve or reject a business?",
    answer:
      "Open Admin ? Verification or the relevant business card. Review the business information and required documents before approving. When rejecting or revoking approval, give clear feedback so the business knows what to correct. Verification approval is separate from supplier credit approval.",
    keywords: ["verification", "documents", "approve", "reject"],
  },
  {
    id: "admin-credit-enable",
    category: "administration",
    roles: ["admin"],
    question: "How do I enable credit requests for West Point or another pharmacy?",
    answer:
      "Find the verified pharmacy?s approved business card in Admin and select Enable credit requests. Confirm you selected the correct business. This allows its owners and managers to apply to suppliers; it does not grant a credit limit or place an order. Each wholesaler makes its own approval decision.",
    keywords: ["west point", "enable", "eligibility", "credit"],
  },
  {
    id: "admin-credit-disable",
    category: "administration",
    roles: ["admin"],
    question: "What happens when I disable credit requests?",
    answer:
      "Disabling eligibility prevents new requests and approval of pending requests for that pharmacy. It does not revoke ongoing supplier credit accounts or cancel existing invoices. Wholesalers manage their own account restrictions and limits.",
    keywords: ["disable", "eligibility", "pending", "existing accounts"],
  },
  {
    id: "admin-team",
    category: "administration",
    roles: ["admin"],
    question: "How is Platform Team different from business staff?",
    answer:
      "Admin ? Platform Team manages platform-level team access. A business?s staff area controls access within that pharmacy or wholesaler. Grant each person the appropriate scope; belonging to a business does not automatically make them a platform administrator.",
    keywords: ["platform team", "staff", "admin", "permissions"],
  },
  {
    id: "admin-monitor",
    category: "administration",
    roles: ["admin"],
    question: "Where can I review platform activity and reports?",
    answer:
      "Use Admin ? Activity to inspect recorded platform actions and Admin ? Reports for the available reporting views. Apply the relevant filters and check the reporting period before drawing conclusions or following up on a business.",
    keywords: ["activity", "reports", "monitor", "platform"],
  },
  {
    id: "support-details",
    category: "account",
    roles: ["all"],
    question: "What information should I include when asking for support?",
    answer:
      "Include the business name, order or request reference, the action you tried and the exact error message. A screenshot can help, but hide private customer details. Never send your password, one-time sign-in code or secret API keys.",
    keywords: ["support", "error", "screenshot", "contact"],
  },
  {
    id: "rfq-large-lists",
    category: "quotations",
    roles: ["pharmacy"],
    question: "How do I request quotes for hundreds of medicines?",
    answer:
      "Use the expanded RFQ editor. Import Excel/CSV or paste a table with Medicine, Quantity and optional Notes headers. Search your items and review them in pages of 25; fix highlighted duplicates or invalid quantities. Search suppliers in pages of 20, review your selected suppliers, or choose All eligible suppliers. Save draft on this device preserves progress for your account and pharmacy. Review the item count, recipient count and deadline before confirming submission. A draft is not sent and is not synced to another device.",
    keywords: ["bulk", "rfq", "import", "draft", "pagination", "suppliers"],
  },
];
