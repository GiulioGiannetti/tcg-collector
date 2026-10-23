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

test("phone: Filters stays a bottom sheet without the desktop header", async ({ page }) => {
  await page.setViewportSize({ width: 420, height: 860 });
  await open(page, {});
  await page.locator("#ftoggle").click();
  await page.waitForTimeout(350);
  await expect(page.locator(".dhead")).toBeHidden();
  const box = await page.locator("#drawer").boundingBox();
  expect(Math.round(box.y + box.height)).toBe(860);   // anchored to the bottom edge
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
