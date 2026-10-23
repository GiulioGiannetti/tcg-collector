// Search: same-name cards from a new set (and their variants) must be findable and distinguishable.
const { test, expect } = require("@playwright/test");
const { open } = require("./support/mock");

const manyTangrowths = db => {
  db.sets.push({ id: 12, name: "Mega Evolution", game_id: "pokemon", series_id: 1, release_date: "2025-09-26", language: "EN" });
  const add = (id, set_id, num, variant, set_name, release_date) => db.catalog_v.push({ id, name: "Tangrowth", card_number: num, variant, language: "EN", kind: "card",
    image_url: null, game_id: "pokemon", set_id, rarity: "Uncommon", special: "Standard", set_name, release_date, series_id: 1, owned: false, created_at: "2026-01-01",
    card_num_int: parseInt(num, 10) });
  for (let i = 0; i < 30; i++) add(500 + i, 10, String(100 + i).padStart(3, "0") + "/102", "Normal", "Base Set", "1999-01-09");
  add(600, 12, "007/132", "Normal", "Mega Evolution", "2025-09-26");
  add(601, 12, "007/132", "Reverse Holofoil", "Mega Evolution", "2025-09-26");
};

test("suggestions list the newest set first and show the variant", async ({ page }) => {
  await open(page, { mutate: manyTangrowths });
  await page.locator("#q").fill("Tangrowth");
  const sg = page.locator("#suggest .sg");
  await expect(sg.first()).toBeVisible();
  await expect(sg.nth(0).locator(".sgs")).toHaveText("Mega Evolution · 007/132");
  await expect(sg.nth(1).locator(".sgs")).toHaveText("Mega Evolution · 007/132 · Reverse Holofoil");
});

test("grid search puts same-name cards from the newest set first", async ({ page }) => {
  await open(page, { mutate: manyTangrowths });
  await page.locator("#q").fill("Tangrowth"); await page.locator("#q").press("Enter");
  const tiles = page.locator(".tile");
  await expect(tiles.first()).toBeVisible();
  await expect(tiles.nth(0)).toContainText("Mega Evolution");
  await expect(tiles.nth(1)).toContainText("Reverse Holofoil");
});
