// The Python witness owns match completion and terminates this process after the receipt.
const { chromium, firefox, webkit } = require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE || "playwright");

async function main() {
    const [engine, executable, url] = process.argv.slice(2);
    const browser = await ({ chromium, firefox, webkit }[engine]).launch({
        executablePath: executable === "default" ? undefined : executable,
        headless: engine === "chromium",
        args: engine === "chromium" ? ["--enable-unsafe-swiftshader", "--use-angle=swiftshader"] : [],
        firefoxUserPrefs: { "webgl.force-enabled": true, "webgl.disabled": false },
    });
    process.on("SIGTERM", () => browser.close());
    const page = await browser.newPage();
    page.on("pageerror", error => console.error(error));
    page.on("console", message => console.error(message.text()));
    await page.goto(url, { waitUntil: "domcontentloaded" });
}

main().catch(error => { console.error(error); process.exitCode = 1; });
