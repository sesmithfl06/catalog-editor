/* Bowker ISBNs: signs in to myidentifiers.com, reads every ISBN on the account's ISBN list, and sends
   the list to Supabase (bowker_isbns_save), which puts new ISBNs into the matching empty ISBN cells.
   Run by .github/workflows/bowker-isbns.yml. Needs the GitHub secrets BOWKER_EMAIL, BOWKER_PASSWORD
   and BOWKER_SYNC_TOKEN (the code bowker-isbns.sql shows). Optional repository variables:
   BOWKER_LOGIN_URL (the sign-in page) and BOWKER_LIST_URL (the page that lists your ISBNs).
   The log shows only page names, counts and the ISBNs it filled in: never your password, and no
   screenshots are kept. */
import { chromium } from "playwright";

const SB_URL = process.env.BOWKER_SB_URL || "https://qurcnkeqxfqqfnygkpmd.supabase.co";   // override only for testing
const SB_KEY = "sb_publishable_SCKdsKDMAWp8htqoVF7VPA_TN9A5KOU";   // the public key the Payhip footer already uses
const { BOWKER_EMAIL, BOWKER_PASSWORD, BOWKER_SYNC_TOKEN } = process.env;
const LOGIN_URL = process.env.BOWKER_LOGIN_URL || "https://www.myidentifiers.com/user/login";
const LIST_URL = process.env.BOWKER_LIST_URL || "";
const MAX_PAGES = 300;

const log = (...a) => console.log(...a);
function fail(msg){ console.error("::error::" + msg); process.exit(1); }

export function isbnOk(d){
  if (!/^97[89]\d{10}$/.test(d)) return false;
  let s = 0; for (let i = 0; i < 12; i++) s += +d[i] * (i % 2 ? 3 : 1);
  return (10 - s % 10) % 10 === +d[12];
}
const ISBN_RE = /97[89](?:[\s-]?\d){10}/g;
const ISBN_ONE = /97[89](?:[\s-]?\d){10}/;
const FORMAT_RE = /audio|e-?book|epub|digital|electronic|kindle|mobi|pdf|paperback|hardcover|hardback|cloth|trade paper|mass market|print/i;
const STATUS_RE = /\b(unassigned|assigned|available|in use|used|unused|reserved)\b/i;
const NOT_TITLE_RE = /^(\$?[\d.,\s\/-]+|edit|view|assign|details|select|actions?|more|manage|barcode|transfer)$/i;

/* Turns the rows of a page (each one: its text and its cells) into ISBN records. */
export function parseRows(rows){
  const best = new Map();
  for (const r of rows){
    const found = [...new Set((r.text.match(ISBN_RE) || []).map(m => m.replace(/\D/g, "")).filter(isbnOk))];
    if (found.length !== 1) continue;                       // a whole table or list, not one row
    const isbn = found[0], prev = best.get(isbn);
    if (prev && prev.text.length <= r.text.length) continue; // keep the smallest element holding this ISBN
    best.set(isbn, r);
  }
  return [...best.entries()].map(([isbn, r]) => {
    const cells = (r.cells.length ? r.cells : r.text.split(/\n|\t/)).map(s => s.replace(/\s+/g, " ").trim()).filter(Boolean);
    const rest = cells.filter(c => c.replace(/\D/g, "") !== isbn && !ISBN_ONE.test(c));
    const format = rest.find(c => FORMAT_RE.test(c) && c.length < 40) || (r.text.match(FORMAT_RE) || [""])[0];
    const status = (r.text.match(STATUS_RE) || [""])[0];
    const title = rest.filter(c => c !== format && !STATUS_RE.test(c) && !NOT_TITLE_RE.test(c) && !/^\d{1,2}[\/.-]\d{1,2}[\/.-]\d{2,4}$/.test(c))
                      .sort((a, b) => b.length - a.length)[0] || "";
    return { isbn, title, format, status, cells };
  });
}

async function rowsOnPage(page){
  return page.$$eval("tr, [role=row], li, .views-row, .card, .row", els => els.map(el => ({
    text: (el.innerText || "").trim(),
    cells: [...el.querySelectorAll("td, th, [role=cell], [role=gridcell]")].map(c => (c.innerText || "").trim()).filter(Boolean)
  })).filter(r => r.text && r.text.length < 2000));
}

async function clickIfVisible(loc){
  try { if (await loc.first().isVisible({ timeout: 1500 })) { await loc.first().click(); return true; } } catch {}
  return false;
}

async function settle(page){ await page.waitForLoadState("networkidle", { timeout: 20000 }).catch(() => {}); }

/* Cloudflare's "Just a moment..." page usually clears itself after a few seconds, so wait for it
   (up to 60 seconds) before giving up. Only a robot check that is actually showing counts: normal
   Cloudflare pages also load its challenge-platform script, which is not a check. */
const WAIT_RE = /just a moment|attention required|checking your browser|un instant/i;
async function checkForChallenge(page){
  for (let s = 0; s < 60 && WAIT_RE.test(await page.title().catch(() => "")); s++) {
    if (s === 0) log(`Bowker shows "${await page.title()}" (Cloudflare check). Waiting for it to clear...`);
    await page.waitForTimeout(1000);
  }
  await settle(page);
  const title = await page.title().catch(() => "");
  const box = page.locator('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="turnstile"], .cf-turnstile, #challenge-form');
  if (WAIT_RE.test(title) || await box.first().isVisible().catch(() => false))
    fail(`Bowker shows a robot check (CAPTCHA) on "${title}" that did not clear within 60 seconds, so it can't be signed in to automatically.`);
}

async function signIn(page){
  await page.goto(LOGIN_URL, { waitUntil: "domcontentloaded", timeout: 60000 });
  await settle(page);
  await checkForChallenge(page);
  await clickIfVisible(page.getByRole("button", { name: /accept( all)?( cookies)?|i agree|agree/i }));
  const pw = () => page.locator('input[type="password"]:visible');
  if (!(await pw().count())) {
    await clickIfVisible(page.getByRole("link", { name: /log ?in|sign ?in/i }));
    await settle(page);
  }
  await checkForChallenge(page);
  const user = page.locator('input[type="email"]:visible, input[autocomplete="username"]:visible, input[name*="mail" i]:visible, input[name*="user" i]:visible, input[name="name"]:visible, input[id*="login" i]:visible').first();
  await user.waitFor({ timeout: 30000 }).catch(() => fail(`No email box found on the sign-in page "${page.url()}". Set the BOWKER_LOGIN_URL variable to the address of Bowker's sign-in page.`));
  await user.fill(BOWKER_EMAIL);
  if (!(await pw().count())) {                       // two-step sign-in: email first, then password
    await user.press("Enter");
    await pw().first().waitFor({ timeout: 30000 }).catch(() => fail("After the email, no password box appeared."));
  }
  await pw().first().fill(BOWKER_PASSWORD);
  await pw().first().press("Enter");
  await page.waitForTimeout(3000);
  await settle(page);
  await checkForChallenge(page);
  if (await pw().count()) {
    const msg = await page.locator('[role=alert], .messages, .error, .alert, .invalid-feedback').first().innerText().catch(() => "");
    fail("Still on the sign-in page after entering the password." + (msg ? ` Bowker says: ${msg.replace(/\s+/g, " ").slice(0, 200)}` : ""));
  }
  log(`Signed in. Now on "${await page.title()}".`);
}

/* Goes to the ISBN list: BOWKER_LIST_URL, or the first link that looks like it. */
async function openList(page){
  if (LIST_URL) { await page.goto(LIST_URL, { waitUntil: "domcontentloaded" }); await settle(page); return; }
  if (parseRows(await rowsOnPage(page)).length) return;
  const tries = [/my isbns|manage isbns|assigned isbns|isbn list/i, /^isbns?$/i, /my identifiers|my titles|my products/i, /my account|dashboard/i];
  for (let round = 0; round < 3; round++) {
    for (const re of tries) {
      if (await clickIfVisible(page.getByRole("link", { name: re }))) {
        await settle(page);
        log(`Opened "${await page.title()}".`);
        if (parseRows(await rowsOnPage(page)).length) return;
      }
    }
  }
  fail(`Signed in, but no page listing ISBNs was found (last page: "${await page.title()}"). Set the BOWKER_LIST_URL variable to the address of the page that lists your ISBNs.`);
}

async function readAllPages(page){
  const all = new Map();
  for (let n = 1; n <= MAX_PAGES; n++) {
    const got = parseRows(await rowsOnPage(page));
    let added = 0;
    for (const r of got) if (!all.has(r.isbn)) { all.set(r.isbn, r); added++; }
    log(`List page ${n}: ${got.length} ISBNs (${added} new).`);
    if (!added && n > 1) break;
    const next = page.locator('a[rel="next"], li.pager__item--next a, li.next a, a[aria-label*="next" i], button[aria-label*="next" i]')
      .or(page.getByRole("link", { name: /^(next|›|»|>)\s*(page)?\s*[›»>]?$/i }))
      .or(page.getByRole("button", { name: /^(next|›|»|>)\s*(page)?\s*[›»>]?$/i }));
    if (!(await next.first().isVisible().catch(() => false)) || await next.first().isDisabled().catch(() => false)) break;
    await next.first().click();
    await settle(page);
    await page.waitForTimeout(800);
  }
  return [...all.values()];
}

async function sendToSupabase(rows){
  const res = await fetch(`${SB_URL}/rest/v1/rpc/bowker_isbns_save`, {
    method: "POST",
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: BOWKER_SYNC_TOKEN, p_rows: rows })
  });
  const body = await res.text();
  if (!res.ok) fail(`Supabase refused the list (${res.status}): ${body.slice(0, 300)}`);
  return JSON.parse(body);
}

async function main(){
  for (const k of ["BOWKER_EMAIL", "BOWKER_PASSWORD", "BOWKER_SYNC_TOKEN"])
    if (!process.env[k]) fail(`The GitHub secret ${k} is missing.`);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
  try {
    await signIn(page);
    await openList(page);
    const rows = await readAllPages(page);
    if (!rows.length) fail("The ISBN list was empty.");
    const out = await sendToSupabase(rows);
    const lines = [
      `Bowker lists ${out.seen} ISBNs (${out.new} not seen before).`,
      out.filled.length ? `Filled in: ${out.filled.map(f => `${f.book} ${f.format} = ${f.isbn}`).join("; ")}.` : "No empty ISBN cells to fill.",
      out.to_check ? `${out.to_check} ISBN(s) with a title are not in the catalog yet: see bowker_isbns_to_check in Supabase.` : ""
    ].filter(Boolean);
    lines.forEach(l => log(l));
    if (process.env.GITHUB_STEP_SUMMARY) {
      const { appendFileSync } = await import("node:fs");
      appendFileSync(process.env.GITHUB_STEP_SUMMARY, lines.join("\n\n") + "\n");
    }
  } finally {
    await browser.close();
  }
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop())) main().catch(e => fail(e.message));
