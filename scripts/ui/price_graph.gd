class_name PriceGraph
extends Control
## Line chart for the fast-forward report: one line per merchant/commodity, x = market day.
## `progress` (0..1) reveals the lines left to right so the week plays out in front of the judges.

const PALETTE := [Color("#ffc688"), Color("#7fd1ae"), Color("#f08a7e"), Color("#8ab4f8"), Color("#d9a7ff"), Color("#f2e394")]
const PAD_LEFT := 30.0
const PAD_BOTTOM := 16.0
const PAD_TOP := 6.0
const PAD_RIGHT := 8.0

var series: Array = []     # [{label, values: Array, open: Array}]
var days: Array = []       # x labels, same length as every values array
var markers: Array = []    # [{index, text}] vertical event lines (bankruptcies)
var progress := 1.0:
	set(v):
		progress = clampf(v, 0.0, 1.0)
		queue_redraw()


func set_report(report: Dictionary, field := "bid") -> void:
	series.clear()
	markers.clear()
	days.clear()
	for s in report.get("series", []):
		series.append({"label": s.get("label", ""), "values": s.get(field, []), "open": s.get("open", [])})
		if days.is_empty():
			days = s.get("days", [])
		var open: Array = s.get("open", [])
		for i in range(1, open.size()):
			if open[i - 1] and not open[i]:
				markers.append({"index": i, "text": "%s bust" % str(s.get("merchant_name", ""))})
	queue_redraw()


func _draw() -> void:
	var plot := Rect2(Vector2(PAD_LEFT, PAD_TOP), size - Vector2(PAD_LEFT + PAD_RIGHT, PAD_TOP + PAD_BOTTOM))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.045, 0.09, 0.9))
	if series.is_empty() or days.size() < 2:
		draw_string(ThemeDB.fallback_font, plot.position + Vector2(8, 16), "No data", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, TitleStyle.MUTED)
		return
	var top := 1.0
	for s in series:
		for v in s.values:
			top = maxf(top, float(v))
	top = ceilf(top / 10.0) * 10.0
	var font := ThemeDB.fallback_font
	var n := days.size()
	var x_of := func(i: float) -> float:
		return plot.position.x + plot.size.x * (i / float(n - 1))
	var y_of := func(v: float) -> float:
		return plot.end.y - plot.size.y * (v / top)
	# Grid + axes.
	for g in 5:
		var value := top * g / 4.0
		var y: float = y_of.call(value)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(1, 1, 1, 0.08))
		draw_string(font, Vector2(2, y + 3), "%d" % roundi(value), HORIZONTAL_ALIGNMENT_LEFT, PAD_LEFT - 4, 7, TitleStyle.MUTED)
	for i in n:
		var x: float = x_of.call(float(i))
		draw_line(Vector2(x, plot.end.y), Vector2(x, plot.end.y + 3), Color(1, 1, 1, 0.3))
		draw_string(font, Vector2(x - 8, size.y - 3), "D%d" % int(days[i]), HORIZONTAL_ALIGNMENT_LEFT, 20, 7, TitleStyle.MUTED)
	# Lines, revealed up to `progress`.
	var reveal := progress * float(n - 1)
	for k in series.size():
		var s: Dictionary = series[k]
		var color: Color = PALETTE[k % PALETTE.size()]
		var points := PackedVector2Array()
		var values: Array = s.values
		var last := int(floor(reveal))
		for i in range(0, mini(last, n - 1) + 1):
			points.append(Vector2(x_of.call(float(i)), y_of.call(float(values[i]))))
		if last < n - 1:
			var t := reveal - float(last)
			var v := lerpf(float(values[last]), float(values[last + 1]), t)
			points.append(Vector2(x_of.call(reveal), y_of.call(v)))
		if points.size() >= 2:
			draw_polyline(points, color, 1.5, true)
		if points.size() >= 1:
			draw_circle(points[-1], 2.0, color)
	# Event markers (bankruptcies) once the playhead passes them.
	for m in markers:
		if float(m.index) > reveal:
			continue
		var x: float = x_of.call(float(m.index))
		draw_dashed_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), Color("#f08a7e"), 1.0, 3.0)
		draw_string(font, Vector2(x + 3, plot.position.y + 9), str(m.text), HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color("#f08a7e"))
	# Legend.
	var ly := plot.position.y + 4.0
	for k in series.size():
		var color: Color = PALETTE[k % PALETTE.size()]
		var lx := plot.end.x - 118.0
		draw_rect(Rect2(lx, ly + k * 9.0, 6, 6), color)
		draw_string(font, Vector2(lx + 9, ly + k * 9.0 + 6), str(series[k].label), HORIZONTAL_ALIGNMENT_LEFT, 110, 7, TitleStyle.CREAM)
