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
  status: 'Quote requested' | 'Quotes received' | 'Accepted' | 'Processing' | 'Dispatched' | 'Delivered';
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

type Role = 'pharmacy' | 'supplier' | 'admin';

interface AppUser {
  id: string;
  name: string;
  email: string;
  role: Role;
  wholesalerId?: string;
}

interface AdminUserRow {
  id: string;
  name: string;
  email: string;
  role: Role;
  wholesalerId?: string;
}

const orderStatusFlow = ['Quote requested', 'Quotes received', 'Accepted', 'Processing', 'Dispatched', 'Delivered'] as const;

type QuoteDraft = Record<string, { quotedPrice: string; deliveryDays: string; comment: string }>;

export default function App() {
  const [role, setRole] = useState<Role>('pharmacy');
  const [currentUser, setCurrentUser] = useState<AppUser | null>(null);
  const [loginEmail, setLoginEmail] = useState('');
  const [loginPassword, setLoginPassword] = useState('');
  const [loginError, setLoginError] = useState('');
  const [activeWholesalerId, setActiveWholesalerId] = useState('');
  const [wholesalers, setWholesalers] = useState<Wholesaler[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [cart, setCart] = useState<CartItem[]>([]);
  const [search, setSearch] = useState('');
  const [selectedWholesaler, setSelectedWholesaler] = useState('');
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState('');
  const [compareGeneric, setCompareGeneric] = useState('');
  const [compareStrength, setCompareStrength] = useState('');
  const [orderRequests, setOrderRequests] = useState<OrderRequest[]>([]);
  const [supplierRequests, setSupplierRequests] = useState<OrderRequest[]>([]);
  const [quotes, setQuotes] = useState<Quote[]>([]);
  const [supplierQuotes, setSupplierQuotes] = useState<Quote[]>([]);
  const [customerName, setCustomerName] = useState('');
  const [customerPhone, setCustomerPhone] = useState('');
  const [deliveryAddress, setDeliveryAddress] = useState('');
  const [quoteDrafts, setQuoteDrafts] = useState<Record<string, QuoteDraft>>({});
  const [lastSubmittedRequest, setLastSubmittedRequest] = useState<OrderRequest | null>(null);
  const [newWholesalerName, setNewWholesalerName] = useState('');
  const [newWholesalerLocation, setNewWholesalerLocation] = useState('');
  const [newWholesalerRating, setNewWholesalerRating] = useState('4.5');
  const [newProductWholesalerId, setNewProductWholesalerId] = useState('');
  const [newProductName, setNewProductName] = useState('');
  const [newProductGeneric, setNewProductGeneric] = useState('');
  const [newProductStrength, setNewProductStrength] = useState('');
  const [newProductPackSize, setNewProductPackSize] = useState('');
  const [newProductPrice, setNewProductPrice] = useState('');
  const [newProductStock, setNewProductStock] = useState('');

  // Admin user management
  const [adminUsers, setAdminUsers] = useState<AdminUserRow[]>([]);
  const [newUserName, setNewUserName] = useState('');
  const [newUserEmail, setNewUserEmail] = useState('');
  const [newUserPassword, setNewUserPassword] = useState('');
  const [newUserRole, setNewUserRole] = useState<Role>('pharmacy');
  const [newUserWholesalerId, setNewUserWholesalerId] = useState('');

  // Pharmacy self-registration
  const [showRegister, setShowRegister] = useState(false);
  const [regName, setRegName] = useState('');
  const [regEmail, setRegEmail] = useState('');
  const [regPassword, setRegPassword] = useState('');
  const [regError, setRegError] = useState('');

  useEffect(() => {
    const storedUser = localStorage.getItem('pch-user');
    if (!storedUser) {
      return;
    }

    try {
      const parsedUser = JSON.parse(storedUser) as AppUser;
      setCurrentUser(parsedUser);
      setRole(parsedUser.role);
      setActiveWholesalerId(parsedUser.role === 'supplier' ? parsedUser.wholesalerId ?? '' : '');
    } catch {
      localStorage.removeItem('pch-user');
    }
  }, []);

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
    if (!currentUser) {
      return;
    }

    if (role === 'pharmacy') {
      fetchOrderRequests();
      fetchQuotes();
    }

    if (role === 'supplier' && activeWholesalerId) {
      fetchSupplierRequests(activeWholesalerId);
      fetchSupplierQuotes(activeWholesalerId);
    }

    if (role === 'admin') {
      fetchAdminUsers();
    }
  }, [role, activeWholesalerId, currentUser]);

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

  const login = async () => {
    if (!loginEmail.trim() || !loginPassword) {
      setLoginError('Enter your email and password.');
      return;
    }

    setLoading(true);
    setLoginError('');

    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: loginEmail.trim(), password: loginPassword })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Login failed');
      }

      const data = (await response.json()) as { user: AppUser };
      setCurrentUser(data.user);
      setRole(data.user.role);
      setActiveWholesalerId(data.user.role === 'supplier' ? data.user.wholesalerId ?? '' : '');
      localStorage.setItem('pch-user', JSON.stringify(data.user));
      setLoginPassword('');
    } catch (error) {
      setLoginError((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const logout = () => {
    setCurrentUser(null);
    setRole('pharmacy');
    setActiveWholesalerId('');
    setMessage('');
    setLoginError('');
    localStorage.removeItem('pch-user');
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

  const compareGenericOptions = useMemo(() => {
    return Array.from(new Set(products.map((product) => product.generic))).sort((a, b) => a.localeCompare(b));
  }, [products]);

  const compareStrengthOptions = useMemo(() => {
    if (!compareGeneric) {
      return [];
    }

    return Array.from(new Set(products.filter((product) => product.generic === compareGeneric).map((product) => product.strength))).sort((a, b) => a.localeCompare(b));
  }, [products, compareGeneric]);

  const compareOffers = useMemo(() => {
    if (!compareGeneric) {
      return [];
    }

    return products
      .filter((product) => product.generic === compareGeneric && (compareStrength ? product.strength === compareStrength : true))
      .map((product) => ({
        ...product,
        wholesaler: wholesalers.find((wholesaler) => wholesaler.id === product.wholesalerId)
      }))
      .sort((a, b) => a.price - b.price);
  }, [products, wholesalers, compareGeneric, compareStrength]);

  useEffect(() => {
    if (!compareGenericOptions.length) {
      return;
    }

    if (!compareGeneric || !compareGenericOptions.includes(compareGeneric)) {
      setCompareGeneric(compareGenericOptions[0]);
      setCompareStrength('');
    }
  }, [compareGenericOptions, compareGeneric]);

  useEffect(() => {
    if (!compareStrengthOptions.length) {
      setCompareStrength('');
      return;
    }

    if (compareStrength && !compareStrengthOptions.includes(compareStrength)) {
      setCompareStrength('');
    }
  }, [compareStrengthOptions, compareStrength]);

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

      const createdOrder = (await response.json()) as OrderRequest;
      setLastSubmittedRequest(createdOrder);
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

  const getStatusIndex = (status: OrderRequest['status']) => orderStatusFlow.indexOf(status);

  const getNextSupplierAction = (status: OrderRequest['status']) => {
    if (status === 'Accepted') {
      return 'Mark as processing';
    }
    if (status === 'Processing') {
      return 'Mark as dispatched';
    }
    if (status === 'Dispatched') {
      return 'Mark as delivered';
    }
    return null;
  };

  const advanceOrderStatus = async (orderRequestId: string) => {
    if (!activeWholesalerId) {
      setMessage('Select a wholesaler first.');
      return;
    }

    setLoading(true);
    setMessage('');

    try {
      const response = await fetch('/api/order-status', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ orderRequestId, wholesalerId: activeWholesalerId })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Unable to update order status');
      }

      await response.json();
      setMessage('Order status updated successfully.');
      fetchSupplierRequests(activeWholesalerId);
      fetchSupplierQuotes(activeWholesalerId);
      fetchOrderRequests();
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const createWholesaler = async () => {
    const rating = Number(newWholesalerRating);
    if (!newWholesalerName.trim() || !newWholesalerLocation.trim() || Number.isNaN(rating) || rating < 0 || rating > 5) {
      setMessage('Enter wholesaler name, location, and a rating between 0 and 5.');
      return;
    }

    setLoading(true);
    setMessage('');

    try {
      const response = await fetch('/api/wholesalers', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: newWholesalerName.trim(),
          location: newWholesalerLocation.trim(),
          rating
        })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Failed to create wholesaler');
      }

      setNewWholesalerName('');
      setNewWholesalerLocation('');
      setNewWholesalerRating('4.5');
      const wholesalersResponse = await fetch('/api/wholesalers');
      setWholesalers(await wholesalersResponse.json());
      setMessage('Wholesaler added successfully.');
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const createProduct = async () => {
    const price = Number(newProductPrice);
    const stock = Number(newProductStock);
    if (
      !newProductWholesalerId ||
      !newProductName.trim() ||
      !newProductGeneric.trim() ||
      !newProductStrength.trim() ||
      !newProductPackSize.trim() ||
      Number.isNaN(price) ||
      price <= 0 ||
      Number.isNaN(stock) ||
      stock < 0
    ) {
      setMessage('Enter complete product details, valid price, and stock.');
      return;
    }

    setLoading(true);
    setMessage('');

    try {
      const response = await fetch('/api/products', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          wholesalerId: newProductWholesalerId,
          name: newProductName.trim(),
          generic: newProductGeneric.trim(),
          strength: newProductStrength.trim(),
          packSize: newProductPackSize.trim(),
          price,
          stock
        })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Failed to create product');
      }

      setNewProductWholesalerId('');
      setNewProductName('');
      setNewProductGeneric('');
      setNewProductStrength('');
      setNewProductPackSize('');
      setNewProductPrice('');
      setNewProductStock('');
      const productsResponse = await fetch('/api/products');
      setProducts(await productsResponse.json());
      setMessage('Product added successfully.');
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const fetchAdminUsers = () => {
    fetch('/api/users')
      .then((res) => res.json())
      .then(setAdminUsers)
      .catch(() => setMessage('Unable to load users'));
  };

  const createUser = async () => {
    if (!newUserName.trim() || !newUserEmail.trim() || !newUserPassword || !newUserRole) {
      setMessage('Enter name, email, password, and role for the new account.');
      return;
    }
    if (newUserRole === 'supplier' && !newUserWholesalerId) {
      setMessage('Select a wholesaler for the supplier account.');
      return;
    }

    setLoading(true);
    setMessage('');

    try {
      const response = await fetch('/api/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: newUserName.trim(),
          email: newUserEmail.trim(),
          password: newUserPassword,
          role: newUserRole,
          ...(newUserRole === 'supplier' ? { wholesalerId: newUserWholesalerId } : {})
        })
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Failed to create user');
      }

      setNewUserName('');
      setNewUserEmail('');
      setNewUserPassword('');
      setNewUserRole('pharmacy');
      setNewUserWholesalerId('');
      fetchAdminUsers();
      setMessage('User account created successfully.');
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const deleteUser = async (userId: string) => {
    setLoading(true);
    setMessage('');

    try {
      const response = await fetch(`/api/users/${userId}`, { method: 'DELETE' });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Failed to delete user');
      }

      fetchAdminUsers();
      setMessage('User account removed.');
    } catch (error) {
      setMessage((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  const register = async () => {
    if (!regName.trim() || !regEmail.trim() || !regPassword) {
      setRegError('Enter your name, email, and password.');
      return;
    }

    setLoading(true);
    setRegError('');

    try {
      const createResponse = await fetch('/api/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: regName.trim(), email: regEmail.trim().toLowerCase(), password: regPassword, role: 'pharmacy' })
      });

      if (!createResponse.ok) {
        const error = await createResponse.json();
        throw new Error(error.error || 'Registration failed');
      }

      // Auto sign-in after successful registration
      const loginResponse = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: regEmail.trim().toLowerCase(), password: regPassword })
      });

      if (!loginResponse.ok) {
        throw new Error('Account created. Please sign in.');
      }

      const data = (await loginResponse.json()) as { user: AppUser };
      setCurrentUser(data.user);
      setRole(data.user.role);
      setActiveWholesalerId('');
      localStorage.setItem('pch-user', JSON.stringify(data.user));
      setRegName('');
      setRegEmail('');
      setRegPassword('');
    } catch (error) {
      setRegError((error as Error).message);
    } finally {
      setLoading(false);
    }
  };

  if (!currentUser) {
    return (
      <div className="page-container">
        <section className="panel auth-panel">
          <h1>Pharmacy Connect Hub</h1>
          {showRegister ? (
            <>
              <p>Create a pharmacy account to start ordering.</p>
              <div className="auth-form">
                <input
                  value={regName}
                  onChange={(event) => setRegName(event.target.value)}
                  placeholder="Pharmacy / business name"
                />
                <input
                  type="email"
                  value={regEmail}
                  onChange={(event) => setRegEmail(event.target.value)}
                  placeholder="Email"
                />
                <input
                  type="password"
                  value={regPassword}
                  onChange={(event) => setRegPassword(event.target.value)}
                  placeholder="Password"
                />
                <button onClick={register} disabled={loading}>
                  {loading ? 'Creating account...' : 'Create account'}
                </button>
              </div>
              {regError && <p className="message">{regError}</p>}
              <p className="auth-toggle">
                Already have an account?{' '}
                <button className="link-btn" onClick={() => { setShowRegister(false); setRegError(''); }}>
                  Sign in
                </button>
              </p>
            </>
          ) : (
            <>
              <p>Sign in to access your role-specific workspace.</p>
              <div className="auth-form">
                <input
                  type="email"
                  value={loginEmail}
                  onChange={(event) => setLoginEmail(event.target.value)}
                  placeholder="Email"
                />
                <input
                  type="password"
                  value={loginPassword}
                  onChange={(event) => setLoginPassword(event.target.value)}
                  placeholder="Password"
                />
                <button onClick={login} disabled={loading}>
                  {loading ? 'Signing in...' : 'Sign in'}
                </button>
              </div>
              {loginError && <p className="message">{loginError}</p>}
              <p className="auth-toggle">
                New pharmacy?{' '}
                <button className="link-btn" onClick={() => { setShowRegister(true); setLoginError(''); }}>
                  Create an account
                </button>
              </p>
              <div className="auth-hint">
                <p><strong>Demo accounts</strong></p>
                <p>Admin: admin@pharmacyconnecthub.com / demo123</p>
                <p>Supplier: supplier@pharmacyconnecthub.com / demo123</p>
                <p>Pharmacy: pharmacy@pharmacyconnecthub.com / demo123</p>
              </div>
            </>
          )}
        </section>
      </div>
    );
  }

  return (
    <div className="page-container">
      <header>
        <div>
          <h1>Pharmacy Connect Hub</h1>
          <p>Order request + supplier quote dashboard for pharmacy procurement.</p>
        </div>
        <div className="role-panel session-panel">
          <p>
            <strong>{currentUser.name}</strong>
          </p>
          <p>Role: {currentUser.role}</p>
          {currentUser.role === 'supplier' && (
            <p>Supplier: {wholesalers.find((wholesaler) => wholesaler.id === activeWholesalerId)?.name ?? 'Unassigned'}</p>
          )}
          <button onClick={logout}>Sign out</button>
        </div>
      </header>

      {role === 'pharmacy' ? (
        <>
          <section className="grid-two">
            <div className="panel">
              <h2>Search products</h2>
              <div className="compare-box">
                <div className="compare-header">
                  <h3>Compare wholesaler offers</h3>
                  <p>See who has the best price before adding to cart.</p>
                </div>
                <div className="compare-controls">
                  <select value={compareGeneric} onChange={(event) => setCompareGeneric(event.target.value)}>
                    {compareGenericOptions.length === 0 ? (
                      <option value="">No medicines available</option>
                    ) : (
                      compareGenericOptions.map((generic) => (
                        <option key={generic} value={generic}>
                          {generic}
                        </option>
                      ))
                    )}
                  </select>
                  <select value={compareStrength} onChange={(event) => setCompareStrength(event.target.value)}>
                    <option value="">All strengths</option>
                    {compareStrengthOptions.map((strength) => (
                      <option key={strength} value={strength}>
                        {strength}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="compare-list">
                  {compareOffers.length === 0 ? (
                    <p className="empty-state">No supplier offers match this selection.</p>
                  ) : (
                    compareOffers.map((offer, index) => (
                      <div key={offer.id} className={`compare-offer ${index === 0 ? 'best-offer' : ''}`}>
                        <div>
                          <strong>{offer.wholesaler?.name ?? 'Unknown wholesaler'}</strong>
                          <p>{offer.packSize} • Stock: {offer.stock}</p>
                        </div>
                        <div className="compare-price">
                          {index === 0 && <span className="badge">Best price</span>}
                          <strong>GHS {offer.price.toFixed(2)}</strong>
                        </div>
                      </div>
                    ))
                  )}
                </div>
              </div>
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
              {lastSubmittedRequest && (
                <div className="confirmation-box">
                  <div className="quote-heading">
                    <strong>Last order confirmation</strong>
                    <button onClick={() => window.print()}>Print summary</button>
                  </div>
                  <p><strong>Request ID:</strong> {lastSubmittedRequest.id}</p>
                  <p><strong>Pharmacy:</strong> {lastSubmittedRequest.customerName}</p>
                  <p><strong>Address:</strong> {lastSubmittedRequest.deliveryAddress}</p>
                  <p><strong>Status:</strong> {lastSubmittedRequest.status}</p>
                  <p><strong>Submitted:</strong> {new Date(lastSubmittedRequest.createdAt).toLocaleString()}</p>
                </div>
              )}
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
                      <div className="status-track">
                        {orderStatusFlow.map((statusLabel) => (
                          <span
                            key={`${request.id}-${statusLabel}`}
                            className={`status-step ${getStatusIndex(request.status) >= getStatusIndex(statusLabel) ? 'done' : ''}`}
                          >
                            {statusLabel}
                          </span>
                        ))}
                      </div>
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
                              <div className="quote-items">
                                {quote.items.map((item) => (
                                  <div key={item.productId} className="quote-item-row">
                                    <p>
                                      <strong>{item.productName}</strong> - GHS {item.quotedPrice.toFixed(2)} each
                                    </p>
                                    <p>Delivery: {item.deliveryDays} day(s)</p>
                                    {item.comment && <p>Note: {item.comment}</p>}
                                  </div>
                                ))}
                              </div>
                              {quote.status === 'Pending' && (
                                <button onClick={() => acceptQuote(quote.id)} disabled={loading || request.status !== 'Quotes received'}>
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
      ) : role === 'supplier' ? (
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
                const acceptedSupplierQuote = supplierQuotes.find(
                  (quote) => quote.orderRequestId === request.id && quote.status === 'Accepted'
                );
                const nextSupplierAction = getNextSupplierAction(request.status);
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
                    <button
                      className="primary-button"
                      onClick={() => submitQuote(request.id)}
                      disabled={
                        loading ||
                        supplyableItems.length === 0 ||
                        (request.status !== 'Quote requested' && request.status !== 'Quotes received')
                      }
                    >
                      Submit quote
                    </button>
                    {acceptedSupplierQuote && nextSupplierAction && (
                      <button className="status-action" onClick={() => advanceOrderStatus(request.id)} disabled={loading}>
                        {nextSupplierAction}
                      </button>
                    )}
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
                              <div className="quote-items">
                                {quote.items.map((item) => (
                                  <div key={item.productId} className="quote-item-row">
                                    <p>
                                      <strong>{item.productName}</strong> - GHS {item.quotedPrice.toFixed(2)} each
                                    </p>
                                    <p>Delivery: {item.deliveryDays} day(s)</p>
                                    {item.comment && <p>Note: {item.comment}</p>}
                                  </div>
                                ))}
                              </div>
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
      ) : (
        <section className="panel">
          <h2>Admin workspace</h2>
          <p className="product-meta">Onboard wholesalers and publish products into the marketplace catalog.</p>

          <div className="admin-grid">
            <article className="form-card">
              <h3>Add wholesaler</h3>
              <div className="quote-inputs">
                <input
                  value={newWholesalerName}
                  onChange={(event) => setNewWholesalerName(event.target.value)}
                  placeholder="Wholesaler name"
                />
                <input
                  value={newWholesalerLocation}
                  onChange={(event) => setNewWholesalerLocation(event.target.value)}
                  placeholder="Location"
                />
                <input
                  type="number"
                  min={0}
                  max={5}
                  step="0.1"
                  value={newWholesalerRating}
                  onChange={(event) => setNewWholesalerRating(event.target.value)}
                  placeholder="Rating"
                />
                <button onClick={createWholesaler} disabled={loading}>Add wholesaler</button>
              </div>
            </article>

            <article className="form-card">
              <h3>Add product</h3>
              <div className="quote-inputs">
                <select value={newProductWholesalerId} onChange={(event) => setNewProductWholesalerId(event.target.value)}>
                  <option value="">Select wholesaler</option>
                  {wholesalers.map((wholesaler) => (
                    <option key={wholesaler.id} value={wholesaler.id}>
                      {wholesaler.name}
                    </option>
                  ))}
                </select>
                <input value={newProductName} onChange={(event) => setNewProductName(event.target.value)} placeholder="Product name" />
                <input value={newProductGeneric} onChange={(event) => setNewProductGeneric(event.target.value)} placeholder="Generic name" />
                <div className="inline-grid">
                  <input value={newProductStrength} onChange={(event) => setNewProductStrength(event.target.value)} placeholder="Strength" />
                  <input value={newProductPackSize} onChange={(event) => setNewProductPackSize(event.target.value)} placeholder="Pack size" />
                </div>
                <div className="inline-grid">
                  <input type="number" min={0} step="0.01" value={newProductPrice} onChange={(event) => setNewProductPrice(event.target.value)} placeholder="Price (GHS)" />
                  <input type="number" min={0} step="1" value={newProductStock} onChange={(event) => setNewProductStock(event.target.value)} placeholder="Stock" />
                </div>
                <button onClick={createProduct} disabled={loading}>Add product</button>
              </div>
            </article>
          </div>

          <div className="admin-grid">
            <article className="form-card">
              <h3>Wholesalers ({wholesalers.length})</h3>
              <div className="list-stack">
                {wholesalers.map((wholesaler) => (
                  <div key={wholesaler.id} className="quote-item-row">
                    <p><strong>{wholesaler.name}</strong></p>
                    <p>{wholesaler.location}</p>
                    <p>Rating: {wholesaler.rating.toFixed(1)}</p>
                  </div>
                ))}
              </div>
            </article>

            <article className="form-card">
              <h3>Products ({products.length})</h3>
              <div className="list-stack">
                {products.map((product) => (
                  <div key={product.id} className="quote-item-row">
                    <p><strong>{product.name}</strong></p>
                    <p>{product.generic} - {product.strength}</p>
                    <p>GHS {product.price.toFixed(2)} - Stock {product.stock}</p>
                  </div>
                ))}
              </div>
            </article>
          </div>

          <h3 className="admin-section-title">User accounts</h3>
          <div className="admin-grid">
            <article className="form-card">
              <h3>Create account</h3>
              <div className="quote-inputs">
                <input
                  value={newUserName}
                  onChange={(event) => setNewUserName(event.target.value)}
                  placeholder="Full name"
                />
                <input
                  type="email"
                  value={newUserEmail}
                  onChange={(event) => setNewUserEmail(event.target.value)}
                  placeholder="Email address"
                />
                <input
                  type="password"
                  value={newUserPassword}
                  onChange={(event) => setNewUserPassword(event.target.value)}
                  placeholder="Password"
                />
                <select value={newUserRole} onChange={(event) => { setNewUserRole(event.target.value as Role); setNewUserWholesalerId(''); }}>
                  <option value="pharmacy">Pharmacy</option>
                  <option value="supplier">Supplier</option>
                  <option value="admin">Admin</option>
                </select>
                {newUserRole === 'supplier' && (
                  <select value={newUserWholesalerId} onChange={(event) => setNewUserWholesalerId(event.target.value)}>
                    <option value="">Select wholesaler</option>
                    {wholesalers.map((wh) => (
                      <option key={wh.id} value={wh.id}>{wh.name}</option>
                    ))}
                  </select>
                )}
                <button onClick={createUser} disabled={loading}>Create account</button>
              </div>
            </article>

            <article className="form-card">
              <h3>Accounts ({adminUsers.length})</h3>
              <div className="list-stack">
                {adminUsers.length === 0 ? (
                  <p className="empty-state">No accounts loaded.</p>
                ) : (
                  adminUsers.map((user) => (
                    <div key={user.id} className="quote-item-row user-row">
                      <div>
                        <p><strong>{user.name}</strong></p>
                        <p>{user.email}</p>
                        <p>Role: <span className={`role-badge role-${user.role}`}>{user.role}</span>
                          {user.role === 'supplier' && user.wholesalerId && (
                            <> · {wholesalers.find((wh) => wh.id === user.wholesalerId)?.name ?? user.wholesalerId}</>
                          )}
                        </p>
                      </div>
                      {user.id !== currentUser?.id && (
                        <button className="small-danger" onClick={() => deleteUser(user.id)} disabled={loading}>
                          Remove
                        </button>
                      )}
                    </div>
                  ))
                )}
              </div>
            </article>
          </div>

          {message && <p className="message">{message}</p>}
        </section>
      )}
    </div>
  );
}
