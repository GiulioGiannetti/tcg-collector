// Card images: tcg.pokemon.com cards show the 330×460 file in grids and the 660×920 (-2x) file on the card page.
const { test, expect } = require("@playwright/test");
const { open, tab } = require("./support/mock");

const PCOM = "https://dz3we2x72f7ol.cloudfront.net/expansions/phantasmal-flames/en-us/8BXG_EN_50.png";
const tileOf = (page, name) => page.locator(".tile", { has: page.locator(".name", { hasText: new RegExp("^" + name + "$") }) });

test("tcg.pokemon.com card: grid uses the standard file, card page the -2x file", async ({ page }) => {
  await open(page, { mutate: db => { for (const t of [db.products, db.catalog_v]) t.find(p => p.id === 1).image_url = PCOM; } });
  await tab(page, "My collection");
  const tile = tileOf(page, "Charizard");
  await expect(tile.locator("img").first()).toHaveAttribute("src", PCOM);
  await tile.locator(".name").click();
  const hero = page.locator("#heroimg");
  await expect(hero).toHaveAttribute("src", PCOM.replace(/\.png$/, "-2x.png"));
  await expect(hero).toHaveAttribute("data-fb", PCOM);
});

test("other image hosts are shown unchanged on the card page", async ({ page }) => {
  const other = "https://images.pokemontcg.io/me2/50_hires.png";
  await open(page, { mutate: db => { for (const t of [db.products, db.catalog_v]) t.find(p => p.id === 1).image_url = other; } });
  await tab(page, "My collection");
  await tileOf(page, "Charizard").locator(".name").click();
  await expect(page.locator("#heroimg")).toHaveAttribute("src", other);
});

test("Scryfall card: card page uses the large image", async ({ page }) => {
  const normal = "https://cards.scryfall.io/normal/front/3/5/359ab776-e30c-4ccf-8fb8-8597812f131d.jpg?1783917933";
  await open(page, { mutate: db => { for (const t of [db.products, db.catalog_v]) t.find(p => p.id === 1).image_url = normal; } });
  await tab(page, "My collection");
  await tileOf(page, "Charizard").locator(".name").click();
  await expect(page.locator("#heroimg")).toHaveAttribute("src", normal.replace("/normal/", "/large/"));
});
