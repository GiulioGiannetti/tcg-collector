// Signed-out flow on GitHub Pages, where the app lives under /tcg-collector/.
const { test, expect } = require("@playwright/test");
const { setup, ORIGIN } = require("./support/mock");

test("signed-out visitor reaches welcome and gets back to sign-in inside the app folder", async ({ page }) => {
  await setup(page, { signedOut: true });
  await page.goto(ORIGIN + "/tcg-collector/");
  await expect(page).toHaveURL(ORIGIN + "/tcg-collector/welcome.html");
  await page.locator("#acctemail").fill("tester@example.com");
  await page.locator("#acctform").evaluate(f => f.requestSubmit());
  await expect(page).toHaveURL(ORIGIN + "/tcg-collector/?signin");
  await expect(page.locator("#email")).toBeVisible();
});

for (const f of ["terms.html", "privacy.html", "credits.html"])
  test(f + " sign-in link stays inside the app folder", async ({ page }) => {
    await setup(page, { signedOut: true });
    await page.goto(ORIGIN + "/tcg-collector/" + f);
    const href = await page.locator('a[href*="signin"]').first().evaluate(a => a.href);
    expect(href).toBe(ORIGIN + "/tcg-collector/?signin");
  });
