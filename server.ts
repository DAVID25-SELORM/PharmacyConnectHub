import express from 'express';
import cors from 'cors';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const app = express();
const port = 4000;

const storageFile = path.join(path.dirname(fileURLToPath(import.meta.url)), 'data.json');

app.use(cors({ origin: true }));
app.use(express.json());

interface Wholesaler {
  id: string;
  name: string;
  location: string;
  rating: number;
}

interface Product {
  id: string;
  wholesalerId: string;
  name: string;
  generic: string;
  strength: string;
  packSize: string;
  price: number;
  stock: number;
}

interface OrderRequestItem {
  productId: string;
  productName: string;
  generic: string;
  strength: string;
  packSize: string;
  quantity: number;
}

interface OrderRequest {
  id: string;
  customerName: string;
  customerPhone: string;
  deliveryAddress: string;
  items: OrderRequestItem[];
  status: 'Quote requested' | 'Quotes received' | 'Accepted';
  acceptedQuoteId?: string;
  createdAt: string;
}

interface QuoteItem {
  productId: string;
  productName: string;
  quotedPrice: number;
  deliveryDays: number;
  comment: string;
}

interface Quote {
  id: string;
  wholesalerId: string;
  wholesalerName: string;
  orderRequestId: string;
  items: QuoteItem[];
  total: number;
  status: 'Pending' | 'Accepted' | 'Rejected';
  createdAt: string;
}

interface DataStore {
  wholesalers: Wholesaler[];
  products: Product[];
  orderRequests: OrderRequest[];
  quotes: Quote[];
}

const defaultData: DataStore = {
  wholesalers: [
    { id: 'wh1', name: 'Apex Pharma Supply', location: 'Accra', rating: 4.8 },
    { id: 'wh2', name: 'Goldline Distributors', location: 'Kumasi', rating: 4.5 },
    { id: 'wh3', name: 'Unity Medical Wholesale', location: 'Takoradi', rating: 4.4 }
  ],
  products: [
    { id: 'p1', wholesalerId: 'wh1', name: 'Paracetamol 500mg Tablet', generic: 'Paracetamol', strength: '500mg', packSize: '100 tablets', price: 52, stock: 120 },
    { id: 'p2', wholesalerId: 'wh1', name: 'Amoxicillin 500mg Capsule', generic: 'Amoxicillin', strength: '500mg', packSize: '30 capsules', price: 145, stock: 80 },
    { id: 'p3', wholesalerId: 'wh2', name: 'Cetirizine 10mg Tablet', generic: 'Cetirizine', strength: '10mg', packSize: '30 tablets', price: 90, stock: 150 },
    { id: 'p4', wholesalerId: 'wh2', name: 'Metformin 500mg Tablet', generic: 'Metformin', strength: '500mg', packSize: '60 tablets', price: 210, stock: 70 },
    { id: 'p5', wholesalerId: 'wh3', name: 'Ibuprofen 400mg Tablet', generic: 'Ibuprofen', strength: '400mg', packSize: '50 tablets', price: 95, stock: 100 },
    { id: 'p6', wholesalerId: 'wh3', name: 'Lisinopril 10mg Tablet', generic: 'Lisinopril', strength: '10mg', packSize: '30 tablets', price: 320, stock: 45 }
  ],
  orderRequests: [],
  quotes: []
};

function loadData(): DataStore {
  if (!fs.existsSync(storageFile)) {
    fs.writeFileSync(storageFile, JSON.stringify(defaultData, null, 2), 'utf8');
    return defaultData;
  }

  const raw = fs.readFileSync(storageFile, 'utf8');
  try {
    return JSON.parse(raw) as DataStore;
  } catch {
    fs.writeFileSync(storageFile, JSON.stringify(defaultData, null, 2), 'utf8');
    return defaultData;
  }
}

function saveData(data: DataStore) {
  fs.writeFileSync(storageFile, JSON.stringify(data, null, 2), 'utf8');
}

const store = loadData();

function getWholesaler(wholesalerId: string) {
  return store.wholesalers.find((wh) => wh.id === wholesalerId);
}

function getRelevantRequests(wholesalerId: string) {
  return store.orderRequests.filter((request) =>
    request.items.some((item) =>
      store.products.some(
        (product) =>
          product.wholesalerId === wholesalerId &&
          product.generic === item.generic &&
          product.strength === item.strength
      )
    )
  );
}

app.get('/api/wholesalers', (req, res) => {
  res.json(store.wholesalers);
});

app.get('/api/products', (req, res) => {
  res.json(store.products);
});

app.get('/api/order-requests', (req, res) => {
  res.json(store.orderRequests.slice().reverse());
});

app.get('/api/supplier-requests', (req, res) => {
  const wholesalerId = String(req.query.wholesalerId || '');
  if (!wholesalerId) {
    return res.status(400).json({ error: 'wholesalerId query is required.' });
  }
  res.json(getRelevantRequests(wholesalerId).slice().reverse());
});

app.get('/api/quotes', (req, res) => {
  const { orderRequestId, wholesalerId } = req.query;
  let result = store.quotes;

  if (orderRequestId) {
    result = result.filter((quote) => quote.orderRequestId === String(orderRequestId));
  }

  if (wholesalerId) {
    result = result.filter((quote) => quote.wholesalerId === String(wholesalerId));
  }

  res.json(result.slice().reverse());
});

app.post('/api/order-requests', (req, res) => {
  const { customerName, customerPhone, deliveryAddress, items } = req.body;

  if (!customerName || !customerPhone || !deliveryAddress || !Array.isArray(items) || items.length === 0) {
    return res.status(400).json({ error: 'Customer details and order items are required.' });
  }

  const orderItems: OrderRequestItem[] = items.map((item: { productId: string; quantity: number }) => {
    const product = store.products.find((product) => product.id === item.productId);
    if (!product) {
      throw new Error(`Product not found: ${item.productId}`);
    }

    return {
      productId: product.id,
      productName: product.name,
      generic: product.generic,
      strength: product.strength,
      packSize: product.packSize,
      quantity: Number(item.quantity)
    };
  });

  const orderRequest: OrderRequest = {
    id: `req-${Date.now()}`,
    customerName,
    customerPhone,
    deliveryAddress,
    items: orderItems,
    status: 'Quote requested',
    createdAt: new Date().toISOString()
  };

  store.orderRequests.push(orderRequest);
  saveData(store);
  res.status(201).json(orderRequest);
});

app.post('/api/quotes', (req, res) => {
  const { wholesalerId, orderRequestId, itemQuotes } = req.body;

  if (!wholesalerId || !orderRequestId || !Array.isArray(itemQuotes) || itemQuotes.length === 0) {
    return res.status(400).json({ error: 'wholesalerId, orderRequestId and itemQuotes are required.' });
  }

  const wholesaler = getWholesaler(wholesalerId);
  if (!wholesaler) {
    return res.status(404).json({ error: 'Wholesaler not found.' });
  }

  const orderRequest = store.orderRequests.find((request) => request.id === orderRequestId);
  if (!orderRequest) {
    return res.status(404).json({ error: 'Order request not found.' });
  }

  const quoteItems: QuoteItem[] = itemQuotes.map((item: { productId: string; quotedPrice: number; deliveryDays: number; comment: string }) => {
    const requestItem = orderRequest.items.find((requestItem) => requestItem.productId === item.productId);
    if (!requestItem) {
      throw new Error(`Order item not found: ${item.productId}`);
    }

    return {
      productId: requestItem.productId,
      productName: requestItem.productName,
      quotedPrice: Number(item.quotedPrice),
      deliveryDays: Number(item.deliveryDays),
      comment: item.comment || ''
    };
  });

  if (quoteItems.some((item) => Number.isNaN(item.quotedPrice) || Number.isNaN(item.deliveryDays))) {
    return res.status(400).json({ error: 'Quoted price and delivery days must be valid numbers.' });
  }

  const total = quoteItems.reduce((sum, item) => sum + item.quotedPrice * orderRequest.items.find((value) => value.productId === item.productId)!.quantity, 0);
  const existingQuote = store.quotes.find((quote) => quote.wholesalerId === wholesalerId && quote.orderRequestId === orderRequestId);

  const quote: Quote = existingQuote
    ? {
        ...existingQuote,
        items: quoteItems,
        total,
        status: 'Pending',
        createdAt: existingQuote.createdAt
      }
    : {
        id: `quote-${Date.now()}`,
        wholesalerId,
        wholesalerName: wholesaler.name,
        orderRequestId,
        items: quoteItems,
        total,
        status: 'Pending',
        createdAt: new Date().toISOString()
      };

  if (existingQuote) {
    store.quotes = store.quotes.map((existing) => (existing.id === existingQuote.id ? quote : existing));
  } else {
    store.quotes.push(quote);
  }

  orderRequest.status = 'Quotes received';
  saveData(store);
  res.status(existingQuote ? 200 : 201).json(quote);
});

app.post('/api/quote-accept', (req, res) => {
  const { quoteId } = req.body;
  if (!quoteId) {
    return res.status(400).json({ error: 'quoteId is required.' });
  }

  const quote = store.quotes.find((entry) => entry.id === quoteId);
  if (!quote) {
    return res.status(404).json({ error: 'Quote not found.' });
  }

  store.quotes = store.quotes.map((entry) => {
    if (entry.orderRequestId === quote.orderRequestId) {
      return { ...entry, status: entry.id === quoteId ? 'Accepted' : 'Rejected' };
    }
    return entry;
  });

  const orderRequest = store.orderRequests.find((request) => request.id === quote.orderRequestId);
  if (orderRequest) {
    orderRequest.status = 'Accepted';
    orderRequest.acceptedQuoteId = quoteId;
  }

  saveData(store);
  res.json({ quote, orderRequest });
});

app.listen(port, () => {
  console.log(`Order API server listening at http://localhost:${port}`);
});
