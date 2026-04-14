import { useEffect, useMemo, useState } from 'react';

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

interface CartItem {
  product: Product;
  quantity: number;
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

type Role = 'pharmacy' | 'supplier';

type QuoteDraft = Record<string, { quotedPrice: string; deliveryDays: string; comment: string }>;

export default function App() {
  const [role, setRole] = useState<Role>('pharmacy');
  const [activeWholesalerId, setActiveWholesalerId] = useState('');
  const [wholesalers, setWholesalers] = useState<Wholesaler[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [cart, setCart] = useState<CartItem[]>([]);
  const [search, setSearch] = useState('');
  const [selectedWholesaler, setSelectedWholesaler] = useState('');
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState('');
  const [orderRequests, setOrderRequests] = useState<OrderRequest[]>([]);
  const [supplierRequests, setSupplierRequests] = useState<OrderRequest[]>([]);
  const [quotes, setQuotes] = useState<Quote[]>([]);
  const [supplierQuotes, setSupplierQuotes] = useState<Quote[]>([]);
  const [customerName, setCustomerName] = useState('');
  const [customerPhone, setCustomerPhone] = useState('');
  const [deliveryAddress, setDeliveryAddress] = useState('');
  const [quoteDrafts, setQuoteDrafts] = useState<Record<string, QuoteDraft>>({});

  useEffect(() => {
    fetch('/api/wholesalers')
      .then((res) => res.json())
      .then(setWholesalers)
      .catch(() => setMessage('Unable to load wholesalers'));

    fetch('/api/products')
      .then((res) => res.json())
      .then(setProducts)
      .catch(() => setMessage('Unable to load products'));
  }, []);

  useEffect(() => {
    if (role === 'pharmacy') {
      fetchOrderRequests();
      fetchQuotes();
    }

    if (role === 'supplier' && activeWholesalerId) {
      fetchSupplierRequests(activeWholesalerId);
      fetchSupplierQuotes(activeWholesalerId);
    }
  }, [role, activeWholesalerId]);

  const fetchOrderRequests = () => {
    fetch('/api/order-requests')
      .then((res) => res.json())
      .then(setOrderRequests)
      .catch(() => setMessage('Unable to load order requests'));
  };

  const fetchQuotes = () => {
    fetch('/api/quotes')
      .then((res) => res.json())
      .then(setQuotes)
      .catch(() => setMessage('Unable to load quotes'));
  };

  const fetchSupplierRequests = (wholesalerId: string) => {
    fetch(`/api/supplier-requests?wholesalerId=${wholesalerId}`)
      .then((res) => res.json())
      .then(setSupplierRequests)
      .catch(() => setMessage('Unable to load supplier requests'));
  };

  const fetchSupplierQuotes = (wholesalerId: string) => {
    fetch(`/api/quotes?wholesalerId=${wholesalerId}`)
      .then((res) => res.json())
      .then(setSupplierQuotes)
      .catch(() => setMessage('Unable to load supplier quotes'));
  };

  const filteredProducts = useMemo(() => {
    return products.filter((product) => {
      const term = search.trim().toLowerCase();
      const matchesSearch =
        product.name.toLowerCase().includes(term) ||
        product.generic.toLowerCase().includes(term) ||
        product.packSize.toLowerCase().includes(term);
      const matchesWholesaler = selectedWholesaler ? product.wholesalerId === selectedWholesaler : true;
      return matchesSearch && matchesWholesaler;
    });
  }, [products, search, selectedWholesaler]);

  const cartTotal = useMemo(() => {
    return cart.reduce((total, item) => total + item.product.price * item.quantity, 0);
  }, [cart]);

  const addToCart = (product: Product) => {
    setCart((current) => {
      const existing = current.find((item) => item.product.id === product.id);
      if (existing) {
        return current.map((item) =>
          item.product.id === product.id ? { ...item, quantity: Math.min(item.quantity + 1, product.stock) } : item
        );
      }
      return [...current, { product, quantity: 1 }];
    });
  };

  const updateQuantity = (productId: string, quantity: number) => {
    setCart((current) =>
      current
        .map((item) => (item.product.id === productId ? { ...item, quantity: Math.min(Math.max(quantity, 1), item.product.stock) } : item))
        .filter((item) => item.quantity > 0)
    );
  };

  const removeItem = (productId: string) => {
    setCart((current) => current.filter((item) => item.product.id !== productId));
  };

  const submitOrder = async () => {
    if (!customerName || !customerPhone || !deliveryAddress || cart.length === 0) {
      setMessage('Fill customer details and add at least one item to cart.');
      return;
    }

    setLoading(true);
    setMessage('');

    const request = {
      customerName,
      customerPhone,
      deliveryAddress,
      items: cart.map((item) => ({ productId: item.product.id, quantity: item.quantity }))
    };

    try {
      const response = await fetch('/api/order-requests', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(request)
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Order request submission failed');
      }

      await response.json();
      setCart([]);
      setCustomerName('');
      setCustomerPhone('');
      setDeliveryAddress('');
      setMessage('Order request submitted successfully.');
      fetchOrderRequests();
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const getQuotesForRequest = (requestId: string) => quotes.filter((quote) => quote.orderRequestId === requestId);

  const acceptQuote = async (quoteId: string) => {
    setLoading(true);
    setMessage('');

    try {
      const response = await fetch('/api/quote-accept', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ quoteId })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Quote acceptance failed');
      }

      await response.json();
      setMessage('Quote accepted successfully.');
      fetchOrderRequests();
      fetchQuotes();
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const updateQuoteDraft = (requestId: string, productId: string, field: keyof QuoteDraft[string], value: string) => {
    setQuoteDrafts((current) => ({
      ...current,
      [requestId]: {
        ...current[requestId],
        [productId]: {
          ...current[requestId]?.[productId],
          [field]: value
        }
      }
    }));
  };

  const submitQuote = async (requestId: string) => {
    if (!activeWholesalerId) {
      setMessage('Select a wholesaler first.');
      return;
    }

    const draft = quoteDrafts[requestId] || {};
    const supplierItems = supplierRequests.find((request) => request.id === requestId)?.items ?? [];
    const itemQuotes = supplierItems
      .map((item) => ({
        productId: item.productId,
        quotedPrice: Number(draft[item.productId]?.quotedPrice ?? ''),
        deliveryDays: Number(draft[item.productId]?.deliveryDays ?? ''),
        comment: draft[item.productId]?.comment ?? ''
      }))
      .filter((quote) => !Number.isNaN(quote.quotedPrice) && quote.quotedPrice > 0 && !Number.isNaN(quote.deliveryDays) && quote.deliveryDays > 0);

    if (itemQuotes.length === 0) {
      setMessage('Enter at least one valid quote price and delivery time.');
      return;
    }

    setLoading(true);
    setMessage('');

    try {
      const response = await fetch('/api/quotes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ wholesalerId: activeWholesalerId, orderRequestId: requestId, itemQuotes })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Quote submission failed');
      }

      await response.json();
      setMessage('Quote submitted successfully.');
      fetchSupplierRequests(activeWholesalerId);
      fetchSupplierQuotes(activeWholesalerId);
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const getSupplyableProducts = (request: OrderRequest) => {
    return request.items.filter((item) =>
      products.some(
        (product) =>
          product.wholesalerId === activeWholesalerId &&
          product.generic === item.generic &&
          product.strength === item.strength
      )
    );
  };

  return (
    <div className="page-container">
      <header>
        <div>
          <h1>Pharmacy Connect Hub</h1>
          <p>Order request + supplier quote dashboard for pharmacy procurement.</p>
        </div>
        <div className="role-panel">
          <label>
            View as
            <select value={role} onChange={(event) => setRole(event.target.value as Role)}>
              <option value="pharmacy">Pharmacy</option>
              <option value="supplier">Supplier</option>
            </select>
          </label>
          {role === 'supplier' && (
            <label>
              Supplier
              <select value={activeWholesalerId} onChange={(event) => setActiveWholesalerId(event.target.value)}>
                <option value="">Select wholesaler</option>
                {wholesalers.map((wholesaler) => (
                  <option key={wholesaler.id} value={wholesaler.id}>
                    {wholesaler.name}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>
      </header>

      {role === 'pharmacy' ? (
        <>
          <section className="grid-two">
            <div className="panel">
              <h2>Search products</h2>
              <div className="controls-row">
                <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search name, generic, pack size" />
                <select value={selectedWholesaler} onChange={(event) => setSelectedWholesaler(event.target.value)}>
                  <option value="">All wholesalers</option>
                  {wholesalers.map((wholesaler) => (
                    <option key={wholesaler.id} value={wholesaler.id}>
                      {wholesaler.name}
                    </option>
                  ))}
                </select>
              </div>

              <div className="products-grid">
                {filteredProducts.map((product) => {
                  const wholesaler = wholesalers.find((wh) => wh.id === product.wholesalerId);
                  return (
                    <article key={product.id} className="product-card">
                      <div className="product-card-header">
                        <h3>{product.name}</h3>
                        <span>{product.packSize}</span>
                      </div>
                      <p className="product-meta">{product.generic} • {product.strength}</p>
                      <p className="product-meta">Supplier: {wholesaler?.name}</p>
                      <p className="product-meta">Stock: {product.stock}</p>
                      <div className="product-footer">
                        <strong>GHS {product.price.toFixed(2)}</strong>
                        <button onClick={() => addToCart(product)} disabled={product.stock === 0}>
                          Add to cart
                        </button>
                      </div>
                    </article>
                  );
                })}
                {filteredProducts.length === 0 && <p className="empty-state">No products match your search.</p>}
              </div>
            </div>

            <div className="panel order-panel">
              <h2>Order cart</h2>
              {cart.length === 0 ? (
                <p className="empty-state">Your cart is empty. Add products from wholesalers to place an order.</p>
              ) : (
                <div className="cart-list">
                  {cart.map((item) => (
                    <div key={item.product.id} className="cart-item">
                      <div>
                        <strong>{item.product.name}</strong>
                        <p>{item.product.packSize} • GHS {item.product.price.toFixed(2)}</p>
                        <p>Supplier: {wholesalers.find((wh) => wh.id === item.product.wholesalerId)?.name}</p>
                      </div>
                      <div className="cart-controls">
                        <input type="number" min={1} max={item.product.stock} value={item.quantity} onChange={(event) => updateQuantity(item.product.id, Number(event.target.value))} />
                        <button className="small-danger" onClick={() => removeItem(item.product.id)}>
                          Remove
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              )}

              <div className="summary-box">
                <p>Total items: {cart.reduce((sum, item) => sum + item.quantity, 0)}</p>
                <p>Total cost: GHS {cartTotal.toFixed(2)}</p>
              </div>

              <div className="customer-details">
                <label>
                  Pharmacy name
                  <input value={customerName} onChange={(event) => setCustomerName(event.target.value)} placeholder="e.g. Royal Care Pharmacy" />
                </label>
                <label>
                  Contact phone
                  <input value={customerPhone} onChange={(event) => setCustomerPhone(event.target.value)} placeholder="e.g. +233 24 000 0000" />
                </label>
                <label>
                  Delivery address
                  <textarea value={deliveryAddress} onChange={(event) => setDeliveryAddress(event.target.value)} placeholder="Store location, street, and city" />
                </label>
              </div>

              <button className="primary-button" onClick={submitOrder} disabled={loading || cart.length === 0}>
                {loading ? 'Submitting order...' : 'Submit order'}
              </button>
              {message && <p className="message">{message}</p>}
            </div>
          </section>

          <section className="panel">
            <h2>Order requests & quotes</h2>
            {orderRequests.length === 0 ? (
              <p className="empty-state">No quote requests have been created yet.</p>
            ) : (
              <div className="orders-grid">
                {orderRequests.map((request) => {
                  const requestQuotes = getQuotesForRequest(request.id);
                  const acceptedQuote = requestQuotes.find((quote) => quote.status === 'Accepted');

                  return (
                    <article key={request.id} className="order-card">
                      <h3>{request.customerName}</h3>
                      <p>{request.deliveryAddress}</p>
                      <p>
                        <strong>Status:</strong> {request.status}
                      </p>
                      <p>
                        <strong>Requested:</strong> {new Date(request.createdAt).toLocaleString()}
                      </p>
                      <div className="request-items">
                        {request.items.map((item) => (
                          <div key={item.productId} className="request-item">
                            <strong>{item.productName}</strong>
                            <p>{item.generic} • {item.strength} • {item.packSize}</p>
                            <p>Qty: {item.quantity}</p>
                          </div>
                        ))}
                      </div>
                      <div className="quote-list">
                        <h4>Supplier quotes</h4>
                        {requestQuotes.length === 0 ? (
                          <p className="empty-state">Waiting for supplier quotes.</p>
                        ) : (
                          requestQuotes.map((quote) => (
                            <div key={quote.id} className="quote-card">
                              <div className="quote-heading">
                                <strong>{quote.wholesalerName}</strong>
                                <span>{quote.status}</span>
                              </div>
                              <p>Total: GHS {quote.total.toFixed(2)}</p>
                              <p>Sent: {new Date(quote.createdAt).toLocaleString()}</p>
                              {quote.status === 'Pending' && (
                                <button onClick={() => acceptQuote(quote.id)} disabled={loading || request.status === 'Accepted'}>
                                  Accept this quote
                                </button>
                              )}
                            </div>
                          ))
                        )}
                        {acceptedQuote && (
                          <div className="quote-card accepted-note">
                            <strong>Accepted vendor:</strong> {acceptedQuote.wholesalerName}
                          </div>
                        )}
                      </div>
                    </article>
                  );
                })}
              </div>
            )}
          </section>
        </>
      ) : (
        <section className="panel">
          <h2>Supplier dashboard</h2>
          {!activeWholesalerId ? (
            <p className="empty-state">Select a wholesaler to view quote requests.</p>
          ) : supplierRequests.length === 0 ? (
            <p className="empty-state">No matching quote requests available yet.</p>
          ) : (
            <div className="orders-grid">
              {supplierRequests.map((request) => {
                const supplyableItems = getSupplyableProducts(request);
                return (
                  <article key={request.id} className="order-card">
                    <h3>{request.customerName}</h3>
                    <p>{request.deliveryAddress}</p>
                    <p>
                      <strong>Status:</strong> {request.status}
                    </p>
                    <p>
                      <strong>Requested:</strong> {new Date(request.createdAt).toLocaleString()}
                    </p>
                    <div className="request-items">
                      {request.items.map((item) => {
                        const supplyable = supplyableItems.some((s) => s.productId === item.productId);
                        const draft = quoteDrafts[request.id]?.[item.productId] || { quotedPrice: '', deliveryDays: '', comment: '' };
                        return (
                          <div key={item.productId} className="request-item">
                            <strong>{item.productName}</strong>
                            <p>{item.generic} • {item.strength} • {item.packSize}</p>
                            <p>Qty: {item.quantity}</p>
                            {supplyable ? (
                              <div className="quote-inputs">
                                <input type="number" min={1} placeholder="Price" value={draft.quotedPrice} onChange={(event) => updateQuoteDraft(request.id, item.productId, 'quotedPrice', event.target.value)} />
                                <input type="number" min={1} placeholder="Days" value={draft.deliveryDays} onChange={(event) => updateQuoteDraft(request.id, item.productId, 'deliveryDays', event.target.value)} />
                                <input placeholder="Comment" value={draft.comment} onChange={(event) => updateQuoteDraft(request.id, item.productId, 'comment', event.target.value)} />
                              </div>
                            ) : (
                              <p className="product-meta">This supplier cannot quote this item.</p>
                            )}
                          </div>
                        );
                      })}
                    </div>
                    <button className="primary-button" onClick={() => submitQuote(request.id)} disabled={loading || supplyableItems.length === 0}>
                      Submit quote
                    </button>
                    <div className="quote-list">
                      <h4>My quotes</h4>
                      {supplierQuotes.filter((quote) => quote.orderRequestId === request.id).length === 0 ? (
                        <p className="empty-state">No quote sent for this request yet.</p>
                      ) : (
                        supplierQuotes
                          .filter((quote) => quote.orderRequestId === request.id)
                          .map((quote) => (
                            <div key={quote.id} className="quote-card">
                              <div className="quote-heading">
                                <strong>Quote total</strong>
                                <span>{quote.status}</span>
                              </div>
                              <p>GHS {quote.total.toFixed(2)}</p>
                              <p>Sent: {new Date(quote.createdAt).toLocaleString()}</p>
                            </div>
                          ))
                      )}
                    </div>
                  </article>
                );
              })}
            </div>
          )}
          {message && <p className="message">{message}</p>}
        </section>
      )}
    </div>
  );
}
