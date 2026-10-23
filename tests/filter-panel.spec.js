// Filter panel: centred dialog on desktop (like the Series/Sets pickers), bottom sheet on phones.
const { test, expect } = require("@playwright/test");
const { open, tab } = require("./support/mock");

test("desktop: Filters opens centred with a title and closes with ×, Escape or outside click", async ({ page }) => {
  await page.setViewportSize({ width: 1366, height: 860 });
  await open(page, {});
  await page.locator("#ftoggle").click();
  const d = page.locator("#drawer");
  await expect(d).toHaveClass(/open/);
  await expect(d.locator(".dhead h3")).toHaveText("Filters");
  await page.waitForTimeout(250);
  const box = await d.boundingBox();
  expect(Math.abs(box.x + box.width / 2 - 683)).toBeLessThan(4);      // horizontally centred
  expect(box.y).toBeGreaterThan(0); expect(box.y + box.height).toBeLessThan(860);   // fully on screen
  await page.locator("#dclose").click(); await expect(d).not.toHaveClass(/open/);
  await page.locator("#ftoggle").click(); await page.keyboard.press("Escape"); await expect(d).not.toHaveClass(/open/);
  await page.locator("#ftoggle").click(); await page.mouse.click(20, 420); await expect(d).not.toHaveClass(/open/);
});

test("desktop: Escape in the Series picker closes only the picker", async ({ page }) => {
  await page.setViewportSize({ width: 1366, height: 860 });
  await open(page, {});
  await page.locator("#ftoggle").click();
  await page.locator("#ser .mbtn").click();
  await expect(page.locator(".fpop-scrim")).toHaveCount(1);
  await page.keyboard.press("Escape");
  await expect(page.locator(".fpop-scrim")).toHaveCount(0);
  await expect(page.locator("#drawer")).toHaveClass(/open/);
});

test("phone: Filters is a bottom sheet with a title, and Show results closes it", async ({ page }) => {
  await page.setViewportSize({ width: 420, height: 860 });
  await open(page, {});
  await page.locator("#ftoggle").click();
  await page.waitForTimeout(350);
  await expect(page.locator(".dhead h3")).toHaveText("Filters");
  const box = await page.locator("#drawer").boundingBox();
  expect(Math.round(box.y + box.height)).toBe(860);   // anchored to the bottom edge
  await page.locator("#dapply").click();
  await expect(page.locator("#drawer")).not.toHaveClass(/open/);
});

test("filter panel footer: Clear all is off until a filter is set, then clears everything", async ({ page }) => {
  await page.setViewportSize({ width: 1366, height: 860 });
  await open(page, {});
  await page.locator("#ftoggle").click();
  await expect(page.locator("#dsub")).toHaveText("Showing everything");
  await expect(page.locator("#reset")).toBeDisabled();
  await page.locator("#l .chip", { hasText: "Japanese" }).click();
  await expect(page.locator("#dsub")).toHaveText("1 filter applied");
  await expect(page.locator("#l .chip", { hasText: "Japanese" })).toHaveAttribute("aria-pressed", "true");
  await page.locator("#reset").click();
  await expect(page.locator("#dsub")).toHaveText("Showing everything");
  await expect(page.locator("#l .chip", { hasText: "All" })).toHaveAttribute("aria-pressed", "true");
});

test("section tabs sit in the header, between the Pullfolio bar and the page title", async ({ page }) => {
  for (const [w, h] of [[1366, 860], [390, 844]]) {
    await page.setViewportSize({ width: w, height: h });
    await open(page, {});
    const bar = await page.locator("header .bar").boundingBox();
    const tabs = await page.locator("header .seg").boundingBox();
    const title = await page.locator("#ptitle").boundingBox();
    expect(tabs.y).toBeGreaterThanOrEqual(bar.y + bar.height);
    expect(title.y).toBeGreaterThanOrEqual(tabs.y + tabs.height);
    await tab(page, "Catalog");
    await expect(page.locator("#ptitle")).toContainText("Catalog");
  }
});

test("Card type opens the same tile popup as Series and Sets, and filters on Done", async ({ page }) => {
  await page.setViewportSize({ width: 1366, height: 860 });
  await open(page, { mutate: db => { db.catalog_v.find(p => p.id === 2).special = "Promo"; } });
  await tab(page, "Catalog");
  await page.locator("#ftoggle").click();
  await expect(page.locator("#spc .mbtn")).toHaveText(/All card types \(5\)/);
  await page.locator("#spc .mbtn").click();
  const pop = page.locator(".fpop");
  await expect(pop.locator("h3")).toHaveText("Card types");
  await expect(pop.locator(".ftile")).toHaveCount(5);
  await expect(pop.locator(".ftile", { hasText: "Promo" })).toContainText("Black Star and other promos");
  await pop.locator(".ftile", { hasText: "Promo" }).click();
  await pop.locator(".mdone").click();
  await expect(page.locator(".fpop-scrim")).toHaveCount(0);
  await expect(page.locator("#spc .mbtn")).toContainText("Promo");
  await expect(page.locator(".tile")).toHaveCount(1);
});
