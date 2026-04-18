import express from 'express';
import cors from 'cors';
import {
  ApiError,
  acceptQuote,
  advanceOrderStatus,
  createOrderRequest,
  createProduct,
  createUser,
  createWholesaler,
  deleteUser,
  getStorageInfo,
  listOrderRequests,
  listProducts,
  listQuotes,
  listSupplierRequests,
  listUsers,
  listWholesalers,
  loginUser,
  submitQuote,
  type UserRole
} from './supabaseStore.ts';

const app = express();
const port = 4000;

app.use(cors({ origin: true }));
app.use(express.json());

function asyncRoute(handler: (req: any, res: any) => Promise<unknown>) {
  return (req: any, res: any) => {
    Promise.resolve(handler(req, res)).catch((error) => {
      if (error instanceof ApiError) {
        res.status(error.status).json({ error: error.message });
        return;
      }

      console.error(error);
      res.status(500).json({
        error: error instanceof Error ? error.message : 'Unexpected error.'
      });
    });
  };
}

app.get(
  '/api/wholesalers',
  asyncRoute(async (_req, res) => {
    res.json(await listWholesalers());
  })
);

app.post(
  '/api/auth/login',
  asyncRoute(async (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) {
      throw new ApiError(400, 'email and password are required.');
    }

    const user = await loginUser(String(email), String(password));
    if (!user) {
      throw new ApiError(401, 'Invalid credentials.');
    }

    res.json({ user });
  })
);

app.get(
  '/api/users',
  asyncRoute(async (_req, res) => {
    res.json(await listUsers());
  })
);

app.post(
  '/api/users',
  asyncRoute(async (req, res) => {
    const { name, email, password, role, wholesalerId } = req.body;
    if (!name || !email || !password || !role) {
      throw new ApiError(400, 'name, email, password, and role are required.');
    }

    const validRoles: UserRole[] = ['pharmacy', 'supplier', 'admin'];
    if (!validRoles.includes(role)) {
      throw new ApiError(400, `role must be one of: ${validRoles.join(', ')}.`);
    }

    res.status(201).json(
      await createUser({
        name: String(name),
        email: String(email),
        password: String(password),
        role: role as UserRole,
        wholesalerId: wholesalerId ? String(wholesalerId) : undefined
      })
    );
  })
);

app.delete(
  '/api/users/:id',
  asyncRoute(async (req, res) => {
    await deleteUser(String(req.params.id));
    res.json({ success: true });
  })
);

app.get(
  '/api/products',
  asyncRoute(async (_req, res) => {
    res.json(await listProducts());
  })
);

app.post(
  '/api/wholesalers',
  asyncRoute(async (req, res) => {
    const { name, location, rating } = req.body;
    const numericRating = Number(rating);
    if (!name || !location || Number.isNaN(numericRating) || numericRating < 0 || numericRating > 5) {
      throw new ApiError(400, 'name, location, and rating between 0 and 5 are required.');
    }

    res.status(201).json(await createWholesaler(String(name), String(location), numericRating));
  })
);

app.post(
  '/api/products',
  asyncRoute(async (req, res) => {
    const { wholesalerId, name, generic, strength, packSize, price, stock } = req.body;
    const numericPrice = Number(price);
    const numericStock = Number(stock);

    if (!wholesalerId || !name || !generic || !strength || !packSize) {
      throw new ApiError(400, 'wholesalerId, name, generic, strength, and packSize are required.');
    }

    if (Number.isNaN(numericPrice) || numericPrice <= 0 || Number.isNaN(numericStock) || numericStock < 0) {
      throw new ApiError(400, 'price must be > 0 and stock must be >= 0.');
    }

    res.status(201).json(
      await createProduct({
        wholesalerId: String(wholesalerId),
        name: String(name),
        generic: String(generic),
        strength: String(strength),
        packSize: String(packSize),
        price: numericPrice,
        stock: numericStock
      })
    );
  })
);

app.get(
  '/api/order-requests',
  asyncRoute(async (_req, res) => {
    res.json(await listOrderRequests());
  })
);

app.get(
  '/api/supplier-requests',
  asyncRoute(async (req, res) => {
    const wholesalerId = String(req.query.wholesalerId || '');
    if (!wholesalerId) {
      throw new ApiError(400, 'wholesalerId query is required.');
    }

    res.json(await listSupplierRequests(wholesalerId));
  })
);

app.get(
  '/api/quotes',
  asyncRoute(async (req, res) => {
    const orderRequestId = req.query.orderRequestId ? String(req.query.orderRequestId) : undefined;
    const wholesalerId = req.query.wholesalerId ? String(req.query.wholesalerId) : undefined;
    res.json(await listQuotes({ orderRequestId, wholesalerId }));
  })
);

app.post(
  '/api/order-requests',
  asyncRoute(async (req, res) => {
    const { customerName, customerPhone, deliveryAddress, items } = req.body;
    if (!customerName || !customerPhone || !deliveryAddress || !Array.isArray(items) || items.length === 0) {
      throw new ApiError(400, 'Customer details and order items are required.');
    }

    res.status(201).json(
      await createOrderRequest({
        customerName: String(customerName),
        customerPhone: String(customerPhone),
        deliveryAddress: String(deliveryAddress),
        items
      })
    );
  })
);

app.post(
  '/api/quotes',
  asyncRoute(async (req, res) => {
    const { wholesalerId, orderRequestId, itemQuotes } = req.body;
    if (!wholesalerId || !orderRequestId || !Array.isArray(itemQuotes) || itemQuotes.length === 0) {
      throw new ApiError(400, 'wholesalerId, orderRequestId and itemQuotes are required.');
    }

    res.status(201).json(
      await submitQuote({
        wholesalerId: String(wholesalerId),
        orderRequestId: String(orderRequestId),
        itemQuotes
      })
    );
  })
);

app.post(
  '/api/quote-accept',
  asyncRoute(async (req, res) => {
    const { quoteId } = req.body;
    if (!quoteId) {
      throw new ApiError(400, 'quoteId is required.');
    }

    res.json(await acceptQuote(String(quoteId)));
  })
);

app.post(
  '/api/order-status',
  asyncRoute(async (req, res) => {
    const { orderRequestId, wholesalerId } = req.body;
    if (!orderRequestId || !wholesalerId) {
      throw new ApiError(400, 'orderRequestId and wholesalerId are required.');
    }

    res.json(await advanceOrderStatus(String(orderRequestId), String(wholesalerId)));
  })
);

app.listen(port, () => {
  console.log(`Order API server listening at http://localhost:${port}`);
  const storage = getStorageInfo();
  if (storage.configured) {
    console.log(`Supabase backend configured for ${storage.host}.`);
  } else {
    console.warn('Supabase backend is not configured yet.');
  }
});
