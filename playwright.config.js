// @ts-check
const { defineConfig } = require("@playwright/test");

// The app is a single static page; tests serve it through page.route (see tests/support/mock.js)
// and answer every Supabase call from fixtures, so nothing touches the real project.
module.exports = defineConfig({
  testDir: "tests",
  timeout: 20000,
  fullyParallel: true,
  reporter: [["list"]],
  use: {
    browserName: "chromium",
    viewport: { width: 1100, height: 900 },
  },
});
