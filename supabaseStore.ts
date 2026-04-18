import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { createClient } from '@supabase/supabase-js';

export type UserRole = 'pharmacy' | 'supplier' | 'admin';
export type OrderStatus =
  | 'Quote requested'
  | 'Quotes received'
  | 'Accepted'
  | 'Processing'
  | 'Dispatched'
  | 'Delivered';
export type QuoteStatus = 'Pending' | 'Accepted' | 'Rejected';

export interface Wholesaler {
  id: string;
  name: string;
  location: string;
  rating: number;
}

export interface Product {
  id: string;
  wholesalerId: string;
  name: string;
  generic: string;
  strength: string;
  packSize: string;
  price: number;
  stock: number;
}

export interface OrderRequestItem {
  productId: string;
  productName: string;
  generic: string;
  strength: string;
  packSize: string;
  quantity: number;
}

export interface OrderRequest {
  id: string;
  customerName: string;
  customerPhone: string;
  deliveryAddress: string;
  items: OrderRequestItem[];
  status: OrderStatus;
  acceptedQuoteId?: string;
  createdAt: string;
}

export interface QuoteItem {
  productId: string;
  productName: string;
  quotedPrice: number;
  deliveryDays: number;
  comment: string;
}

export interface Quote {
  id: string;
  wholesalerId: string;
  wholesalerName: string;
  orderRequestId: string;
  items: QuoteItem[];
  total: number;
  status: QuoteStatus;
  createdAt: string;
}

interface UserAccount {
  id: string;
  name: string;
  email: string;
  password: string;
  role: UserRole;
  wholesalerId?: string;
}

export type PublicUser = Omit<UserAccount, 'password'>;

export class ApiError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const rootDir = path.dirname(fileURLToPath(import.meta.url));
loadEnvFile(path.join(rootDir, '.env'));
loadEnvFile(path.join(rootDir, '.env.local'), true);

const supabaseUrl = process.env.SUPABASE_URL ?? process.env.VITE_SUPABASE_URL ?? '';
const supabaseKey =
  process.env.SUPABASE_PUBLISHABLE_KEY ?? process.env.VITE_SUPABASE_PUBLISHABLE_KEY ?? '';

const supabase =
  supabaseUrl && supabaseKey
    ? createClient(supabaseUrl, supabaseKey, {
        auth: { autoRefreshToken: false, persistSession: false }
      })
    : null;

const seedData = {
  wholesalers: [
    { id: 'wh1', name: 'Apex Pharma Supply', location: 'Accra', rating: 4.8 },
    { id: 'wh2', name: 'Goldline Distributors', location: 'Kumasi', rating: 4.5 },
    { id: 'wh3', name: 'Unity Medical Wholesale', location: 'Takoradi', rating: 4.4 }
  ] as Wholesaler[],
  products: [
    {
      id: 'p1',
      wholesalerId: 'wh1',
      name: 'Paracetamol 500mg Tablet',
      generic: 'Paracetamol',
      strength: '500mg',
      packSize: '100 tablets',
      price: 52,
      stock: 120
    },
    {
      id: 'p2',
      wholesalerId: 'wh1',
      name: 'Amoxicillin 500mg Capsule',
      generic: 'Amoxicillin',
      strength: '500mg',
      packSize: '30 capsules',
      price: 145,
      stock: 80
    },
    {
      id: 'p3',
      wholesalerId: 'wh2',
      name: 'Cetirizine 10mg Tablet',
      generic: 'Cetirizine',
      strength: '10mg',
      packSize: '30 tablets',
      price: 90,
      stock: 150
    },
    {
      id: 'p4',
      wholesalerId: 'wh2',
      name: 'Metformin 500mg Tablet',
      generic: 'Metformin',
      strength: '500mg',
      packSize: '60 tablets',
      price: 210,
      stock: 70
    },
    {
      id: 'p5',
      wholesalerId: 'wh3',
      name: 'Ibuprofen 400mg Tablet',
      generic: 'Ibuprofen',
      strength: '400mg',
      packSize: '50 tablets',
      price: 95,
      stock: 100
    },
    {
      id: 'p6',
      wholesalerId: 'wh3',
      name: 'Lisinopril 10mg Tablet',
      generic: 'Lisinopril',
      strength: '10mg',
      packSize: '30 tablets',
      price: 320,
      stock: 45
    }
  ] as Product[],
  users: [
    {
      id: 'u-admin-1',
      name: 'Platform Admin',
      email: 'admin@pharmacyconnecthub.com',
      password: 'demo123',
      role: 'admin'
    },
    {
      id: 'u-supplier-1',
      name: 'Apex Pharma Supply Team',
      email: 'supplier@pharmacyconnecthub.com',
      password: 'demo123',
      role: 'supplier',
      wholesalerId: 'wh1'
    },
    {
      id: 'u-pharmacy-1',
      name: 'Royal Care Pharmacy',
      email: 'pharmacy@pharmacyconnecthub.com',
      password: 'demo123',
      role: 'pharmacy'
    }
  ] as UserAccount[]
};

let seedPromise: Promise<void> | null = null;

export function getStorageInfo() {
  return { configured: Boolean(supabase), host: safeHost(supabaseUrl) };
}

function loadEnvFile(filePath: string, allowOverride = false) {
  if (!fs.existsSync(filePath)) {
    return;
  }

  for (const line of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) {
      continue;
    }

    const separator = trimmed.indexOf('=');
    if (separator < 0) {
      continue;
    }

    const key = trimmed.slice(0, separator).trim();
    if (!key || (!allowOverride && process.env[key] !== undefined)) {
      continue;
    }

    let value = trimmed.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    process.env[key] = value;
  }
}

function safeHost(value: string) {
  try {
    return new URL(value).host;
  } catch {
    return value;
  }
}

function dbError(error: unknown) {
  if (error instanceof ApiError) {
    return error;
  }

  if (error && typeof error === 'object') {
    const code = 'code' in error ? String((error as { code?: string }).code ?? '') : '';
    const message =
      'message' in error ? String((error as { message?: string }).message ?? '') : 'Unexpected error.';

    if (code === '42P01' || /relation .* does not exist/i.test(message)) {
      return new ApiError(
        500,
        'Supabase tables are missing. Run supabase/schema.sql in the Supabase SQL editor first.'
      );
    }

    if (code === '42501') {
      return new ApiError(
        500,
        'Supabase rejected this request. Check the grants and RLS policies in supabase/schema.sql.'
      );
    }

    if (code === '23505') {
      return new ApiError(409, 'A record with this value already exists.');
    }
  }

  return error;
}

function requireClient() {
  if (!supabase) {
    throw new ApiError(
      503,
      'Supabase is not configured. Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY to .env.'
    );
  }

  return supabase;
}

async function readyClient() {
  const client = requireClient();
  await ensureSeedData();
  return client;
}

async function ensureSeedData() {
  const client = requireClient();
  if (seedPromise) {
    return seedPromise;
  }

  seedPromise = (async () => {
    const [wholesalers, products, users] = await Promise.all([
      client.from('wholesalers').select('id', { count: 'exact', head: true }),
      client.from('products').select('id', { count: 'exact', head: true }),
      client.from('users').select('id', { count: 'exact', head: true })
    ]);

    if (wholesalers.error) {
      throw dbError(wholesalers.error);
    }
    if (products.error) {
      throw dbError(products.error);
    }
    if (users.error) {
      throw dbError(users.error);
    }

    const seeded =
      (wholesalers.count ?? 0) > 0 && (products.count ?? 0) > 0 && (users.count ?? 0) > 0;
    if (seeded) {
      return;
    }

    const { error: wholesalerError } = await client
      .from('wholesalers')
      .upsert(seedData.wholesalers.map(toWholesalerInsert), {
        onConflict: 'id',
        ignoreDuplicates: true
      });
    if (wholesalerError) {
      throw dbError(wholesalerError);
    }

    const { error: productError } = await client
      .from('products')
      .upsert(seedData.products.map(toProductInsert), {
        onConflict: 'id',
        ignoreDuplicates: true
      });
    if (productError) {
      throw dbError(productError);
    }

    const { error: userError } = await client.from('users').upsert(seedData.users.map(toUserInsert), {
      onConflict: 'id',
      ignoreDuplicates: true
    });
    if (userError) {
      throw dbError(userError);
    }
  })().catch((error) => {
    seedPromise = null;
    throw error;
  });

  return seedPromise;
}

function makeId(prefix: string) {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
}

function nextStatus(status: OrderStatus) {
  if (status === 'Accepted') {
    return 'Processing' as OrderStatus;
  }
  if (status === 'Processing') {
    return 'Dispatched' as OrderStatus;
  }
  if (status === 'Dispatched') {
    return 'Delivered' as OrderStatus;
  }
  return null;
}

function toWholesalerInsert(wholesaler: Wholesaler) {
  return {
    id: wholesaler.id,
    name: wholesaler.name,
    location: wholesaler.location,
    rating: wholesaler.rating
  };
}

function toProductInsert(product: Product) {
  return {
    id: product.id,
    wholesaler_id: product.wholesalerId,
    name: product.name,
    generic: product.generic,
    strength: product.strength,
    pack_size: product.packSize,
    price: product.price,
    stock: product.stock
  };
}

function toUserInsert(user: UserAccount) {
  return {
    id: user.id,
    name: user.name,
    email: user.email,
    password: user.password,
    role: user.role,
    wholesaler_id: user.wholesalerId ?? null
  };
}

function mapWholesaler(row: any): Wholesaler {
  return {
    id: String(row.id),
    name: String(row.name),
    location: String(row.location),
    rating: Number(row.rating)
  };
}

function mapProduct(row: any): Product {
  return {
    id: String(row.id),
    wholesalerId: String(row.wholesaler_id),
    name: String(row.name),
    generic: String(row.generic),
    strength: String(row.strength),
    packSize: String(row.pack_size),
    price: Number(row.price),
    stock: Number(row.stock)
  };
}

function mapUser(row: any): UserAccount {
  return {
    id: String(row.id),
    name: String(row.name),
    email: String(row.email),
    password: String(row.password),
    role: row.role as UserRole,
    ...(row.wholesaler_id ? { wholesalerId: String(row.wholesaler_id) } : {})
  };
}

function publicUser(user: UserAccount): PublicUser {
  const { password: _password, ...safeUser } = user;
  return safeUser;
}

function mapRequestBase(row: any): Omit<OrderRequest, 'items'> {
  return {
    id: String(row.id),
    customerName: String(row.customer_name),
    customerPhone: String(row.customer_phone),
    deliveryAddress: String(row.delivery_address),
    status: row.status as OrderStatus,
    ...(row.accepted_quote_id ? { acceptedQuoteId: String(row.accepted_quote_id) } : {}),
    createdAt: String(row.created_at)
  };
}

function mapRequestItem(row: any): OrderRequestItem {
  return {
    productId: String(row.product_id),
    productName: String(row.product_name),
    generic: String(row.generic),
    strength: String(row.strength),
    packSize: String(row.pack_size),
    quantity: Number(row.quantity)
  };
}

function mapQuoteBase(row: any): Omit<Quote, 'items'> {
  return {
    id: String(row.id),
    wholesalerId: String(row.wholesaler_id),
    wholesalerName: String(row.wholesaler_name),
    orderRequestId: String(row.order_request_id),
    total: Number(row.total),
    status: row.status as QuoteStatus,
    createdAt: String(row.created_at)
  };
}

function mapQuoteItem(row: any): QuoteItem {
  return {
    productId: String(row.product_id),
    productName: String(row.product_name),
    quotedPrice: Number(row.quoted_price),
    deliveryDays: Number(row.delivery_days),
    comment: row.comment ? String(row.comment) : ''
  };
}

async function wholesalerById(id: string) {
  const client = await readyClient();
  const { data, error } = await client
    .from('wholesalers')
    .select('id, name, location, rating')
    .eq('id', id)
    .maybeSingle();

  if (error) {
    throw dbError(error);
  }

  return data ? mapWholesaler(data) : null;
}

async function productsByIds(ids: string[]) {
  const productIds = Array.from(new Set(ids.filter(Boolean)));
  if (productIds.length === 0) {
    return [] as Product[];
  }

  const client = await readyClient();
  const { data, error } = await client
    .from('products')
    .select('id, wholesaler_id, name, generic, strength, pack_size, price, stock')
    .in('id', productIds);

  if (error) {
    throw dbError(error);
  }

  return (data ?? []).map(mapProduct);
}

async function requestById(id: string) {
  const client = await readyClient();
  const { data: requestRow, error: requestError } = await client
    .from('order_requests')
    .select(
      'id, customer_name, customer_phone, delivery_address, status, accepted_quote_id, created_at'
    )
    .eq('id', id)
    .maybeSingle();

  if (requestError) {
    throw dbError(requestError);
  }

  if (!requestRow) {
    return null;
  }

  const { data: itemRows, error: itemError } = await client
    .from('order_request_items')
    .select(
      'order_request_id, product_id, product_name, generic, strength, pack_size, quantity, created_at'
    )
    .eq('order_request_id', id)
    .order('created_at', { ascending: true });

  if (itemError) {
    throw dbError(itemError);
  }

  return {
    ...mapRequestBase(requestRow),
    items: (itemRows ?? []).map(mapRequestItem)
  } satisfies OrderRequest;
}

async function quoteById(id: string) {
  const client = await readyClient();
  const { data: quoteRow, error: quoteError } = await client
    .from('quotes')
    .select('id, wholesaler_id, wholesaler_name, order_request_id, total, status, created_at')
    .eq('id', id)
    .maybeSingle();

  if (quoteError) {
    throw dbError(quoteError);
  }

  if (!quoteRow) {
    return null;
  }

  const { data: itemRows, error: itemError } = await client
    .from('quote_items')
    .select('quote_id, product_id, product_name, quoted_price, delivery_days, comment, created_at')
    .eq('quote_id', id)
    .order('created_at', { ascending: true });

  if (itemError) {
    throw dbError(itemError);
  }

  return {
    ...mapQuoteBase(quoteRow),
    items: (itemRows ?? []).map(mapQuoteItem)
  } satisfies Quote;
}

export async function listWholesalers() {
  const client = await readyClient();
  const { data, error } = await client
    .from('wholesalers')
    .select('id, name, location, rating')
    .order('created_at', { ascending: true });

  if (error) {
    throw dbError(error);
  }

  return (data ?? []).map(mapWholesaler);
}

export async function listProducts() {
  const client = await readyClient();
  const { data, error } = await client
    .from('products')
    .select('id, wholesaler_id, name, generic, strength, pack_size, price, stock')
    .order('created_at', { ascending: true });

  if (error) {
    throw dbError(error);
  }

  return (data ?? []).map(mapProduct);
}

export async function loginUser(email: string, password: string) {
  const client = await readyClient();
  const { data, error } = await client
    .from('users')
    .select('id, name, email, password, role, wholesaler_id')
    .eq('email', email.trim().toLowerCase())
    .eq('password', password)
    .maybeSingle();

  if (error) {
    throw dbError(error);
  }

  return data ? publicUser(mapUser(data)) : null;
}

export async function listUsers() {
  const client = await readyClient();
  const { data, error } = await client
    .from('users')
    .select('id, name, email, password, role, wholesaler_id')
    .order('created_at', { ascending: true });

  if (error) {
    throw dbError(error);
  }

  return (data ?? []).map(mapUser).map(publicUser);
}

export async function createUser(input: {
  name: string;
  email: string;
  password: string;
  role: UserRole;
  wholesalerId?: string;
}) {
  const client = await readyClient();

  if (input.role === 'supplier') {
    if (!input.wholesalerId) {
      throw new ApiError(400, 'wholesalerId is required for supplier accounts.');
    }

    const wholesaler = await wholesalerById(input.wholesalerId);
    if (!wholesaler) {
      throw new ApiError(404, 'Wholesaler not found.');
    }
  }

  const { data, error } = await client
    .from('users')
    .insert({
      id: makeId('u'),
      name: input.name.trim(),
      email: input.email.trim().toLowerCase(),
      password: input.password,
      role: input.role,
      wholesaler_id: input.role === 'supplier' ? input.wholesalerId ?? null : null
    })
    .select('id, name, email, password, role, wholesaler_id')
    .single();

  if (error) {
    if (String((error as { code?: string }).code ?? '') === '23505') {
      throw new ApiError(409, 'An account with this email already exists.');
    }
    throw dbError(error);
  }

  return publicUser(mapUser(data));
}

export async function deleteUser(id: string) {
  const client = await readyClient();
  const { data, error } = await client
    .from('users')
    .select('id, name, email, password, role, wholesaler_id')
    .eq('id', id)
    .maybeSingle();

  if (error) {
    throw dbError(error);
  }

  if (!data) {
    throw new ApiError(404, 'User not found.');
  }

  const user = mapUser(data);
  if (user.role === 'admin') {
    const { count, error: countError } = await client
      .from('users')
      .select('id', { count: 'exact', head: true })
      .eq('role', 'admin');
    if (countError) {
      throw dbError(countError);
    }
    if ((count ?? 0) <= 1) {
      throw new ApiError(400, 'Cannot delete the only admin account.');
    }
  }

  const { error: deleteError } = await client.from('users').delete().eq('id', id);
  if (deleteError) {
    throw dbError(deleteError);
  }
}

export async function createWholesaler(name: string, location: string, rating: number) {
  const client = await readyClient();
  const { data, error } = await client
    .from('wholesalers')
    .insert({
      id: makeId('wh'),
      name: name.trim(),
      location: location.trim(),
      rating: Number(rating.toFixed(1))
    })
    .select('id, name, location, rating')
    .single();

  if (error) {
    throw dbError(error);
  }

  return mapWholesaler(data);
}

export async function createProduct(input: {
  wholesalerId: string;
  name: string;
  generic: string;
  strength: string;
  packSize: string;
  price: number;
  stock: number;
}) {
  const client = await readyClient();
  const wholesaler = await wholesalerById(input.wholesalerId);
  if (!wholesaler) {
    throw new ApiError(404, 'Wholesaler not found.');
  }

  const { data, error } = await client
    .from('products')
    .insert({
      id: makeId('p'),
      wholesaler_id: input.wholesalerId,
      name: input.name.trim(),
      generic: input.generic.trim(),
      strength: input.strength.trim(),
      pack_size: input.packSize.trim(),
      price: Number(input.price.toFixed(2)),
      stock: Math.floor(input.stock)
    })
    .select('id, wholesaler_id, name, generic, strength, pack_size, price, stock')
    .single();

  if (error) {
    throw dbError(error);
  }

  return mapProduct(data);
}

export async function listOrderRequests() {
  const client = await readyClient();
  const { data: requestRows, error: requestError } = await client
    .from('order_requests')
    .select(
      'id, customer_name, customer_phone, delivery_address, status, accepted_quote_id, created_at'
    )
    .order('created_at', { ascending: false });

  if (requestError) {
    throw dbError(requestError);
  }

  if (!requestRows?.length) {
    return [] as OrderRequest[];
  }

  const ids = requestRows.map((row) => String(row.id));
  const { data: itemRows, error: itemError } = await client
    .from('order_request_items')
    .select(
      'order_request_id, product_id, product_name, generic, strength, pack_size, quantity, created_at'
    )
    .in('order_request_id', ids)
    .order('created_at', { ascending: true });

  if (itemError) {
    throw dbError(itemError);
  }

  const items = new Map<string, OrderRequestItem[]>();
  for (const row of itemRows ?? []) {
    const key = String(row.order_request_id);
    items.set(key, [...(items.get(key) ?? []), mapRequestItem(row)]);
  }

  return requestRows.map((row) => ({
    ...mapRequestBase(row),
    items: items.get(String(row.id)) ?? []
  }));
}

export async function listSupplierRequests(wholesalerId: string) {
  const [products, requests] = await Promise.all([listProducts(), listOrderRequests()]);
  const supported = new Set(
    products
      .filter((product) => product.wholesalerId === wholesalerId)
      .map((product) => `${product.generic}::${product.strength}`)
  );

  return requests.filter((request) =>
    request.items.some((item) => supported.has(`${item.generic}::${item.strength}`))
  );
}

export async function createOrderRequest(input: {
  customerName: string;
  customerPhone: string;
  deliveryAddress: string;
  items: Array<{ productId: string; quantity: number }>;
}) {
  const client = await readyClient();
  const products = await productsByIds(input.items.map((item) => item.productId));
  const productMap = new Map(products.map((product) => [product.id, product]));

  const items = input.items.map((item) => {
    const product = productMap.get(String(item.productId));
    if (!product) {
      throw new ApiError(404, `Product not found: ${item.productId}`);
    }

    const quantity = Number(item.quantity);
    if (Number.isNaN(quantity) || quantity <= 0) {
      throw new ApiError(400, 'Each order quantity must be a valid number greater than zero.');
    }

    return {
      productId: product.id,
      productName: product.name,
      generic: product.generic,
      strength: product.strength,
      packSize: product.packSize,
      quantity
    };
  });

  const { data: requestRow, error: requestError } = await client
    .from('order_requests')
    .insert({
      id: makeId('req'),
      customer_name: input.customerName.trim(),
      customer_phone: input.customerPhone.trim(),
      delivery_address: input.deliveryAddress.trim(),
      status: 'Quote requested'
    })
    .select(
      'id, customer_name, customer_phone, delivery_address, status, accepted_quote_id, created_at'
    )
    .single();

  if (requestError) {
    throw dbError(requestError);
  }

  const { error: itemError } = await client.from('order_request_items').insert(
    items.map((item) => ({
      order_request_id: String(requestRow.id),
      product_id: item.productId,
      product_name: item.productName,
      generic: item.generic,
      strength: item.strength,
      pack_size: item.packSize,
      quantity: item.quantity
    }))
  );

  if (itemError) {
    await client.from('order_requests').delete().eq('id', requestRow.id);
    throw dbError(itemError);
  }

  return {
    ...mapRequestBase(requestRow),
    items
  } satisfies OrderRequest;
}

export async function listQuotes(filters: { orderRequestId?: string; wholesalerId?: string } = {}) {
  const client = await readyClient();
  let query = client
    .from('quotes')
    .select('id, wholesaler_id, wholesaler_name, order_request_id, total, status, created_at')
    .order('created_at', { ascending: false });

  if (filters.orderRequestId) {
    query = query.eq('order_request_id', filters.orderRequestId);
  }
  if (filters.wholesalerId) {
    query = query.eq('wholesaler_id', filters.wholesalerId);
  }

  const { data: quoteRows, error: quoteError } = await query;
  if (quoteError) {
    throw dbError(quoteError);
  }

  if (!quoteRows?.length) {
    return [] as Quote[];
  }

  const ids = quoteRows.map((row) => String(row.id));
  const { data: itemRows, error: itemError } = await client
    .from('quote_items')
    .select('quote_id, product_id, product_name, quoted_price, delivery_days, comment, created_at')
    .in('quote_id', ids)
    .order('created_at', { ascending: true });

  if (itemError) {
    throw dbError(itemError);
  }

  const items = new Map<string, QuoteItem[]>();
  for (const row of itemRows ?? []) {
    const key = String(row.quote_id);
    items.set(key, [...(items.get(key) ?? []), mapQuoteItem(row)]);
  }

  return quoteRows.map((row) => ({
    ...mapQuoteBase(row),
    items: items.get(String(row.id)) ?? []
  }));
}

export async function submitQuote(input: {
  wholesalerId: string;
  orderRequestId: string;
  itemQuotes: Array<{ productId: string; quotedPrice: number; deliveryDays: number; comment: string }>;
}) {
  const client = await readyClient();
  const wholesaler = await wholesalerById(input.wholesalerId);
  if (!wholesaler) {
    throw new ApiError(404, 'Wholesaler not found.');
  }

  const request = await requestById(input.orderRequestId);
  if (!request) {
    throw new ApiError(404, 'Order request not found.');
  }

  const requestItems = new Map(request.items.map((item) => [item.productId, item]));
  const items = input.itemQuotes.map((item) => {
    const requestItem = requestItems.get(String(item.productId));
    if (!requestItem) {
      throw new ApiError(400, `Order item not found: ${item.productId}`);
    }

    const quotedPrice = Number(item.quotedPrice);
    const deliveryDays = Number(item.deliveryDays);
    if (Number.isNaN(quotedPrice) || quotedPrice <= 0 || Number.isNaN(deliveryDays) || deliveryDays <= 0) {
      throw new ApiError(400, 'Quoted price and delivery days must be valid numbers greater than zero.');
    }

    return {
      productId: requestItem.productId,
      productName: requestItem.productName,
      quotedPrice: Number(quotedPrice.toFixed(2)),
      deliveryDays: Math.floor(deliveryDays),
      comment: item.comment ? String(item.comment).trim() : ''
    };
  });

  const total = Number(
    items
      .reduce((sum, item) => sum + item.quotedPrice * requestItems.get(item.productId)!.quantity, 0)
      .toFixed(2)
  );

  const { data: existingQuote, error: existingError } = await client
    .from('quotes')
    .select('id, wholesaler_id, wholesaler_name, order_request_id, total, status, created_at')
    .eq('wholesaler_id', input.wholesalerId)
    .eq('order_request_id', input.orderRequestId)
    .maybeSingle();

  if (existingError) {
    throw dbError(existingError);
  }

  let savedQuote: any;
  if (existingQuote) {
    const { data, error } = await client
      .from('quotes')
      .update({ wholesaler_name: wholesaler.name, total, status: 'Pending' })
      .eq('id', existingQuote.id)
      .select('id, wholesaler_id, wholesaler_name, order_request_id, total, status, created_at')
      .single();

    if (error) {
      throw dbError(error);
    }

    savedQuote = data;

    const { error: deleteError } = await client.from('quote_items').delete().eq('quote_id', existingQuote.id);
    if (deleteError) {
      throw dbError(deleteError);
    }
  } else {
    const { data, error } = await client
      .from('quotes')
      .insert({
        id: makeId('quote'),
        wholesaler_id: input.wholesalerId,
        wholesaler_name: wholesaler.name,
        order_request_id: input.orderRequestId,
        total,
        status: 'Pending'
      })
      .select('id, wholesaler_id, wholesaler_name, order_request_id, total, status, created_at')
      .single();

    if (error) {
      throw dbError(error);
    }

    savedQuote = data;
  }

  const { error: itemError } = await client.from('quote_items').insert(
    items.map((item) => ({
      quote_id: String(savedQuote.id),
      product_id: item.productId,
      product_name: item.productName,
      quoted_price: item.quotedPrice,
      delivery_days: item.deliveryDays,
      comment: item.comment
    }))
  );

  if (itemError) {
    throw dbError(itemError);
  }

  const { error: requestError } = await client
    .from('order_requests')
    .update({ status: 'Quotes received' })
    .eq('id', input.orderRequestId);

  if (requestError) {
    throw dbError(requestError);
  }

  return {
    ...mapQuoteBase(savedQuote),
    items
  } satisfies Quote;
}

export async function acceptQuote(quoteId: string) {
  const client = await readyClient();
  const quote = await quoteById(quoteId);
  if (!quote) {
    throw new ApiError(404, 'Quote not found.');
  }

  const { error: rejectError } = await client
    .from('quotes')
    .update({ status: 'Rejected' })
    .eq('order_request_id', quote.orderRequestId)
    .neq('id', quoteId);
  if (rejectError) {
    throw dbError(rejectError);
  }

  const { error: acceptError } = await client
    .from('quotes')
    .update({ status: 'Accepted' })
    .eq('id', quoteId);
  if (acceptError) {
    throw dbError(acceptError);
  }

  const { error: requestError } = await client
    .from('order_requests')
    .update({ status: 'Accepted', accepted_quote_id: quoteId })
    .eq('id', quote.orderRequestId);
  if (requestError) {
    throw dbError(requestError);
  }

  return {
    quote: { ...quote, status: 'Accepted' as QuoteStatus },
    orderRequest: await requestById(quote.orderRequestId)
  };
}

export async function advanceOrderStatus(orderRequestId: string, wholesalerId: string) {
  const client = await readyClient();
  const request = await requestById(orderRequestId);
  if (!request) {
    throw new ApiError(404, 'Order request not found.');
  }

  if (!request.acceptedQuoteId) {
    throw new ApiError(400, 'Order does not have an accepted supplier yet.');
  }

  const { data: acceptedQuote, error: acceptedError } = await client
    .from('quotes')
    .select('id, wholesaler_id, status')
    .eq('id', request.acceptedQuoteId)
    .eq('status', 'Accepted')
    .maybeSingle();

  if (acceptedError) {
    throw dbError(acceptedError);
  }

  if (!acceptedQuote) {
    throw new ApiError(404, 'Accepted quote not found.');
  }

  if (String(acceptedQuote.wholesaler_id) !== wholesalerId) {
    throw new ApiError(403, 'Only the accepted supplier can update fulfillment status.');
  }

  const status = nextStatus(request.status);
  if (!status) {
    throw new ApiError(400, 'No further status transition is allowed for this order.');
  }

  const { error } = await client.from('order_requests').update({ status }).eq('id', orderRequestId);
  if (error) {
    throw dbError(error);
  }

  return { orderRequest: await requestById(orderRequestId) };
}
