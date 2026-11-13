import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { Market, loadRules, rng } from "../market.mjs";

const rules = loadRules(fileURLToPath(new URL("../../economy/pricing_rules.toml", import.meta.url)));

function market() {
  let t = 1_000_000;
  return new Market(rules, { now: () => (t += 1000) });
}

test("formula: price = base - (inventory - ideal) * elasticity, clamped", () => {
  const m = market();
  const doc = rules.merchants.doc.stock.medkit;
  const base = rules.commodities.medkit.base_price;
  assert.equal(m.midPrice("doc", "medkit", doc.ideal), base);
  assert.equal(m.midPrice("doc", "medkit", doc.ideal + 2), base - 2 * doc.elasticity);
  assert.equal(m.midPrice("doc", "medkit", 1000), base * rules.pricing.floor_ratio);
  assert.equal(m.midPrice("doc", "medkit", -1000), base * rules.pricing.ceiling_ratio);
  assert.ok(m.bidAt("doc", "medkit", doc.ideal) < m.askAt("doc", "medkit", doc.ideal));
});

test("selling walks the price down unit by unit and explains why", () => {
  const m = market();
  m.recordHaul({ player: "p1", runId: "run-1", haul: { medkit: 20 } });
  const before = m.quote("doc", "medkit");
  const r = m.trade({ player: "p1", merchant: "doc", commodity: "medkit", side: "sell", qty: 20, intentId: "i-1" });
  assert.equal(r.ok, true);
  assert.equal(r.qty, 20);
  assert.equal(r.unit_prices[0], before.bid);
  for (let i = 1; i < r.unit_prices.length; i++) assert.ok(r.unit_prices[i] <= r.unit_prices[i - 1]);
  assert.equal(r.scrap_delta, r.unit_prices.reduce((a, b) => a + b, 0));
  assert.equal(r.balances.medkit, 0);
  assert.equal(r.quote.band, "glut");
  assert.match(r.reason, /stacked to the ceiling/);
  // Same intent twice is the same result, not a second payout.
  const again = m.trade({ player: "p1", merchant: "doc", commodity: "medkit", side: "sell", qty: 20, intentId: "i-1" });
  assert.equal(again.duplicate, true);
  assert.equal(again.total, r.total);
});

test("buying with max_total refuses when the price moved", () => {
  const m = market();
  const q = m.quote("rusty", "premium_ammo");
  const cheap = m.trade({ player: "p2", merchant: "rusty", commodity: "premium_ammo", side: "buy", qty: 3, maxTotal: q.ask_ladder[0] - 1 });
  assert.equal(cheap.ok, false);
  assert.equal(cheap.reason_key, "price_moved");
  const fair = m.trade({ player: "p2", merchant: "rusty", commodity: "premium_ammo", side: "buy", qty: 3,
    maxTotal: q.ask_ladder.slice(0, 3).reduce((a, b) => a + b, 0) });
  assert.equal(fair.ok, true);
  assert.equal(fair.qty, 3);
  assert.equal(fair.scrap_delta, -fair.total);
  assert.equal(fair.balances.premium_ammo, 3);
});

test("a merchant stops buying when her treasury runs dry, then goes bankrupt at day end", () => {
  const m = market();
  m.recordHaul({ player: "whale", runId: "r", haul: { medkit: 500 } });
  const r = m.trade({ player: "whale", merchant: "doc", commodity: "medkit", side: "sell", qty: 99 });
  assert.equal(r.ok, true);
  assert.ok(r.partial, "the sale should stop early");
  const book = m.state.merchants.doc;
  assert.ok(book.treasury < m.bidAt("doc", "medkit", book.inventory.medkit) || book.inventory.medkit >= rules.merchants.doc.stock.medkit.max);
  const r2 = m.trade({ player: "whale", merchant: "doc", commodity: "medkit", side: "sell", qty: 1 });
  assert.equal(r2.ok, false);
  assert.ok(["broke", "glut"].includes(r2.reason_key));
  // Day end: the camp buys 3-ish medkits, but she's still under min_treasury -> closes.
  if (book.treasury < rules.merchants.doc.min_treasury) {
    const log = m.advanceDay(rng(1));
    assert.ok(log.some((l) => /bankrupt/.test(l)), log.join("\n"));
    assert.equal(book.open, false);
    const closed = m.trade({ player: "whale", merchant: "doc", commodity: "medkit", side: "buy", qty: 1 });
    assert.equal(closed.reason_key, "closed");
    // Pooled reopening.
    const half = m.invest({ player: "a", merchant: "doc", scrap: 100 });
    assert.equal(half.ok, true);
    assert.equal(half.reopened, false);
    const rest = m.invest({ player: "b", merchant: "doc", scrap: 999 });
    assert.equal(rest.accepted, rules.merchants.doc.reopen_cost - 100);
    assert.equal(rest.reopened, true);
    assert.equal(book.open, true);
  }
});

test("hauls are idempotent per run id and ignore unknown commodities", () => {
  const m = market();
  const a = m.recordHaul({ player: "p", runId: "run-9", haul: { medkit: 2, battery: 1, gold: 50, medkit_bad: -3 } });
  assert.deepEqual(a.credited, { medkit: 2, battery: 1 });
  const b = m.recordHaul({ player: "p", runId: "run-9", haul: { medkit: 2 } });
  assert.equal(b.duplicate, true);
  assert.equal(m.player("p").balances.medkit, 2);
});

test("fast-forward is deterministic, leaves live books untouched unless applied", () => {
  const m = market();
  const liveBefore = JSON.stringify(m.state.merchants);
  const a = m.fastForward({ days: 7, seed: 7 });
  const b = m.fastForward({ days: 7, seed: 7 });
  assert.deepEqual(a.series.map((s) => s.bid), b.series.map((s) => s.bid));
  assert.equal(a.series[0].bid.length, 8, "start sample + 7 days");
  assert.ok(a.log.length >= 7);
  assert.equal(JSON.stringify(m.state.merchants), liveBefore);
  assert.equal(Object.keys(m.state.players).filter((id) => id.startsWith("sim:")).length, 0);
  const c = m.fastForward({ days: 3, seed: 3, apply: true });
  assert.equal(c.applied, true);
  assert.equal(m.state.day, c.to_day);
});

test("snapshot carries everything the client renders", () => {
  const m = market();
  m.recordHaul({ player: "p", runId: "r1", haul: { pizza_contract: 1 } });
  const s = m.snapshot("p");
  assert.equal(s.merchants.length, 3);
  const mamaG = s.merchants.find((x) => x.id === "mama_g");
  const q = mamaG.quotes.find((x) => x.commodity === "pizza_contract");
  assert.equal(q.token_id, "3");
  assert.ok(q.reason.length > 0);
  assert.ok(q.formula.includes("base"));
  assert.equal(s.player.balances.pizza_contract, 1);
  assert.equal(s.chain.mode, "ledger-only");
});
