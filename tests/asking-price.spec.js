// Asking-price fallback (PRICE_FALLBACK_ASKING on). Fixture data: tests/support/fixtures.js
const { test, expect } = require("@playwright/test");
const { open, tab } = require("./support/mock");

const TIP = "Asking price. Based on current eBay listings, not completed sales. Will switch to sold prices when available.";
const tileOf = (page, name) => page.locator(".tile", { has: page.locator(".name", { hasText: new RegExp("^" + name + "$") }) });
const priceOfTile = (page, name) => tileOf(page, name).locator(".price .v");
const openCol = async (page, opts) => { const ctx = await open(page, opts); await tab(page, "My collection"); await expect(page.locator("#sum")).toContainText("lines"); return ctx; };
const openCard = async (page, name) => { await tileOf(page, name).locator(".name").click(); await expect(page.locator("#sheet h2")).toHaveText(name); };

test.describe("rule 2: sold first, asking only as fallback", () => {
  test("sold price wins even when an ask exists", async ({ page }) => {
    await openCol(page, { flag: true });
    await expect(priceOfTile(page, "Charizard")).toHaveText("$300.00");
    await expect(tileOf(page, "Charizard").locator(".askb")).toHaveCount(0);
  });
  test("no sold price falls back to the median ask", async ({ page }) => {
    await openCol(page, { flag: true });
    await expect(priceOfTile(page, "Blastoise")).toHaveText("ASK$120.00");
    await expect(priceOfTile(page, "Base Set Booster Box")).toHaveText("ASK$5,000.00");
  });
  test("card detail shows no asking figure when sold exists", async ({ page }) => {
    await openCol(page, { flag: true });
    await openCard(page, "Charizard");
    await expect(page.locator("#askbox")).toContainText("No current eBay listings found.");
    await expect(page.locator("#askbox")).not.toContainText("Asking price $");
    await expect(page.locator("#soldbox")).toContainText("$300.00");
  });
});

test.describe("rule 3: asking figures are labelled", () => {
  test("tiles carry the ASK badge, muted style and tooltip", async ({ page }) => {
    await openCol(page, { flag: true });
    const v = priceOfTile(page, "Blastoise");
    await expect(v.locator(".askb")).toHaveText("ASK");
    await expect(v).toHaveClass(/askv/);
    await expect(v).not.toHaveClass(/\bok\b/);
    await expect(v).toHaveAttribute("title", TIP);
  });
  test("card detail says Asking price with the info text", async ({ page }) => {
    await openCol(page, { flag: true });
    await openCard(page, "Blastoise");
    const sheet = page.locator("#sheet");
    await expect(sheet.locator(".box", { hasText: "In your collection" })).toContainText("1 × Near Mint — ASKAsking price $120.00 each");
    await expect(sheet.locator("#askbox")).toContainText("ASKAsking price $120.00");
    await expect(sheet.locator("#askbox")).toContainText("Based on current eBay listings, not completed sales. Will switch to sold prices when available.");
    const row = sheet.locator(".box", { hasText: "Prices by quality" }).locator("tr.askrow");
    await expect(row).toHaveCount(1);
    await expect(row).toContainText("Near MintASK$120.00");
    await expect(row.locator(".askv")).toHaveAttribute("title", TIP);
  });
});

test.describe("rule 4: thin data and no data", () => {
  test("fewer than 4 listings shows From low ask with count", async ({ page }) => {
    await openCol(page, { flag: true });
    await expect(priceOfTile(page, "Venusaur")).toHaveText("ASKFrom $60.00 · 2 listings");
    await openCard(page, "Venusaur");
    await expect(page.locator("#askbox")).toContainText("Asking price From $60.00 · 2 listings");
    await expect(page.locator("#askbox")).toContainText("too few for a median");
    await expect(page.locator("#askbox")).not.toContainText("$80.00");
  });
  test("no ask row shows No price yet", async ({ page }) => {
    await openCol(page, { flag: true });
    await expect(priceOfTile(page, "Pikachu")).toHaveText("No price yet");
    await openCard(page, "Pikachu");
    await expect(page.locator(".box", { hasText: "In your collection" })).toContainText("1 × Near Mint — no price yet");
  });
});

test.describe("rule 5: totals keep sold and asking apart", () => {
  test("collection summary", async ({ page }) => {
    await openCol(page, { flag: true });
    // sold: Charizard 2 × 300. asking: Blastoise 120 + Venusaur from 60 + box 5000 + Mewtwo PSA 10 400. unpriced: Pikachu, Gyarados LP
    await expect(page.locator("#sum")).toContainText("8 items · 7 lines · $600.00 raw value · ASK$5,580.00 asking price · 2 items unpriced · 1 of 7 lines priced");
    await expect(page.locator("#asktotal")).toHaveAttribute("title", TIP);
  });
  test("investment tab", async ({ page }) => {
    await openCol(page, { flag: true });
    await tab(page, "Investment");
    await expect(page.locator(".bigv")).toHaveText("$600.00");
    await expect(page.locator("#askinv")).toHaveText("ASK$5,580.00 asking price · not included above · 2 items unpriced");
  });
});

test.describe("rule 6: no asking prices in carts / net", () => {
  test("unpriced cart lines say Needs sold data and stay out of the net", async ({ page }) => {
    await openCol(page, { flag: true });
    await tab(page, "Carts");
    const sell = page.locator(".side.sell");
    await expect(sell.locator(".lt")).toHaveText("Needs sold data");
    await expect(sell.locator("h3")).toHaveText("Sell $0.00");
    await expect(sell.locator(".pricein")).toHaveAttribute("placeholder", "Price");
    await expect(page.locator(".net .big")).toHaveText("You pay $300.00");
    await expect(page.locator("#netwarn")).toContainText("Needs sold data");
    await expect(page.locator("#cartview")).not.toContainText("ASK");
  });
  test("P&L and arbitrage never use asking prices", async ({ page }) => {
    await openCol(page, { flag: true, mutate: db => { db.collection_items.find(c => c.product_id === 2).cost_paid = 50; } });
    await tab(page, "Investment");
    // only Blastoise has a cost, and it has an ask but no sold price: no profit may be computed from the ask
    await expect(page.locator("#pnl")).toContainText(/Unrealised profit\s*Needs sold data/);
    await expect(page.locator("#pnl")).toContainText(/Market value \(raw\)\s*\$600\.00/);
    await expect(page.locator("#arb")).toContainText("Needs sold data.");
    await expect(page.locator("#arb tbody tr")).toHaveCount(0);
  });
  test("per-copy profit is not shown from an asking price", async ({ page }) => {
    await openCol(page, { flag: true, mutate: db => { db.collection_items.find(c => c.product_id === 2).cost_paid = 50; } });
    await expect(priceOfTile(page, "Blastoise")).toHaveText("ASK$120.00");
    await expect(tileOf(page, "Blastoise").locator(".profit")).toHaveCount(0);
  });
});

test.describe("rule 7: current eBay listings on card detail", () => {
  test("lowest first, excluded rows hidden, links open in a new tab, updated time", async ({ page }) => {
    await openCol(page, { flag: true });
    await openCard(page, "Blastoise");
    const box = page.locator("#askbox");
    await expect(box.locator("h3")).toHaveText("Current eBay listings");
    await expect(box.locator(".sale b")).toHaveText(["$95.00", "$110.00", "$115.00", "$120.00", "$130.00", "$150.00"]);
    await expect(box).not.toContainText("PROXY");
    const link = box.locator(".sale a").first();
    await expect(link).toHaveText("Blastoise Base Holo NM");
    await expect(link).toHaveAttribute("target", "_blank");
    await expect(link).toHaveAttribute("href", /^https:\/\/www\.ebay\.com\.au\/itm\//);
    await expect(box.locator(".sale").first()).toContainText("Raw");
    await expect(box).toContainText("Updated 3 h ago");
    // the existing sold section is still there, unchanged
    await expect(page.locator("#soldbox")).toContainText("No credible eBay AU sales recorded yet for Near Mint.");
  });
  test("at most 10 listings, grade shown", async ({ page }) => {
    await openCol(page, { flag: true });
    await openCard(page, "Mewtwo");
    const box = page.locator("#askbox");
    await expect(box.locator(".sale")).toHaveCount(10);
    await expect(box.locator(".sale b").first()).toHaveText("$40.00");
    await expect(box.locator(".sale b").last()).toHaveText("$49.00");
  });
});

test.describe("rule 8: graded vs raw", () => {
  test("graded copy uses the matching grade's ask", async ({ page }) => {
    await openCol(page, { flag: true });
    await expect(priceOfTile(page, "Mewtwo")).toHaveText("ASK$400.00");
    await openCard(page, "Mewtwo");
    await expect(page.locator(".box", { hasText: "In your collection" })).toContainText("1 × Near Mint · PSA 10 — ASKAsking price $400.00 each");
    await expect(page.locator("#askbox")).toContainText("Asking price $400.00");
  });
  test("raw copy in another condition does not borrow the NM ask", async ({ page }) => {
    await openCol(page, { flag: true });
    await expect(priceOfTile(page, "Gyarados")).toHaveText("No price yet");
  });
  test("catalog (one raw NM of each) uses the raw ask", async ({ page }) => {
    await open(page, { flag: true });
    await expect(priceOfTile(page, "Mewtwo")).toHaveText("ASK$50.00");
    await expect(priceOfTile(page, "Gyarados")).toHaveText("ASK$30.00");
  });
});

test.describe("rule 9: feature flag", () => {
  test("flag off: no asking data is requested or shown", async ({ page }) => {
    const { log } = await open(page, { flag: false });
    await openCard(page, "Blastoise");
    await expect(page.locator("#soldbox")).toContainText("No credible eBay AU sales recorded yet");
    await page.locator("#x").click();
    await tab(page, "Catalog"); await expect(page.locator(".tile").first()).toBeVisible();
    expect(log.filter(r => /^ask_/.test(r.table))).toEqual([]);
    await expect(page.locator("body")).not.toContainText("ASK");
  });
  test("the shipped default is on", async () => {
    const html = require("fs").readFileSync(require("path").join(__dirname, "../index.html"), "utf8");
    expect(html.match(/const PRICE_FALLBACK_ASKING = (true|false);/g)).toEqual(["const PRICE_FALLBACK_ASKING = true;"]);
  });
});

test.describe("rule 10: batched queries", () => {
  test("collection loads all asks in one batched request", async ({ page }) => {
    const { log } = await openCol(page, { flag: true });
    const reqs = log.filter(r => r.table === "ask_price_v");
    expect(reqs).toHaveLength(1);
    expect(reqs[0].params.product_id).toBe("in.(1,2,3,4,5,6,7)");
    expect(reqs[0].params.market).toBe("eq.AU");
  });
  test("catalog grid batches only products not yet loaded", async ({ page }) => {
    const { log } = await open(page, { flag: true, mutate: db => {
      for (const id of [8, 9]) db.catalog_v.push({ ...db.catalog_v[3], id, name: "Extra " + id, owned: false });
      db.ask_price_v.push({ ...db.ask_price_v[1], product_id: 9, median_ask_aud: 77 });
    } });
    await tab(page, "Catalog");
    await expect(priceOfTile(page, "Extra 9")).toHaveText("ASK$77.00");
    const reqs = log.filter(r => r.table === "ask_price_v");
    expect(reqs.map(r => r.params.product_id)).toEqual(["in.(1,2,3,4,5,6,7)", "in.(8,9)"]);
  });
});
