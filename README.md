# Pharmacy Connect Hub MVP

A simple B2B pharmacy ordering platform prototype for wholesalers and retail pharmacies.

## Features

- Multi-wholesaler product catalog
- Supplier quote request and bidding workflow
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

## Notes

- The backend runs on `http://localhost:4000`
- API routes are proxied by Vite to simplify local development
- Data is stored in memory for the prototype
