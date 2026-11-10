class_name UpgradeDef
extends Resource
## One purchasable permanent upgrade. Authored as .tres in res://resources/upgrades/.
##
## Effect: every level adds `per_level` to the stat named by `stat`:
##   PERCENT -> stat *= 1 + per_level * level   (0.15 = +15% per level)
##   ADD     -> stat += per_level * level
##   UNLOCK  -> level > 0 unlocks something (stat names it, e.g. "unlock.shotgun")
## Stat keys are read by GameManager.apply_stat(); see the STAT_* list there.

enum Category { VEHICLE, WEAPONS, HANDYMAN }
enum Mode { PERCENT, ADD, UNLOCK }

@export var id: StringName
@export var display_name := "Upgrade"
@export_multiline var description := ""
@export var category: Category = Category.VEHICLE
## Key into the asset manifest's "items" section for the icon.
@export var icon_item := "blueprint"

@export_group("Effect")
@export var stat: StringName
@export var mode: Mode = Mode.PERCENT
@export var per_level := 0.1
@export var max_level := 3

@export_group("Cost")
@export var base_cost := 40
## Each level costs base_cost * cost_growth^level.
@export var cost_growth := 1.6


func cost_for_level(next_level: int) -> int:
	return roundi(base_cost * pow(cost_growth, next_level - 1))


## Human-readable effect for a level, e.g. "+30%" or "+20".
func effect_text(level: int) -> String:
	match mode:
		Mode.PERCENT:
			return "%+d%%" % roundi(per_level * level * 100.0)
		Mode.ADD:
			var v := per_level * level
			var num := "%d" % roundi(v) if is_equal_approx(v, roundf(v)) else "%.2f" % v
			return ("+" if v >= 0.0 else "") + num
		_:
			return "Unlocked" if level > 0 else "Locked"
