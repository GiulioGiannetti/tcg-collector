// Stage 0 characterisation tests: pin down what the touched screens show today.
// They run with PRICE_FALLBACK_ASKING forced off, which must reproduce today's behaviour exactly.
// The "sold-priced items" block re-runs the sold-based assertions with the flag on.
const { test, expect } = require("@playwright/test");
const { open, tab } = require("./support/mock");

const tileOf = (page, name) => page.locator(".tile", { has: page.locator(".name", { hasText: new RegExp("^" + name + "$") }) });
const withCost = db => { db.collection_items.find(c => c.product_id === 1).cost_paid = 200; };
const withArb = db => { db.arbitrage_v = [{ product_id: 1, condition: "NM", grade: "", other_market: "US", other_price: 150, au_price: 300, gap_pct: 50 }]; };

for (const flag of [false, true]) {
  test.describe("characterisation, sold-priced items (flag " + (flag ? "on" : "off") + ")", () => {
    test("collection tile shows the sold median", async ({ page }) => {
      await open(page, { flag });
      await tab(page, "My collection");
      await expect(tileOf(page, "Charizard").locator(".price .v")).toHaveText("$300.00");
      await expect(tileOf(page, "Charizard").locator(".price .v")).toHaveClass(/ok/);
    });
    test("card detail: collection line, quality table and sold box", async ({ page }) => {
      await open(page, { flag });
      await tab(page, "My collection");
      await tileOf(page, "Charizard").locator(".name").click();
      const sheet = page.locator("#sheet");
      await expect(sheet.locator("h2")).toHaveText("Charizard");
      await expect(sheet.locator(".box", { hasText: "In your collection" })).toContainText("2 × Near Mint — $300.00 each");
      const qt = sheet.locator(".box", { hasText: "Prices by quality" });
      await expect(qt.locator("thead")).toHaveText(/Quality\s*Median sold\s*Sales\s*Population/);
      await expect(qt.locator("tbody tr")).toHaveCount(2);
      await expect(qt.locator("tbody tr").nth(0)).toContainText("PSA 10$900.003");
      await expect(qt.locator("tbody tr").nth(1)).toContainText("Near Mint$300.008");
      const sold = sheet.locator("#soldbox");
      await expect(sold).toContainText("$300.00");
      await expect(sold).toContainText("Median of the latest 3 credible eBay AU sales · low confidence (few sales)");
      await expect(sold).toContainText("Last 3 credible sales");
      await expect(sold.locator(".sale")).toHaveCount(4);
      await expect(sold).toContainText("1 sale(s) excluded as outliers — review");
    });
    test("profit per copy uses the sold median", async ({ page }) => {
      await open(page, { flag, mutate: withCost });
      await tab(page, "My collection");
      // 300 − 13.4% fee − $0.30 − $3 postage − $200 paid
      await expect(tileOf(page, "Charizard").locator(".profit")).toHaveText("+$56.50 profit ea");
    });
    test("carts: sold-priced buy line", async ({ page }) => {
      await open(page, { flag });
      await tab(page, "Carts");
      const buy = page.locator(".side.buy");
      await expect(buy.locator("h3")).toHaveText("Buy $300.00");
      await expect(buy.locator(".pricein")).toHaveAttribute("placeholder", "eBay 300.00");
      await expect(buy.locator(".lt")).toHaveText("$300.00");
    });
    test("arbitrage row from sold data", async ({ page }) => {
      await open(page, { flag, mutate: withArb });
      await tab(page, "Investment");
      const row = page.locator("#arb tbody tr");
      await expect(row).toHaveCount(1);
      // landed = 150 × 1.02 FX × 1.1 GST + $10 postage = 178.30; net gap = 300 − 178.30
      await expect(row).toContainText("US $150.00$178.30$300.00+$121.70");
    });
  });
}

test.describe("characterisation, today's full behaviour (flag off)", () => {
  const flag = false;
  test("collection summary and unpriced tiles", async ({ page }) => {
    await open(page, { flag });
    await tab(page, "My collection");
    await expect(page.locator("#sum")).toContainText("8 items · 7 lines · $600.00 raw value · 1 of 7 lines priced");
    for (const n of ["Blastoise", "Venusaur", "Pikachu", "Base Set Booster Box", "Mewtwo", "Gyarados"])
      await expect(tileOf(page, n).locator(".price .v")).toHaveText("No sold data yet");
    await expect(page.locator(".tile")).toHaveCount(7);
  });
  test("set grid (catalog filtered to a set)", async ({ page }) => {
    await open(page, { flag });
    await tileOf(page, "Charizard").locator(".setlink").click();
    await expect(page.getByRole("tab", { name: "Catalog" })).toHaveAttribute("aria-selected", "true");
    await expect(page.locator(".tile")).toHaveCount(7);
    await expect(page.locator("#sum")).toContainText("7 / 7 owned");
    await expect(page.locator("#sum")).toContainText("Owned $300.00 · Full pool $300.00 · raw · 1 priced");
    await expect(page.locator("#sum")).toContainText("Showing 7 items");
    await expect(tileOf(page, "Charizard").locator(".price .v")).toHaveText("$300.00");
    await expect(tileOf(page, "Blastoise").locator(".price .v")).toHaveText("No sold data yet");
    await expect(tileOf(page, "Blastoise")).toHaveClass(/owned/);
  });
  test("card detail with no sold data", async ({ page }) => {
    await open(page, { flag });
    await tab(page, "My collection");
    await tileOf(page, "Blastoise").locator(".name").click();
    const sheet = page.locator("#sheet");
    await expect(sheet.locator(".box", { hasText: "In your collection" })).toContainText("1 × Near Mint — no sold data yet");
    await expect(sheet).toContainText("No eBay sold prices yet for any quality.");
    await expect(sheet.locator("#soldbox")).toContainText("No credible eBay AU sales recorded yet for Near Mint.");
    await expect(sheet).not.toContainText("Current eBay listings");
  });
  test("investment tab: value, P&L and empty arbitrage", async ({ page }) => {
    await open(page, { flag });
    await tab(page, "Investment");
    const kpi = page.locator(".panel").first();
    await expect(kpi).toContainText("Portfolio value today");
    await expect(kpi.locator(".bigv")).toHaveText("$600.00");
    await expect(kpi).toContainText("8 items · 2 priced from eBay AU sold");
    await expect(page.locator(".panel", { hasText: "Diversification" })).toContainText("Share of your portfolio value");
    await expect(page.locator("#pnl")).toContainText(/Market value \(raw\)\s*\$600\.00\s*Unrealised profit\s*—/);
    await expect(page.locator("#arb")).toContainText("Fills in once eBay sold prices are flowing for Australia");
    await expect(page.locator("#arb")).not.toContainText("Needs sold data");
    await expect(page.locator("#ratios")).toHaveText("This fills in once eBay prices exist for booster boxes and the cards in their sets.");
  });
  test("carts / net panel", async ({ page }) => {
    await open(page, { flag });
    await tab(page, "Carts");
    const sell = page.locator(".side.sell");
    await expect(sell.locator("h3")).toHaveText("Sell $0.00");
    await expect(sell.locator(".pricein")).toHaveAttribute("placeholder", "Price");
    await expect(sell.locator(".lt")).toHaveText("No price");
    await expect(sell).toContainText("1 line(s) have no price yet — enter one to include them.");
    await expect(page.locator(".net")).toContainText("Sell $0.00 − Buy $300.00");
    await expect(page.locator(".net .big")).toHaveText("You pay $300.00");
  });
});
