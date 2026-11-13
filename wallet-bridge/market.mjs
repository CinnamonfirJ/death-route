// Camp Market engine. Everything the player sees as "the economy" is computed here from
// economy/pricing_rules.toml. The chain adapter (nep245.mjs) mirrors balance changes to the
// NEP-245 contract asynchronously; trades never wait on NEAR and never surface gas or popups.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { parse as parseToml } from "smol-toml";

export const BANDS = ["glut", "high", "balanced", "low", "scarce"];
const LEDGER_LIMIT = 300;
const HISTORY_LIMIT = 40;

export function loadRules(path) {
  return parseToml(readFileSync(path, "utf8"));
}

/** Small deterministic PRNG (mulberry32) so fast-forward runs are reproducible. */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function roundTo(value) {
  return Math.round(value * 100) / 100;
}

export class Market {
  /**
   * @param rules parsed pricing_rules.toml
   * @param options { persistPath?, chain?, now? }
   *   chain: { mode, contract, explorer, mint(), transfer(), burn() } from nep245.mjs
   */
  constructor(rules, options = {}) {
    this.rules = rules;
    this.persistPath = options.persistPath || "";
    this.chain = options.chain || null;
    this.now = options.now || (() => Date.now());
    this.state = this.persistPath ? this._load() : null;
    if (!this.state) this.state = this.freshState();
    this._reconcileRules();
  }

  // ---------- state ----------

  freshState() {
    const merchants = {};
    for (const [id, m] of Object.entries(this.rules.merchants)) {
      merchants[id] = this._freshMerchant(m);
    }
    return { version: 1, day: 1, dayStartedAt: this.now(), merchants, players: {}, intents: {},
      ledger: [], events: [] };
  }

  _freshMerchant(m) {
    const inventory = {};
    for (const [c, s] of Object.entries(m.stock)) inventory[c] = s.start;
    return { treasury: m.treasury, open: true, inventory, invested: 0, investors: {}, bankruptcies: 0,
      lifetime_bought: 0, lifetime_sold: 0 };
  }

  /** New merchants or commodities added to the TOML appear without wiping saved books. */
  _reconcileRules() {
    for (const [id, m] of Object.entries(this.rules.merchants)) {
      if (!this.state.merchants[id]) this.state.merchants[id] = this._freshMerchant(m);
      for (const [c, s] of Object.entries(m.stock)) {
        if (this.state.merchants[id].inventory[c] === undefined) this.state.merchants[id].inventory[c] = s.start;
      }
    }
  }

  _load() {
    try {
      const data = JSON.parse(readFileSync(this.persistPath, "utf8"));
      return data && typeof data === "object" && data.merchants ? data : null;
    } catch {
      return null;
    }
  }

  save() {
    if (!this.persistPath) return;
    mkdirSync(dirname(this.persistPath), { recursive: true });
    const tmp = this.persistPath + ".tmp";
    writeFileSync(tmp, JSON.stringify(this.state));
    renameSync(tmp, this.persistPath);
  }

  player(id) {
    let p = this.state.players[id];
    if (!p) {
      p = { balances: {}, hauls: {}, history: [], scrap_earned: 0, scrap_spent: 0, created: this.now() };
      this.state.players[id] = p;
    }
    return p;
  }

  // ---------- pricing ----------

  /** Mid price for `commodity` at `merchant` given an inventory level. */
  midPrice(merchantId, commodity, inventory) {
    const stock = this.rules.merchants[merchantId].stock[commodity];
    const base = this.rules.commodities[commodity].base_price;
    const raw = base - (inventory - stock.ideal) * stock.elasticity;
    const lo = base * this.rules.pricing.floor_ratio;
    const hi = base * this.rules.pricing.ceiling_ratio;
    return Math.min(hi, Math.max(lo, raw));
  }

  /** What the merchant pays a courier for one unit at this inventory level. */
  bidAt(merchantId, commodity, inventory) {
    const spread = this.rules.merchants[merchantId].spread;
    return Math.max(this.rules.pricing.min_bid, Math.floor(this.midPrice(merchantId, commodity, inventory) * (1 - spread)));
  }

  /** What a courier pays the merchant for one unit at this inventory level. */
  askAt(merchantId, commodity, inventory) {
    const spread = this.rules.merchants[merchantId].spread;
    return Math.max(1, Math.ceil(this.midPrice(merchantId, commodity, inventory) * (1 + spread)));
  }

  band(merchantId, commodity, inventory) {
    const stock = this.rules.merchants[merchantId].stock[commodity];
    const ratio = inventory / stock.ideal;
    const b = this.rules.pricing.bands;
    if (ratio >= b.glut) return "glut";
    if (ratio >= b.high) return "high";
    if (ratio <= b.scarce) return "scarce";
    if (ratio <= b.low) return "low";
    return "balanced";
  }

  voice(merchantId, key, commodity, extra = {}) {
    const m = this.rules.merchants[merchantId];
    const c = this.rules.commodities[commodity] || { name: commodity, plural: commodity };
    const template = (m.voice && m.voice[key]) || this.rules.voice[key] || "";
    const vars = { item: c.name, plural: c.plural || c.name, ...extra };
    return template.replace(/\{(\w+)\}/g, (_, k) => (vars[k] !== undefined ? String(vars[k]) : ""));
  }

  /** Full quote for one merchant/commodity pair, including the explanation shown in the tooltip. */
  quote(merchantId, commodity) {
    const m = this.rules.merchants[merchantId];
    const book = this.state.merchants[merchantId];
    const stock = m.stock[commodity];
    const inv = book.inventory[commodity] ?? 0;
    const ladderSize = this.rules.market.quote_ladder;
    const bid = this.bidAt(merchantId, commodity, inv);
    const ask = this.askAt(merchantId, commodity, inv);
    const band = this.band(merchantId, commodity, inv);
    // Ladders: the price of the 1st, 2nd, ... unit if a courier sells (or buys) that many now.
    const bidLadder = [];
    const askLadder = [];
    let treasury = book.treasury;
    for (let i = 0; i < ladderSize; i++) {
      const sellInv = inv + i;
      const price = this.bidAt(merchantId, commodity, sellInv);
      if (!book.open || sellInv >= stock.max || treasury < price) break;
      treasury -= price;
      bidLadder.push(price);
    }
    for (let i = 0; i < ladderSize; i++) {
      const buyInv = inv - i;
      if (!book.open || buyInv <= 0) break;
      askLadder.push(this.askAt(merchantId, commodity, buyInv));
    }
    let reason;
    let reasonKey = band;
    if (!book.open) reasonKey = "closed";
    else if (inv <= 0 && band === "scarce") reasonKey = "scarce";
    else if (bidLadder.length === 0 && inv < stock.max) reasonKey = "broke";
    reason = this.voice(merchantId, reasonKey, commodity, { stock: inv, ideal: stock.ideal, price: bid });
    const explain = `${this.rules.commodities[commodity].base_price} base − (${inv} stock − ${stock.ideal} ideal) × ${stock.elasticity} = ${roundTo(this.midPrice(merchantId, commodity, inv))} mid · spread ${Math.round(m.spread * 100)}%`;
    return { merchant: merchantId, commodity, token_id: this.rules.commodities[commodity].token_id,
      inventory: inv, ideal: stock.ideal, max: stock.max, mid: roundTo(this.midPrice(merchantId, commodity, inv)),
      bid, ask, band, reason, reason_key: reasonKey, formula: explain,
      bid_ladder: bidLadder, ask_ladder: askLadder,
      can_sell: bidLadder.length > 0, can_buy: askLadder.length > 0 };
  }

  // ---------- public views ----------

  snapshot(playerId = "") {
    const merchants = Object.entries(this.rules.merchants).map(([id, m]) => {
      const book = this.state.merchants[id];
      return { id, name: m.name, title: m.title, character: m.character || "",
        account: this.chain?.merchantAccount ? this.chain.merchantAccount(m.account) : m.account,
        open: book.open, treasury: book.treasury, min_treasury: m.min_treasury,
        reopen_cost: m.reopen_cost, invested: book.invested, bankruptcies: book.bankruptcies,
        closed_line: book.open ? "" : this.voice(id, "closed", Object.keys(m.stock)[0]),
        quotes: Object.keys(m.stock).map((c) => this.quote(id, c)) };
    });
    const commodities = {};
    for (const [id, c] of Object.entries(this.rules.commodities)) {
      commodities[id] = { token_id: c.token_id, name: c.name, plural: c.plural || c.name, icon: c.icon,
        base_price: c.base_price, description: c.description || "" };
    }
    const out = { ok: true, market: this.rules.market.name, day: this.state.day, merchants, commodities,
      chain: this.chain ? this.chain.describe() : { mode: "ledger-only" },
      events: this.state.events.slice(-12) };
    if (playerId) {
      const p = this.player(playerId);
      out.player = { id: playerId, balances: { ...p.balances }, history: p.history.slice(-10),
        scrap_earned: p.scrap_earned, scrap_spent: p.scrap_spent };
    }
    return out;
  }

  ledger(playerId = "", limit = 50) {
    const rows = playerId ? this.state.ledger.filter((r) => r.from === playerId || r.to === playerId) : this.state.ledger;
    return rows.slice(-limit).reverse();
  }

  // ---------- actions ----------

  /** A courier returns from a route: credit what they scavenged. Idempotent per run_id. */
  recordHaul({ player: playerId, account = "", runId, haul }) {
    const p = this.player(playerId);
    if (!runId || typeof runId !== "string") return { ok: false, error: "A run id is required." };
    if (p.hauls[runId]) return { ok: true, duplicate: true, balances: { ...p.balances } };
    const credited = {};
    for (const [c, nRaw] of Object.entries(haul || {})) {
      const n = Math.floor(Number(nRaw));
      if (!this.rules.commodities[c] || !Number.isFinite(n) || n <= 0 || n > 999) continue;
      p.balances[c] = (p.balances[c] || 0) + n;
      credited[c] = n;
    }
    p.hauls[runId] = { at: this.now(), credited };
    if (Object.keys(p.hauls).length > 200) delete p.hauls[Object.keys(p.hauls)[0]];
    for (const [c, n] of Object.entries(credited)) {
      this._ledger({ kind: "mint", from: "", to: playerId, account, commodity: c, amount: n,
        memo: `haul:${runId}` });
    }
    this._event(`${this._shortName(playerId)} banked ${Object.entries(credited).map(([c, n]) => `${n} ${this.rules.commodities[c].name}`).join(", ") || "nothing"}.`);
    this.save();
    return { ok: true, credited, balances: { ...p.balances } };
  }

  /**
   * Execute a trade intent. side "sell" = courier sells to merchant (earns scrap),
   * side "buy" = courier buys from merchant (spends scrap). The client is told the scrap
   * delta; scrap itself stays in the game save. `maxTotal` guards a buy against price moves.
   */
  trade({ player: playerId, account = "", merchant: merchantId, commodity, side, qty, intentId, maxTotal }) {
    const m = this.rules.merchants[merchantId];
    if (!m) return { ok: false, error: "Unknown merchant." };
    const stock = m.stock[commodity];
    if (!stock) return { ok: false, error: `${m.name} doesn't deal in that.` };
    qty = Math.floor(Number(qty));
    if (!Number.isFinite(qty) || qty <= 0 || qty > 99) return { ok: false, error: "Quantity must be 1-99." };
    if (side !== "sell" && side !== "buy") return { ok: false, error: "Side must be sell or buy." };
    if (intentId && this.state.intents[intentId]) return { ...this.state.intents[intentId], duplicate: true };
    const book = this.state.merchants[merchantId];
    const p = this.player(playerId);
    const c = this.rules.commodities[commodity];
    if (!book.open) return { ok: false, error: this.voice(merchantId, "closed", commodity), reason_key: "closed" };

    const unitPrices = [];
    let filled = 0;
    let total = 0;
    if (side === "sell") {
      const have = p.balances[commodity] || 0;
      if (have < qty) return { ok: false, error: `You only have ${have} ${have === 1 ? c.name : c.plural || c.name}.` };
      let inv = book.inventory[commodity];
      let treasury = book.treasury;
      let stopped = "";
      for (let i = 0; i < qty; i++) {
        if (inv >= stock.max) { stopped = "full"; break; }
        const price = this.bidAt(merchantId, commodity, inv);
        if (treasury < price) { stopped = "broke"; break; }
        unitPrices.push(price);
        total += price;
        treasury -= price;
        inv += 1;
        filled += 1;
      }
      if (filled === 0) {
        const key = stopped === "full" ? "glut" : "broke";
        return { ok: false, error: this.voice(merchantId, key, commodity), reason_key: key };
      }
      book.inventory[commodity] = inv;
      book.treasury = treasury;
      book.lifetime_bought += filled;
      p.balances[commodity] = have - filled;
      p.scrap_earned += total;
    } else {
      let inv = book.inventory[commodity];
      if (inv <= 0) return { ok: false, error: this.voice(merchantId, "sold_out", commodity), reason_key: "sold_out" };
      for (let i = 0; i < qty && inv > 0; i++) {
        const price = this.askAt(merchantId, commodity, inv);
        if (maxTotal !== undefined && total + price > maxTotal) break;
        unitPrices.push(price);
        total += price;
        inv -= 1;
        filled += 1;
      }
      if (filled === 0) return { ok: false, error: "The price moved. Check the new quote.", reason_key: "price_moved" };
      book.inventory[commodity] = inv;
      book.treasury += total;
      book.lifetime_sold += filled;
      p.balances[commodity] = (p.balances[commodity] || 0) + filled;
      p.scrap_spent += total;
    }

    const q = this.quote(merchantId, commodity);
    const result = { ok: true, side, merchant: merchantId, commodity, qty: filled, requested: qty,
      unit_prices: unitPrices, total, scrap_delta: side === "sell" ? total : -total,
      reason: q.reason, reason_key: q.reason_key, quote: q, balances: { ...p.balances },
      merchant_treasury: book.treasury, intent_id: intentId || "", partial: filled < qty };
    p.history.push({ at: this.now(), side, merchant: merchantId, commodity, qty: filled, total });
    if (p.history.length > HISTORY_LIMIT) p.history.splice(0, p.history.length - HISTORY_LIMIT);
    if (intentId) {
      this.state.intents[intentId] = result;
      const keys = Object.keys(this.state.intents);
      if (keys.length > 2000) for (const k of keys.slice(0, 500)) delete this.state.intents[k];
    }
    this._ledger({ kind: "transfer", intent: intentId || "",
      from: side === "sell" ? playerId : `merchant:${merchantId}`,
      to: side === "sell" ? `merchant:${merchantId}` : playerId,
      account, merchant: merchantId, commodity, amount: filled, scrap: total,
      memo: `${side}:${filled}x${commodity}@${total}` });
    this._event(`${this._shortName(playerId)} ${side === "sell" ? "sold" : "bought"} ${filled} ${filled === 1 ? c.name : c.plural || c.name} ${side === "sell" ? "to" : "from"} ${m.name} for ${total} scrap.`);
    if (side === "sell" && book.treasury < m.min_treasury) {
      this._event(`${m.name} is nearly out of scrap (${book.treasury} left). One more day like this and the shop closes.`);
    }
    this.save();
    return result;
  }

  /** Couriers pool scrap to reopen a bankrupt merchant. */
  invest({ player: playerId, merchant: merchantId, scrap }) {
    const m = this.rules.merchants[merchantId];
    if (!m) return { ok: false, error: "Unknown merchant." };
    const book = this.state.merchants[merchantId];
    if (book.open) return { ok: false, error: `${m.name} is open for business. Nothing to reopen.` };
    scrap = Math.floor(Number(scrap));
    if (!Number.isFinite(scrap) || scrap <= 0 || scrap > 10000) return { ok: false, error: "Invest 1-10000 scrap." };
    const needed = m.reopen_cost - book.invested;
    const accepted = Math.min(scrap, needed);
    book.invested += accepted;
    book.investors[playerId] = (book.investors[playerId] || 0) + accepted;
    let reopened = false;
    if (book.invested >= m.reopen_cost) {
      reopened = true;
      book.open = true;
      book.treasury = m.reopen_cost;
      for (const [c, s] of Object.entries(m.stock)) book.inventory[c] = s.start;
      book.invested = 0;
      book.investors = {};
      this._event(`${m.name} reopened. Couriers pooled ${m.reopen_cost} scrap to restock the shop.`);
    } else {
      this._event(`${this._shortName(playerId)} invested ${accepted} scrap in ${m.name} (${book.invested}/${m.reopen_cost}).`);
    }
    this._ledger({ kind: "invest", from: playerId, to: `merchant:${merchantId}`, merchant: merchantId,
      scrap: accepted, memo: reopened ? "reopen" : `pool:${book.invested}/${m.reopen_cost}` });
    this.save();
    return { ok: true, accepted, scrap_delta: -accepted, invested: book.invested, reopen_cost: m.reopen_cost,
      reopened, merchant: merchantId };
  }

  // ---------- time ----------

  /** Called by the server on a timer: rolls the market day when day_length_minutes passed. */
  tick() {
    const ms = this.rules.market.day_length_minutes * 60_000;
    let rolled = 0;
    while (this.now() - this.state.dayStartedAt >= ms && rolled < 48) {
      this.advanceDay(rng(this.state.day * 7919));
      this.state.dayStartedAt += ms;
      rolled += 1;
    }
    if (rolled) this.save();
    return rolled;
  }

  /**
   * One market day: the camp population consumes `daily_use` of each commodity (paying the ask
   * price into the merchant's treasury), then bankruptcy is checked. Returns the day's log.
   */
  advanceDay(random = Math.random) {
    const log = [];
    for (const [id, m] of Object.entries(this.rules.merchants)) {
      const book = this.state.merchants[id];
      if (!book.open) continue;
      for (const [c, s] of Object.entries(m.stock)) {
        // Camp demand wobbles a little day to day.
        const want = Math.max(0, Math.round(s.daily_use * (0.7 + random() * 0.6)));
        let sold = 0;
        for (let i = 0; i < want && book.inventory[c] > 0; i++) {
          book.treasury += this.askAt(id, c, book.inventory[c]);
          book.inventory[c] -= 1;
          sold += 1;
        }
        if (sold < want && want > 0) log.push(`${m.name} ran out of ${this.rules.commodities[c].plural || c} (camp wanted ${want}).`);
      }
      // Rent, guards, bribes: a shop that isn't selling (empty shelves or floor prices) bleeds out.
      book.treasury -= m.daily_upkeep || 0;
      if (book.treasury < m.min_treasury) {
        book.open = false;
        book.bankruptcies += 1;
        book.treasury = Math.max(0, book.treasury);
        log.push(`${m.name} (${m.title}) went bankrupt with ${book.treasury} scrap. Shop closed.`);
      }
    }
    this.state.day += 1;
    for (const line of log) this._event(`Day ${this.state.day}: ${line}`);
    return log;
  }

  /**
   * Judge mode: simulate `days` of synthetic courier traffic on a COPY of the live books and
   * return a day-by-day price series plus an event log. Deterministic per seed. Pass
   * `apply: true` to make the simulated outcome the live state.
   */
  fastForward({ days, seed, apply = false } = {}) {
    const sim = this.rules.simulation;
    days = Math.min(60, Math.max(1, Math.floor(Number(days) || sim.days)));
    const random = rng(Number.isFinite(Number(seed)) ? Number(seed) : sim.seed);
    const live = this.state;
    const copy = JSON.parse(JSON.stringify(live));
    this.state = copy;
    const series = {};  // "merchant/commodity" -> { merchant, commodity, label, bid: [], ask: [], inventory: [], treasury: [] }
    const log = [];
    const sample = (day) => {
      for (const [id, m] of Object.entries(this.rules.merchants)) {
        const book = this.state.merchants[id];
        for (const c of Object.keys(m.stock)) {
          const key = `${id}/${c}`;
          series[key] ??= { merchant: id, merchant_name: m.name, commodity: c,
            label: `${m.name}: ${this.rules.commodities[c].name}`, days: [], bid: [], ask: [], inventory: [], treasury: [], open: [] };
          const s = series[key];
          s.days.push(day);
          s.bid.push(this.bidAt(id, c, book.inventory[c]));
          s.ask.push(this.askAt(id, c, book.inventory[c]));
          s.inventory.push(book.inventory[c]);
          s.treasury.push(book.treasury);
          s.open.push(book.open);
        }
      }
    };
    const startDay = this.state.day;
    sample(startDay);
    for (let d = 0; d < days; d++) {
      const dayLog = [];
      for (let k = 0; k < sim.couriers_per_day; k++) {
        const courier = `sim:courier-${k + 1}`;
        for (const [c, flow] of Object.entries(sim.flow)) {
          if (!this.rules.commodities[c]) continue;
          const sellers = this._dealers(c);
          if (sellers.length === 0) continue;
          const sold = Math.max(0, Math.round(flow.sold * (random() * 1.6 + 0.2)));
          const bought = Math.max(0, Math.round(flow.bought * (random() * 1.6 + 0.2)));
          const merchant = sellers[Math.floor(random() * sellers.length)];
          if (sold > 0) {
            this.player(courier).balances[c] = (this.player(courier).balances[c] || 0) + sold;
            const r = this._quietTrade({ player: courier, merchant, commodity: c, side: "sell", qty: sold });
            if (r.ok && r.quote.band === "glut" && r.unit_prices[0] !== r.unit_prices[r.unit_prices.length - 1]) {
              dayLog.push(`${this.rules.merchants[merchant].name} overstocked on ${this.rules.commodities[c].plural || c}: price slid ${r.unit_prices[0]} → ${r.unit_prices[r.unit_prices.length - 1]}.`);
            }
          }
          if (bought > 0) this._quietTrade({ player: courier, merchant, commodity: c, side: "buy", qty: bought });
        }
      }
      const closed = this.advanceDay(random);
      dayLog.push(...closed);
      sample(this.state.day);
      for (const line of dayLog) log.push({ day: this.state.day, text: line });
      if (dayLog.length === 0) log.push({ day: this.state.day, text: "Quiet day at the camp." });
    }
    // Drop the synthetic couriers before anything is kept.
    for (const id of Object.keys(this.state.players)) if (id.startsWith("sim:")) delete this.state.players[id];
    this.state.events = live.events.slice();
    const summary = Object.entries(this.rules.merchants).map(([id, m]) => {
      const book = this.state.merchants[id];
      return { id, name: m.name, open: book.open, treasury: book.treasury, bankruptcies: book.bankruptcies };
    });
    const report = { ok: true, days, seed: Number.isFinite(Number(seed)) ? Number(seed) : sim.seed, from_day: startDay,
      to_day: this.state.day, series: Object.values(series), log, summary, applied: Boolean(apply) };
    if (apply) {
      this.state.ledger = live.ledger;
      this.state.intents = live.intents;
      this.state.dayStartedAt = this.now();
      this._event(`Fast-forward applied: ${days} simulated days (seed ${report.seed}).`);
      this.save();
    } else {
      this.state = live;
    }
    return report;
  }

  _dealers(commodity) {
    return Object.entries(this.rules.merchants).filter(([, m]) => m.stock[commodity]).map(([id]) => id);
  }

  /** trade() without ledger/event/persistence side effects, for the simulator. */
  _quietTrade(args) {
    const ledger = this._ledger;
    const event = this._event;
    const save = this.save;
    this._ledger = () => {};
    this._event = () => {};
    this.save = () => {};
    try {
      return this.trade(args);
    } finally {
      this._ledger = ledger;
      this._event = event;
      this.save = save;
    }
  }

  // ---------- ledger / chain mirror ----------

  _ledger(entry) {
    const row = { id: `${this.now().toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`,
      at: this.now(), status: "recorded", tx: "", ...entry };
    this.state.ledger.push(row);
    if (this.state.ledger.length > LEDGER_LIMIT) this.state.ledger.splice(0, this.state.ledger.length - LEDGER_LIMIT);
    if (this.chain && this.chain.enabled && row.commodity) {
      row.status = "pending";
      const tokenId = this.rules.commodities[row.commodity].token_id;
      this.chain.mirror(row, tokenId).then((outcome) => {
        Object.assign(row, outcome);
        this.save();
      }).catch((error) => {
        row.status = "failed";
        row.error = String(error?.message || error).slice(0, 200);
        this.save();
      });
    }
    return row;
  }

  _event(text) {
    this.state.events.push({ at: this.now(), day: this.state.day, text });
    if (this.state.events.length > 60) this.state.events.splice(0, this.state.events.length - 60);
  }

  _shortName(playerId) {
    if (playerId.startsWith("guest:")) return "A guest courier";
    if (playerId.startsWith("sim:")) return "A courier";
    return playerId.length > 24 ? playerId.slice(0, 10) + "…" + playerId.slice(-10) : playerId;
  }
}
