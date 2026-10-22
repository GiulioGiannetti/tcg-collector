// Stage 0 characterisation tests: pin down what the touched screens show today.
// They run with PRICE_FALLBACK_ASKING forced off, which must reproduce today's behaviour exactly.
// The "sold wins" block re-runs the sold-priced assertions with the flag on.
const { test, expect } = require("@playwright/test");
const { open, tab } = require("./support/mock");

const tileOf = (page, name) => page.locator(".tile", { has: page.locator(".name", { hasText: new RegExp("^" + name + "$") }) });

for (const flag of [false, true]) {
  test.describe("characterisation, sold-priced items (flag " + (flag ? "on" : "off") + ")", () => {
    test("collection tile shows the sold median", async ({ page }) => {
      await open(page, { flag });
      await expect(tileOf(page, "Charizard").locator(".price .v")).toHaveText("$300.00");
      await expect(tileOf(page, "Charizard").locator(".price .v")).toHaveClass(/ok/);
    });
    test("card detail: collection line, quality table and sold box", async ({ page }) => {
      await open(page, { flag });
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
      await expect(sold.getByRole("link", { name: "View all sold listings on eBay ↗" })).toBeVisible();
    });
    test("carts: sold-priced buy line", async ({ page }) => {
      await open(page, { flag });
      await tab(page, "Carts");
      const buy = page.locator(".side.buy");
      await expect(buy.locator("h3")).toHaveText("Buy $300.00");
      await expect(buy.locator(".pricein")).toHaveAttribute("placeholder", "eBay 300.00");
      await expect(buy.locator(".lt")).toHaveText("$300.00");
    });
  });
}

test.describe("characterisation, today's full behaviour (flag off)", () => {
  const flag = false;
  test("collection summary and unpriced tiles", async ({ page }) => {
    await open(page, { flag });
    await expect(page.locator("#sum")).toContainText("8 items · 7 lines · $600.00 raw value");
    await expect(page.locator("#sum")).toContainText("1 of 7 lines priced from eBay AU sold");
    for (const n of ["Blastoise", "Venusaur", "Pikachu", "Base Set Booster Box", "Mewtwo", "Gyarados"])
      await expect(tileOf(page, n).locator(".price .v")).toHaveText("No sold data yet");
    await expect(page.locator(".tile")).toHaveCount(7);
  });
  test("set grid (tap a set name)", async ({ page }) => {
    await open(page, { flag });
    await tileOf(page, "Charizard").locator(".setlink").click();   // filters to Base Set
    await tab(page, "Catalog");
    await expect(page.locator(".tile")).toHaveCount(7);
    await expect(page.locator("#sum")).toContainText("7 products · $300.00 (1 priced) raw value, one of each");
    await expect(tileOf(page, "Charizard").locator(".price .v")).toHaveText("$300.00");
    await expect(tileOf(page, "Blastoise").locator(".price .v")).toHaveText("No sold data yet");
    await expect(tileOf(page, "Blastoise")).toHaveClass(/owned/);
  });
  test("card detail with no sold data", async ({ page }) => {
    await open(page, { flag });
    await tileOf(page, "Blastoise").locator(".name").click();
    const sheet = page.locator("#sheet");
    await expect(sheet.locator(".box", { hasText: "In your collection" })).toContainText("1 × Near Mint — no sold data yet");
    await expect(sheet).toContainText("No eBay sold prices yet for any quality.");
    await expect(sheet.locator("#soldbox")).toContainText("No credible eBay AU sales recorded yet for Near Mint.");
    await expect(sheet.locator(".box")).toHaveCount(3);
    await expect(sheet).not.toContainText("Current eBay listings");
  });
  test("investment tab", async ({ page }) => {
    await open(page, { flag });
    await tab(page, "Investment");
    const kpi = page.locator(".panel").first();
    await expect(kpi).toContainText("Portfolio value today");
    await expect(kpi.locator(".bigv")).toHaveText("$600.00");
    await expect(kpi).toContainText("8 items · 2 priced from eBay AU sold");
    await expect(page.locator(".panel", { hasText: "Diversification" })).toContainText("Share of your portfolio value");
    await expect(page.locator("#ratios")).toHaveText("This fills in once eBay prices exist for booster boxes and the cards in their sets.");
  });
  test("carts / net (arbitrage) panel", async ({ page }) => {
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
