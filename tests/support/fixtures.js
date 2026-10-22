// Deterministic fixture data shaped like the Supabase tables/views the app reads.
const NOW = Date.parse("2026-10-22T09:00:00Z");
const hoursAgo = h => new Date(NOW - h * 3600e3).toISOString();

const sets = [
  { id: 10, name: "Base Set", game_id: "pokemon", series_id: 1, release_date: "1999-01-09", language: "EN" },
  { id: 11, name: "Jungle", game_id: "pokemon", series_id: 1, release_date: "1999-06-16", language: "EN" },
];
const series = [{ id: 1, name: "Original Series", game_id: "pokemon", sort_order: 1 }];

const P = (id, name, extra = {}) => ({ id, name, card_number: String(id) + "/102", variant: null, language: "EN", kind: "card",
  image_url: null, game_id: "pokemon", set_id: 10, rarity: "Rare Holo", special: null, ...extra });
const products = [
  P(1, "Charizard"),                                   // sold price exists (and an ask too: sold must win)
  P(2, "Blastoise"),                                   // no sold, ask with enough listings
  P(3, "Venusaur"),                                    // no sold, thin ask (2 listings)
  P(4, "Pikachu", { rarity: "Common" }),               // nothing at all
  P(5, "Base Set Booster Box", { kind: "sealed", card_number: null, rarity: null }), // sealed ask
  P(6, "Mewtwo"),                                      // owned graded PSA 10; asks for raw and PSA 10
  P(7, "Gyarados"),                                    // owned LP raw; only an NM ask exists
];
const byId = new Map(products.map(p => [p.id, p]));

const line = (id, pid, quantity, condition, grade = "") =>
  ({ id, quantity, condition, grade, date_added: "2026-01-0" + (id % 9 + 1), cost_paid: null, product_id: pid, products: byId.get(pid) });
const collection_items = [
  line(101, 1, 2, "NM"), line(102, 2, 1, "NM"), line(103, 3, 1, "NM"), line(104, 4, 1, "NM"),
  line(105, 5, 1, "NM"), line(106, 6, 1, "NM", "PSA 10"), line(107, 7, 1, "LP"),
];
const ownedIds = new Set(collection_items.map(c => c.product_id));
const catalog_v = products.map(p => {
  const s = sets.find(x => x.id === p.set_id);
  return { ...p, set_name: s.name, release_date: s.release_date, series_id: s.series_id, owned: ownedIds.has(p.id), created_at: "2026-01-01" };
});

const price_v = [
  { product_id: 1, condition: "NM", grade: "", median: 300, sales: 8, last_sold: hoursAgo(30) },
  { product_id: 1, condition: "NM", grade: "PSA 10", median: 900, sales: 3, last_sold: hoursAgo(50) },
];
const sold_review_v = [1, 2, 3, 4].map(i => ({ id: 900 + i, product_id: 1, market: "AU", condition: "NM", grade: "",
  title: "Charizard Base Set sale " + i, url: "https://www.ebay.com.au/itm/sold" + i, price: 290 + i * 5,
  sold_at: hoursAgo(24 * i), credible: i !== 4, exclusion_reason: i === 4 ? "Outlier: too low" : null, user_decision: null }));

const ask = (product_id, condition, grade, median, low, listings, h = 3) => ({ product_id, market: "AU", condition, grade,
  median_ask_aud: median, low_ask_aud: low, listings, enough_listings: listings >= 4, updated_at: hoursAgo(h), basis: "asking (eBay active listings)" });
const ask_price_v = [
  ask(1, "NM", "", 350, 320, 9),
  ask(2, "NM", "", 120, 95, 6),
  ask(3, "NM", "", 80, 60, 2),
  ask(5, "Sealed", "", 5000, 4800, 5),
  ask(6, "NM", "", 50, 40, 7),
  ask(6, "NM", "PSA 10", 400, 380, 4),
  ask(7, "NM", "", 30, 25, 5),
];
let lid = 5000;
const L = (product_id, price, title, grade = "", excluded = false, condition = "NM") => ({ id: ++lid, product_id, market: "AU", condition, grade,
  price, currency: "AUD", title, url: "https://www.ebay.com.au/itm/" + lid, image_url: null, ebay_item_id: String(lid), excluded,
  exclusion_reason: excluded ? "Proxy / fake" : null, first_seen: hoursAgo(48), last_seen: hoursAgo(3) });
const ask_listings = [
  L(2, 130, "Blastoise 2/102 Base Set Holo"), L(2, 95, "Blastoise Base Holo NM"), L(2, 120, "Blastoise Holo Rare"),
  L(2, 1, "Blastoise PROXY custom card", "", true), L(2, 150, "Blastoise 2/102"), L(2, 110, "Blastoise unlimited"),
  L(2, 115, "Blastoise base set"),
  ...Array.from({ length: 12 }, (_, i) => L(6, 40 + i, "Mewtwo listing " + (i + 1))),
  L(6, 380, "Mewtwo PSA 10 Base Set", "PSA 10"),
];

const carts = [{ id: 1, name: "Trade night", status: "open", created_at: "2026-10-01", buy_discount: 0, buy_discount_mode: "$", sell_discount: 0, sell_discount_mode: "$" }];
const cart_items = [
  { id: 1, cart_id: 1, product_id: 1, side: "buy", condition: "NM", grade: "", quantity: 1, unit_price: null, products: byId.get(1) },
  { id: 2, cart_id: 1, product_id: 2, side: "sell", condition: "NM", grade: "", quantity: 1, unit_price: null, products: byId.get(2) },
];

function tables(){
  return structuredClone({ sets, series, products, collection_items, catalog_v, price_v, sold_review_v, ask_price_v, ask_listings, carts, cart_items,
    portfolio_snapshots: [], set_ratio_v: [], upcoming_sets: [], news_items: [], profiles: [], follows: [], listings: [], offers: [], profile_contacts: [] });
}
module.exports = { tables, NOW };
