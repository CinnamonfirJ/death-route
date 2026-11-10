class_name UpgradeCatalog
extends Resource
## Every upgrade in the game. A single resource (instead of scanning a folder)
## so it survives export, where .tres files get remapped.

@export var upgrades: Array[UpgradeDef] = []


func get_upgrade(id: StringName) -> UpgradeDef:
	for u in upgrades:
		if u.id == id:
			return u
	return null


func in_category(category: UpgradeDef.Category) -> Array[UpgradeDef]:
	var out: Array[UpgradeDef] = []
	for u in upgrades:
		if u.category == category:
			out.append(u)
	return out
