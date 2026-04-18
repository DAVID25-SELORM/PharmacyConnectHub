# Pharmacy Connect Hub MVP

A simple B2B pharmacy ordering platform prototype for wholesalers and retail pharmacies.

## Features

- Multi-wholesaler product catalog
- Multi-wholesaler price comparison by medicine
- Supplier quote request and bidding workflow
- Line-item quote breakdown before acceptance
- Order confirmation summary with printable request details
- Fulfillment lifecycle tracking (Accepted > Processing > Dispatched > Delivered)
- Admin workspace for wholesaler onboarding and product publishing
- Role-based login gates for pharmacy, supplier, and admin dashboards
- Supplier dashboard for quote submission
- Persistent order request storage in `data.json`
- Order request history and quote acceptance

## Run locally

1. Install dependencies:
   ```bash
   npm install
   ```
2. Start the backend and frontend together:
   ```bash
   npm run dev
   ```
3. Open `http://localhost:5173`

## Optional commands

- Run frontend only:
   ```bash
   npm run dev:web
   ```
- Run API only:
   ```bash
   npm run dev:api
   ```

## Demo login accounts

- Admin: `admin@pharmacyconnecthub.com` / `demo123`
- Supplier: `supplier@pharmacyconnecthub.com` / `demo123`
- Pharmacy: `pharmacy@pharmacyconnecthub.com` / `demo123`

## Notes

- The backend runs on `http://localhost:4000`
- API routes are proxied by Vite to simplify local development
- Data is persisted to `data.json` for the prototype
