extends SceneTree
## Camp market: hauls bank into commodities, crates map to commodities, the Garage market tab and
## the fast-forward graph build offline, and (if a bridge is running) a real haul + trade round-trips.
##
##   godot --headless -s tests/market/market_test.gd -- --save=user://market_test.save

var results := {}


func _initialize() -> void:
	_run.call_deferred()
	create_timer(60.0, true, true).timeout.connect(func() -> void: print("TIMEOUT"); _report(); quit(2))


func _check(name: String, ok: bool, info := "") -> void:
	results[name] = ok
	print(("PASS " if ok else "FAIL ") + name + ("  (" + info + ")" if info != "" else ""))


func _wait(s: float) -> void:
	await create_timer(s, true, true).timeout


func _run() -> void:
	var gm = root.get_node("GameManager")
	var market = root.get_node("CampMarket")
	# Resolved at run time: with `-s`, class names used at parse time would compile these scripts
	# before the autoloads they reference exist.
	var PickupScript = load("res://scripts/pickups/pickup.gd")
	var MarkerScript = load("res://scripts/rooms/room_marker.gd")
	var PanelScript = load("res://scripts/ui/camp_market.gd")
	var GraphScript = load("res://scripts/ui/price_graph.gd")
	gm.reset_save()
	_check("guest id generated", gm.guest_id.length() == 24, gm.guest_id)

	# --- banking a successful run ---
	gm.start_run(&"camp")
	gm.add_run_commodity("medkit", 3)
	gm.add_run_commodity("battery", 1)
	var summary: Dictionary = gm.end_run(true, -1.0, {"pizza_delivered": true})
	_check("success banks every crate", gm.haul.get("medkit", 0) == 3 and gm.haul.get("battery", 0) == 1, str(gm.haul))
	_check("delivery mints a pizza contract", gm.haul.get("pizza_contract", 0) == 1)
	_check("summary carries the haul", summary.get("haul", {}).get("medkit", 0) == 3)
	await _wait(0.1)
	var pending_after_success: int = gm.pending_hauls.size()

	# --- banking a failed run halves the crates and mints nothing ---
	gm.start_run(&"camp")
	gm.add_run_commodity("medkit", 3)
	gm.end_run(false)
	_check("failure keeps half, rounded down", gm.haul.get("medkit", 0) == 4, str(gm.haul))
	_check("no contract without a delivery", gm.haul.get("pizza_contract", 0) == 1)

	# --- crates ---
	var crate_commodity: Dictionary = PickupScript.CRATE_COMMODITY
	_check("every crate kind names a commodity",
		crate_commodity.values().all(func(id: String) -> bool: return gm.COMMODITIES.has(id)))
	_check("crate kind lookup", PickupScript.crate_kind_for("battery") == PickupScript.Kind.CRATE_BATTERY)
	var icons_ok := true
	var item_for_kind: Dictionary = PickupScript.ITEM_FOR_KIND
	for k in item_for_kind:
		if root.get_node("Assets").item_frames(item_for_kind[k]) == null:
			icons_ok = false
	_check("every pickup kind has art", icons_ok)
	var labels: Array = MarkerScript.LABELS
	var colors: Array = MarkerScript.COLORS
	var kinds: int = MarkerScript.Kind.size()
	_check("marker tables cover CRATE", labels.size() == kinds and colors.size() == kinds
		and labels[MarkerScript.Kind.CRATE] == "CRATE")

	# --- UI builds offline ---
	var panel = PanelScript.new()
	root.add_child(panel)
	await process_frame
	_check("market panel builds offline", panel.get_child_count() >= 4)
	var graph = GraphScript.new()
	graph.set_report({"series": [{"label": "Doc: Medkit", "bid": [15, 14, 9, 4], "open": [true, true, true, false],
		"days": [1, 2, 3, 4], "merchant_name": "Doc"}]})
	graph.size = Vector2(300, 120)
	root.add_child(graph)
	await process_frame
	_check("graph marks a bankruptcy", graph.markers.size() == 1 and graph.markers[0].index == 3)
	panel.queue_free()
	graph.queue_free()

	# --- live bridge round-trip (skipped when no bridge is listening) ---
	await market.refresh()
	if not market.online:
		print("SKIP bridge offline: live trade round-trip not exercised")
		_check("pending hauls queued while offline", gm.pending_hauls.size() >= 1, str(gm.pending_hauls.size()))
	else:
		_check("bridge acknowledged pending hauls", gm.pending_hauls.is_empty(), "pending before: %d" % pending_after_success)
		_check("bridge balances mirror the haul", market.balance("medkit") == 4 and market.balance("pizza_contract") == 1,
			str(market.balances))
		var scrap_before: int = gm.currency
		var sale: Dictionary = await market.trade("doc", "medkit", "sell", 2)
		_check("sold two medkits to Doc", sale.get("ok", false) and sale.get("qty", 0) == 2, str(sale.get("error", "")))
		_check("scrap credited locally", gm.currency == scrap_before + int(sale.get("scrap_delta", 0)))
		_check("merchant explains the price", str(sale.get("reason", "")).length() > 0, str(sale.get("reason", "")))
		var contract: Dictionary = await market.trade("mama_g", "pizza_contract", "sell", 1)
		_check("dispatch redeems the pizza contract", contract.get("ok", false) and contract.get("total", 0) >= 40, str(contract.get("total", 0)))
		var buy: Dictionary = await market.trade("rusty", "premium_ammo", "buy", 1)
		_check("bought ammo from Rusty", buy.get("ok", false) and market.balance("premium_ammo") == 1, str(buy.get("error", "")))
		var report: Dictionary = await market.fast_forward(7, false)
		_check("fast-forward returns a week of prices", report.get("ok", false) and report.get("series", []).size() >= 5
			and report.get("series", [])[0].get("bid", []).size() == 8)
		var ledger: Dictionary = await market.ledger()
		_check("ledger lists our trades", ledger.get("rows", []).size() >= 3)
	_report()
	quit(0 if results.values().all(func(v: bool) -> bool: return v) else 1)


func _report() -> void:
	var passed := results.values().filter(func(v: bool) -> bool: return v).size()
	print("RESULT %d/%d passed" % [passed, results.size()])
