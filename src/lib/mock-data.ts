export type Wholesaler = {
  id: string;
  name: string;
  location: string;
  rating: number;
  verified: boolean;
};

export type Product = {
  id: string;
  name: string;
  brand: string;
  category: string;
  form: string; // tablet, syrup, injection
  packSize: string;
  price: number; // GHS
  stock: number;
  wholesalerId: string;
  imageHue: number;
};

export type CartItem = {
  productId: string;
  quantity: number;
};

export type OrderStatus = "pending" | "processing" | "fulfilled" | "cancelled";

export type Order = {
  id: string;
  pharmacyName: string;
  wholesalerId: string;
  items: { productId: string; productName: string; quantity: number; price: number }[];
  total: number;
  status: OrderStatus;
  createdAt: string;
};

export const wholesalers: Wholesaler[] = [
  { id: "w1", name: "Pokupharma Ltd.", location: "Accra, Greater Accra", rating: 4.8, verified: true },
  { id: "w2", name: "Ernest Chemists Wholesale", location: "Tema, Greater Accra", rating: 4.7, verified: true },
  { id: "w3", name: "Kinapharma Distribution", location: "Kumasi, Ashanti", rating: 4.6, verified: true },
  { id: "w4", name: "Letap Pharmaceuticals", location: "Takoradi, Western", rating: 4.5, verified: true },
];

export const categories = [
  "Antibiotics",
  "Analgesics",
  "Antimalarials",
  "Antihypertensives",
  "Vitamins & Supplements",
  "Antidiabetics",
  "Antacids",
  "Cough & Cold",
];

export const products: Product[] = [
  { id: "p1", name: "Amoxicillin 500mg", brand: "Aurobindo", category: "Antibiotics", form: "Capsule", packSize: "100s", price: 28.5, stock: 240, wholesalerId: "w1", imageHue: 195 },
  { id: "p2", name: "Paracetamol 500mg", brand: "GSK", category: "Analgesics", form: "Tablet", packSize: "1000s", price: 42.0, stock: 580, wholesalerId: "w1", imageHue: 70 },
  { id: "p3", name: "Artemether/Lumefantrine 80/480", brand: "Novartis", category: "Antimalarials", form: "Tablet", packSize: "24s", price: 18.75, stock: 120, wholesalerId: "w2", imageHue: 30 },
  { id: "p4", name: "Amlodipine 10mg", brand: "Cipla", category: "Antihypertensives", form: "Tablet", packSize: "30s", price: 12.4, stock: 320, wholesalerId: "w2", imageHue: 320 },
  { id: "p5", name: "Vitamin C 1000mg", brand: "HealthAid", category: "Vitamins & Supplements", form: "Tablet", packSize: "60s", price: 35.0, stock: 410, wholesalerId: "w3", imageHue: 50 },
  { id: "p6", name: "Metformin 850mg", brand: "Merck", category: "Antidiabetics", form: "Tablet", packSize: "60s", price: 22.0, stock: 180, wholesalerId: "w3", imageHue: 230 },
  { id: "p7", name: "Omeprazole 20mg", brand: "Dr. Reddy's", category: "Antacids", form: "Capsule", packSize: "30s", price: 16.9, stock: 260, wholesalerId: "w4", imageHue: 280 },
  { id: "p8", name: "Ciprofloxacin 500mg", brand: "Bayer", category: "Antibiotics", form: "Tablet", packSize: "100s", price: 48.0, stock: 90, wholesalerId: "w1", imageHue: 195 },
  { id: "p9", name: "Ibuprofen 400mg", brand: "Reckitt", category: "Analgesics", form: "Tablet", packSize: "100s", price: 24.5, stock: 470, wholesalerId: "w2", imageHue: 10 },
  { id: "p10", name: "Loratadine 10mg", brand: "Sandoz", category: "Cough & Cold", form: "Tablet", packSize: "30s", price: 9.8, stock: 350, wholesalerId: "w3", imageHue: 150 },
  { id: "p11", name: "Diclofenac 50mg", brand: "Voltaren", category: "Analgesics", form: "Tablet", packSize: "100s", price: 31.2, stock: 210, wholesalerId: "w4", imageHue: 0 },
  { id: "p12", name: "Losartan 50mg", brand: "Cipla", category: "Antihypertensives", form: "Tablet", packSize: "30s", price: 14.6, stock: 290, wholesalerId: "w1", imageHue: 320 },
];

export const sampleOrders: Order[] = [
  {
    id: "ORD-1042",
    pharmacyName: "Goodlife Pharmacy, East Legon",
    wholesalerId: "w1",
    items: [
      { productId: "p1", productName: "Amoxicillin 500mg", quantity: 5, price: 28.5 },
      { productId: "p2", productName: "Paracetamol 500mg", quantity: 3, price: 42.0 },
    ],
    total: 268.5,
    status: "pending",
    createdAt: "2 hours ago",
  },
  {
    id: "ORD-1041",
    pharmacyName: "Topcare Pharmacy, Tema",
    wholesalerId: "w1",
    items: [{ productId: "p8", productName: "Ciprofloxacin 500mg", quantity: 2, price: 48.0 }],
    total: 96.0,
    status: "processing",
    createdAt: "Yesterday",
  },
  {
    id: "ORD-1039",
    pharmacyName: "Unichem Pharmacy, Adabraka",
    wholesalerId: "w1",
    items: [
      { productId: "p12", productName: "Losartan 50mg", quantity: 10, price: 14.6 },
      { productId: "p2", productName: "Paracetamol 500mg", quantity: 2, price: 42.0 },
    ],
    total: 230.0,
    status: "fulfilled",
    createdAt: "3 days ago",
  },
];

export const pharmacyOrderHistory: Order[] = [
  {
    id: "ORD-1042",
    pharmacyName: "You",
    wholesalerId: "w1",
    items: [
      { productId: "p1", productName: "Amoxicillin 500mg", quantity: 5, price: 28.5 },
      { productId: "p2", productName: "Paracetamol 500mg", quantity: 3, price: 42.0 },
    ],
    total: 268.5,
    status: "pending",
    createdAt: "2 hours ago",
  },
  {
    id: "ORD-1038",
    pharmacyName: "You",
    wholesalerId: "w2",
    items: [{ productId: "p3", productName: "Artemether/Lumefantrine 80/480", quantity: 4, price: 18.75 }],
    total: 75.0,
    status: "fulfilled",
    createdAt: "5 days ago",
  },
  {
    id: "ORD-1031",
    pharmacyName: "You",
    wholesalerId: "w3",
    items: [{ productId: "p5", productName: "Vitamin C 1000mg", quantity: 2, price: 35.0 }],
    total: 70.0,
    status: "fulfilled",
    createdAt: "2 weeks ago",
  },
];

export function formatGHS(amount: number): string {
  return `GH₵ ${amount.toFixed(2)}`;
}

export function getWholesaler(id: string): Wholesaler | undefined {
  return wholesalers.find((w) => w.id === id);
}

export function getProduct(id: string): Product | undefined {
  return products.find((p) => p.id === id);
}
