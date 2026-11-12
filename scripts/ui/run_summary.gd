class_name RunSummary
extends CanvasLayer
## End-of-run card. Pauses the game; "Back to Garage" (or [E]/[R]) returns to the Garage.

const SUCCESS_LINES := [
	"Pizza delivered. The customer did not tip.",
	"Pizza arrived. Mostly intact. Like you.",
	"Five stars. The reviewer was eaten shortly after.",
]
const FAIL_LINES := [
	"Delivery failed. Your corpse is now the package.",
	"The customer has been notified of the delay.",
	"Undeliverable. Return to sender.",
]

@onready var panel: PanelContainer = %Panel
@onready var title: Label = %Title
@onready var flavor: Label = %Flavor
@onready var details: Label = %Details
@onready var back_button: Button = %BackButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	panel.theme = Assets.ui_theme()
	if TouchLayout.enabled():
		TouchLayout.label(flavor, 14)
		TouchLayout.label(details, 14)
		TouchLayout.button(back_button)
		TitleStyle.primary(back_button)
	visible = false
	back_button.pressed.connect(GameManager.goto_garage)


func show_summary(summary: Dictionary) -> void:
	if summary.get("versus", false):
		_show_versus(summary)
		return
	var success: bool = summary.get("success", false)
	var pizza_delivered: bool = summary.get("pizza_delivered", success)
	title.text = "ROUTE COMPLETE" if success else "RUN FAILED"
	title.add_theme_color_override(&"font_color", Color(0.55, 0.9, 0.45) if success else Color(0.95, 0.3, 0.25))
	flavor.text = (SUCCESS_LINES if success else FAIL_LINES).pick_random()
	if not success and pizza_delivered:
		flavor.text = "The customer got their pizza. You didn't make it back."
	var lines := [
		"Pizza handed to the customer" if pizza_delivered else "Pizza undelivered",
		"Scrap found:   %d" % summary.get("scrap_found", 0),
		"Scrap banked:  %d%s" % [summary.get("scrap_banked", 0), "" if success else "  (half: you died)"],
		"Zombies killed: %d" % summary.get("kills", 0),
		"%s condition: %d%%" % [String(summary.get("weapon", "pistol")).capitalize(),
			roundi(float(summary.get("durability", 1.0)) * 100.0)],
	]
	if success:
		var line := "Survivors delivered: %d" % summary.get("survivors", 0)
		var bad: int = summary.get("infected_delivered", 0)
		if bad > 0:
			line += "\n...and %d infected. The camp is having a bad night." % bad
		lines.append(line)
	if summary.has("rival"):
		lines.append(summary.rival)
	details.text = "\n".join(lines)
	visible = true
	get_tree().paused = true
	back_button.grab_focus()


func _show_versus(summary: Dictionary) -> void:
	var result: String = summary.get("result", "draw")
	title.text = {"win": "VICTORY", "lose": "DEFEAT", "draw": "DRAW"}[result]
	title.add_theme_color_override(&"font_color", {"win": Color(0.55, 0.9, 0.45), "lose": Color(0.95, 0.3, 0.25),
		"draw": Color(1, 0.85, 0.4)}[result])
	var who: String = summary.get("winner_name", "")
	flavor.text = String(summary.get("reason", "")) + ("" if who == "" else "  %s wins." % who)
	details.text = "%s\n\nScrap banked: %d" % [summary.get("board", ""), summary.get("scrap_banked", 0)]
	visible = true
	get_tree().paused = true
	back_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if visible and (event.is_action_pressed(&"interact") or event.is_action_pressed(&"reload")):
		GameManager.goto_garage()
