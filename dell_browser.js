// Load a Dell support page in the installed Chrome and return the warranty
// HTML that Akamai blocks curl-impersonate from fetching. Writes
// details.html and product.txt into the directory given as argv[2].
const fs = require("fs");
const os = require("os");
const path = require("path");

function loadPlaywright() {
  const local = path.join(__dirname, "node_modules", "playwright");
  try {
    return require(local);
  } catch (e) {
    /* fall through */
  }
  try {
    return require("playwright");
  } catch (e) {
    return null;
  }
}

const svctag = process.argv[2];
const outDir = process.argv[3];
if (!svctag || !outDir) {
  console.error("usage: dell_browser.js <service_tag> <output_dir>");
  process.exit(2);
}

const playwright = loadPlaywright();
if (!playwright) {
  console.error("playwright is not installed. From this directory run: npm install");
  process.exit(1);
}

const url =
  "https://www.dell.com/support/product-details/en-us/servicetag/" +
  svctag +
  "/overview";

(async () => {
  const context = await playwright.chromium.launchPersistentContext(
    process.env.DELL_CHROME_PROFILE || path.join(os.tmpdir(), "dell-warranty-chrome"),
    {
      channel: "chrome",
      headless: false,
      viewport: { width: 1400, height: 900 },
      args: ["--disable-blink-features=AutomationControlled"],
    }
  );
  const page = context.pages()[0] || (await context.newPage());
  let product = "";
  let details = "";

  page.on("response", async (res) => {
    try {
      if (res.status() !== 200) return;
      const u = res.url();
      if (!product && u.includes("/overview") && res.request().resourceType() === "document") {
        const html = await res.text();
        const match = html.match(/"ProductName":"([^"]+)"/);
        if (match) product = match[1];
      }
      if (!details && u.includes("/entitlement/details")) {
        const body = await res.text();
        if (body.includes("WarrantyCmsViewModel")) details = body;
      }
    } catch (e) {
      /* a body can only be read once */
    }
  });

  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 90000 });
  for (let i = 0; i < 25 && !details; i++) {
    const link = page.locator("a.primaryWarrantyName");
    if (await link.count()) await link.first().click({ timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(3000);
    if (!details) {
      const dom = await page.content();
      if (dom.includes("WarrantyCmsViewModel-table3")) details = dom;
    }
  }
  if (!product) {
    const title = await page.title();
    product = title.replace(/^Support for\s+/i, "").replace(/\s*\|.*$/, "").trim();
  }
  await context.close();

  if (!details) {
    console.error("browser did not receive warranty details for " + svctag);
    process.exit(1);
  }
  fs.writeFileSync(path.join(outDir, "details.html"), details);
  fs.writeFileSync(path.join(outDir, "product.txt"), product + "\n");
})().catch((err) => {
  console.error(String(err && err.stack ? err.stack : err));
  process.exit(1);
});
