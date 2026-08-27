class_name BlueprintNamer
extends RefCounted
# Generates deadpan designations for player designs: a compound word-pair
# wrapped in military version formatting. "GoatHauler Mk VI", "FoxShaft M38",
# "Type 17 IronDung".
#
# The joke is structural, not written. Nothing in the word lists is trying to
# be funny on its own - "Goat" and "Hauler" are both entirely ordinary. The
# comedy comes from the designation format treating whatever falls out with
# complete bureaucratic seriousness, which is the same "played straight"
# rule the rest of the interface follows. So: no puns, no exclamation marks,
# no words that are already jokes. If a pair lands as absurd, the format
# should still present it as though it came off a procurement form.
#
# Used to SUGGEST a name, never to assign one silently - a design still only
# reaches the match roster when the player commits to a name (see
# blueprint_manager.is_named()). The generator exists because the actual
# annoyance was never "designs have no name", it was "every row in the
# roster is indistinguishable from every other row."

# Deliberately concrete, mundane, eloquent, and martial.
# Split cleanly: 120 Absurd / Eloquent and 120 Serious / Warlike (240 total).
const HEADS = [
	# === ABSURD / ELOQUENT ===
	"Goat", "Mule", "Boar", "Hog", "Badger", "Otter", "Toad", "Moth",
	"Vole", "Beaver", "Ferret", "Hare", "Crow", "Rook", "Gull", "Goose",
	"Gander", "Mallard", "Pigeon", "Capon", "Rooster", "Hen", "Turkey", "Peacock",
	"Pangolin", "Walrus", "Porpoise", "Newt", "Weasel", "Stoat", "Possum", "Hamster",
	"Maggot", "Grub", "Cricket", "Beetle", "Barnacle", "Leech", "Tick", "Worm",
	"Turnip", "Parsnip", "Cabbage", "Radish", "Mushroom", "Truffle", "Pudding", "Mutton",
	"Gristle", "Tallow", "Curd", "Suet", "Lard", "Tripe", "Offal", "Chaff",
	"Kettle", "Barrel", "Spade", "Churn", "Cask", "Plow", "Bale", "Tub",
	"Bucket", "Ladle", "Trough", "Bellows", "Grommet", "Spigot", "Thimble", "Monocle",
	"Teapot", "Goblet", "Chalice", "Parasol", "Slipper", "Spectacle", "Petticoat", "Candelabra",
	"Brocade", "Velvet", "Porcelain", "Bisque", "Tapestry", "Gossamer", "Reliquary", "Cenotaph",
	"Viscount", "Baron", "Archon", "Prelate", "Abbot", "Prior", "Vicar", "Rector",
	"Seneschal", "Castellan", "Chamberlain", "Patrician", "Magnate", "Potentate", "Grandee", "Archduke",
	"Requiem", "Elegy", "Madrigal", "Canticle", "Carillon", "Psalter", "Nocturne", "Sonnet",
	"Seraph", "Cherub", "Gazebo", "Pavilion", "Cloister", "Rookery", "Apiary", "Belfry",

	# === SERIOUS / WARLIKE ===
	"Iron", "Steel", "Brass", "Lead", "Tin", "Coal", "Slag", "Ore",
	"Basalt", "Flint", "Shale", "Grit", "Rust", "Ash", "Silt", "Peat",
	"Stone", "Clay", "Salt", "Gravel", "Ditch", "Bog", "Fen", "Ridge",
	"Gulch", "Marsh", "Scrub", "Quarry", "Barrow", "Trench", "Canyon", "Crag",
	"Heath", "Dune", "Bluff", "Pike", "Anvil", "Drum", "Rivet", "Harness",
	"Fox", "Elk", "Ox", "Ram", "Wasp", "Stag", "Hound", "Bull",
	"Vanguard", "Rampart", "Bastion", "Bulwark", "Sentry", "Garrison", "Colossus", "Titan",
	"Dread", "Storm", "Thunder", "Wrath", "Fury", "Havoc", "Carnage", "Ruin",
	"Doom", "Bane", "Scourge", "Terror", "Menace", "Peril", "Assault", "Siege",
	"Strike", "Sortie", "Ambush", "Front", "Flank", "Citadel", "Fortress", "Redoubt",
	"Bunker", "Keep", "Turret", "Barbican", "Parapet", "Casemate", "Aegis", "Cuirass",
	"Gauntlet", "Helm", "Gorget", "Hauberk", "Tungsten", "Titanium", "Ballistic", "Kinetic",
	"Thermal", "Plasma", "Laser", "Apex", "Vortex", "Savage", "Grim", "Lethal",
	"Dire", "Ironclad", "Warhound", "Spartan", "Legion", "Phalanx", "Cohort", "Centurion",
	"Hussar", "Lancer", "Grenadier", "Marksman", "Mortar", "Howitzer", "Autocannon", "Vulcan",
]

# Function-shaped nouns, roles, and descriptors.
# Split cleanly: 120 Absurd / Eloquent and 120 Serious / Warlike (240 total).
const TAILS = [
	# === ABSURD / ELOQUENT ===
	"Hauler", "Shaft", "Dung", "Sump", "Sled", "Trough", "Wallow", "Bellows",
	"Gasket", "Flange", "Spindle", "Cog", "Yoke", "Winch", "Crank", "Piston",
	"Hopper", "Tender", "Dredger", "Auger", "Borer", "Nozzle", "Fitting", "Coupler",
	"Bearing", "Strut", "Gimbal", "Carriage", "Davit", "Gantry", "Bung", "Valve",
	"Chamber", "Chassis", "Plodder", "Trundler", "Waddler", "Toddler", "Stumbler", "Scuttler",
	"Grumbler", "Cackler", "Guzzler", "Snorter", "Belcher", "Spitter", "Dripper", "Leaker",
	"Squeaker", "Rattler", "Clatterer", "Thumper", "Clanker", "Honker", "Puffer", "Wheezer",
	"Growler", "Muncher", "Chewer", "Nibbler", "Pecker", "Scratcher", "Rooter", "Grubber",
	"Gleaner", "Forager", "Scavenger", "Sifter", "Sweeper", "Cobbler", "Tinkerer", "Fiddler",
	"Weaver", "Spinner", "Fuller", "Currier", "Cooper", "Chandler", "Ostler", "Scullion",
	"Lackey", "Flunkey", "Steward", "Bailiff", "Butler", "Valet", "Almoner", "Hospitaller",
	"Troubadour", "Minstrel", "Jester", "Harlequin", "Puppeteer", "Peddler", "Charlatan", "Mountebank",
	"Philosopher", "Astronomer", "Chronicler", "Antiquarian", "Cartographer", "Scholar", "Scribe", "Archivist",
	"Librarian", "Theologian", "Diplomat", "Emissary", "Legate", "Ambassador", "Consul", "Magistrate",
	"Proctor", "Arbiter", "Ombudsman", "Hierophant", "Virtuoso", "Aesthete", "Connoisseur", "Dilettante",

	# === SERIOUS / WARLIKE ===
	"Digger", "Lifter", "Breaker", "Cutter", "Grinder", "Pusher", "Loader", "Rammer",
	"Scraper", "Dozer", "Roller", "Striker", "Press", "Pulverizer", "Crusher", "Cleaver",
	"Slicer", "Piercer", "Splitter", "Severer", "Flayer", "Executioner", "Liquidator", "Inquisitor",
	"Punisher", "Avenger", "Reckoner", "Dominator", "Conqueror", "Subjugator", "Oppressor", "Tyrant",
	"Warlord", "Warmaster", "Overlord", "Imperator", "Destroyer", "Annihilator", "Obliterator", "Decimator",
	"Devastator", "Exterminator", "Eradicator", "Terminator", "Vindicator", "Retaliator", "Interceptor", "Suppressor",
	"Infiltrator", "Stalker", "Predator", "Hunter", "Tracker", "Slayer", "Butcher", "Warmonger",
	"Warmachine", "Siegebreaker", "Dreadbringer", "Stormbringer", "Hellion", "Ravager", "Raider", "Berserker",
	"Gladiator", "Centurion", "Legionnaire", "Grenadier", "Bombardier", "Gunner", "Marksman", "Sharpshooter",
	"Sniper", "Trooper", "Shocktrooper", "Commando", "Fusilier", "Cuirassier", "Hussar", "Lancer",
	"Chasseur", "Pikeman", "Halberdier", "Swordsman", "Shieldbearer", "Bulwark", "Bastion", "Ironclad",
	"Dreadguard", "Enforcer", "Sentinel", "Vanguard", "Outrider", "Dragoon", "Goliath", "Dreadnought",
	"Marauder", "Sapper", "Pioneer", "Reaver", "Harrier", "Warden", "Marshal", "Warmace",
	"Warhammer", "Battleaxe", "Broadsword", "Claymore", "Bayonet", "Ballista", "Catapult", "Trebuchet",
	"Bombard", "Howitzer", "Mortar", "Autocannon", "Gatling", "Vulcan", "Firestorm", "Hellfire",
]

# Roman numerals only go as high as the format plausibly would. A "Mk XLVII"
# reads as a joke about roman numerals rather than as equipment.
const ROMAN = [
	"I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
	"XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX",
]

const SUFFIX_LETTERS = ["A", "B", "C", "D", "E", "H", "K", "R", "S", "T"]
const AUSF_LETTERS = ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "M"]
const YEARS = [1897, 1903, 1914, 1915, 1918, 1926, 1930, 1934, 1938, 1941, 1944]


# Returns a designation string. Pass an rng for reproducible output (tests);
# omit it for a fresh random name.
static func generate(rng: RandomNumberGenerator = null) -> String:
	var r := rng
	if r == null:
		r = RandomNumberGenerator.new()
		r.randomize()

	var compound: String = HEADS[r.randi() % HEADS.size()] + TAILS[r.randi() % TAILS.size()]

	# Rich distribution of procurement, marks, ordnance, blocks, and continental specs
	match r.randi() % 24:
		0, 1: # Standard Mark
			return "%s Mk %s" % [compound, ROMAN[r.randi() % ROMAN.size()]]
		2: # Starred Mark (upgrade / revision)
			var stars := "*" if (r.randi() % 2 == 0) else "**"
			return "%s Mk %s%s" % [compound, ROMAN[r.randi() % ROMAN.size()], stars]
		3: # Mark + Suffix
			return "%s Mk %s%s" % [
				compound,
				ROMAN[r.randi() % ROMAN.size()],
				SUFFIX_LETTERS[r.randi() % SUFFIX_LETTERS.size()]]
		4: # Mark + Mod
			return "%s Mk %s Mod %d" % [
				compound,
				ROMAN[r.randi() % ROMAN.size()],
				r.randi_range(1, 6)]
		5, 6: # Standard Ordnance Model
			return "%s M%d" % [compound, r.randi_range(10, 99)]
		7: # Subvariant Ordnance (e.g. M4A3)
			return "%s M%dA%d" % [compound, r.randi_range(1, 9), r.randi_range(1, 4)]
		8: # Ordnance Dash (e.g. M50-D)
			return "%s M%d-%s" % [compound, r.randi_range(10, 80), SUFFIX_LETTERS[r.randi() % SUFFIX_LETTERS.size()]]
		9: # Type Prefix
			return "Type %d %s" % [r.randi_range(2, 99), compound]
		10: # Type Subvariant Prefix (e.g. Type 89-B)
			return "Type %d-%s %s" % [
				r.randi_range(10, 99),
				SUFFIX_LETTERS[r.randi() % SUFFIX_LETTERS.size()],
				compound]
		11: # Pattern
			return "%s Pattern %d" % [compound, r.randi_range(4, 45)]
		12: # Model Year
			return "%s Model %d" % [compound, YEARS[r.randi() % YEARS.size()]]
		13: # Mle Year
			return "%s Mle %d" % [compound, YEARS[r.randi() % YEARS.size()]]
		14: # Ausf.
			return "%s Ausf. %s" % [compound, AUSF_LETTERS[r.randi() % AUSF_LETTERS.size()]]
		15: # Ausf. Subvariant
			return "%s Ausf. %s%d" % [compound, AUSF_LETTERS[r.randi() % AUSF_LETTERS.size()], r.randi_range(1, 3)]
		16: # Numbered
			return "%s No. %d" % [compound, r.randi_range(2, 40)]
		17: # Numbered Mark (e.g. No. 4 Mk II)
			return "%s No. %d Mk %s" % [compound, r.randi_range(1, 9), ROMAN[r.randi() % 8]]
		18: # Block Roman
			return "%s Block %s" % [compound, ROMAN[r.randi() % 10]]
		19: # Block Number
			return "%s Block %d" % [compound, r.randi_range(10, 60)]
		20: # Series
			return "%s Series %s" % [compound, ROMAN[r.randi() % 12]]
		21: # Mod.
			return "%s Mod. %d" % [compound, r.randi_range(28, 55)]
		22: # Dash Alphanumeric
			return "%s-%d%s" % [
				compound,
				r.randi_range(2, 9),
				SUFFIX_LETTERS[r.randi() % SUFFIX_LETTERS.size()]]
		_: # Bureau Object / Project
			if r.randi() % 2 == 0:
				return "Object %d %s" % [r.randi_range(100, 999), compound]
			else:
				return "Project %d %s" % [r.randi_range(12, 88), compound]


# Generates a punchy, pronounceable military slang portmanteau / abbreviation
# for long unit names (e.g. "VanguardDreadnought Mk IV" -> "Vandread",
# "CitadelFuller No. 4" -> "Citful", "High Mobility Multipurpose Wheeled Vehicle" -> "Humvee").
# Short names (<= 8 chars) return empty string as no abbreviation is needed.
static func suggest_abbreviation(name: String) -> String:
	var trimmed := name.strip_edges()
	if trimmed.is_empty():
		return ""

	# Strip leading designation prefixes like "Type 17", "Object 279", "Project 44"
	var core := trimmed
	var prefix_regex := RegEx.new()
	prefix_regex.compile("(?i)^(Type \\d+[-\\w]*|Object \\d+|Project \\d+)\\s*")
	core = prefix_regex.sub(core, "")

	# Strip trailing designation suffixes like "Mk IV*", "M38", "Ausf. D", "No. 4", "Series V", etc.
	var suffix_regex := RegEx.new()
	suffix_regex.compile("(?i)\\s+(Mk\\s+[\\w*]+.*|M\\d+.*|Ausf\\.\\s*.*|No\\.\\s*.*|Series\\s+.*|Block\\s+.*|Pattern\\s+.*|Model\\s+.*|Mle\\s+.*|Mod\\.\\s*.*|-\\d+.*|\\(.*\\))$")
	core = suffix_regex.sub(core, "")
	core = core.strip_edges()

	if core.length() <= 8:
		return ""

	var words_regex := RegEx.new()
	words_regex.compile("[A-Z]?[a-z]+|[A-Z]+(?=[A-Z][a-z]|\\d|\\W|$)|\\d+")
	var matches := words_regex.search_all(core)
	var words: Array[String] = []
	for m in matches:
		var w := m.get_string().strip_edges()
		if not w.is_empty():
			words.append(w)

	if words.is_empty():
		var fallback_regex := RegEx.new()
		fallback_regex.compile("\\w+")
		for m in fallback_regex.search_all(trimmed):
			var w := m.get_string().strip_edges()
			if not w.is_empty():
				words.append(w)

	if words.is_empty():
		return ""

	# Short single-word names don't need an abbreviation
	if words.size() == 1 and words[0].length() <= 8:
		return ""

	# Multi-word phrase (e.g. High Mobility Multipurpose Wheeled Vehicle -> Humvee)
	if words.size() >= 4:
		var initials := ""
		for w in words:
			initials += w.left(1).to_upper()
		if initials == "HMMWV" or initials.contains("HMMWV"):
			return "Humvee"
		if initials.length() <= 5:
			var has_vowel := false
			for ch in initials:
				if ch in "AEIOU":
					has_vowel = true
					break
			if not has_vowel:
				return (initials.left(1) + "u" + initials.substr(1, 2).to_lower() + "ee").capitalize()
		return initials

	if words.size() == 3:
		var initials := ""
		for w in words:
			initials += w.left(1).to_upper()
		return initials

	if words.size() == 2:
		var w1 := words[0]
		var w2 := words[1]
		var s1 := _extract_syllable(w1, 4).capitalize()
		var w2_l := w2.to_lower()
		var s2 := ""

		# Recognized root anchors
		if "dread" in w2_l: s2 = "dread"
		elif "zerk" in w2_l or "berserk" in w2_l: s2 = "zerk"
		elif "strike" in w2_l: s2 = "strike"
		elif "crush" in w2_l: s2 = "crush"
		elif "break" in w2_l: s2 = "break"
		elif "munch" in w2_l: s2 = "munch"
		elif "haul" in w2_l: s2 = "haul"
		elif "gun" in w2_l: s2 = "gun"
		elif "hound" in w2_l: s2 = "hound"
		elif "guard" in w2_l: s2 = "guard"
		elif "bringer" in w2_l: s2 = "bring"
		else:
			s2 = _extract_syllable(w2, 4).to_lower()
			var root_regex := RegEx.new()
			root_regex.compile("(?i)(er|or|ier|ought|ing|ation|ant|ard|ist|ian|ment)$")
			var root2 := root_regex.sub(w2_l, "")
			if root2.length() >= 3 and root2.length() <= 5:
				s2 = root2

		if not s1.is_empty() and not s2.is_empty() and s1.right(1).to_lower() == s2.left(1).to_lower():
			s2 = s2.substr(1)

		var res := (s1 + s2).capitalize()
		if res.to_lower() == core.to_lower():
			return ""
		return res

	if words.size() == 1 and words[0].length() > 8:
		return _extract_syllable(words[0], 4).capitalize() + "o"

	return ""


static func _extract_syllable(word: String, max_len: int = 4) -> String:
	var w := word.to_lower()
	var v_regex := RegEx.new()
	v_regex.compile("[aeiouy]+")
	var v_match := v_regex.search(w)
	if v_match == null:
		return w.left(max_len)
	var end_v := v_match.get_end()
	var rest := w.substr(end_v)
	var c_regex := RegEx.new()
	c_regex.compile("[^aeiouy]+")
	var c_match := c_regex.search(rest)
	var syl := ""
	if c_match != null and c_match.get_start() == 0:
		var c_str := c_match.get_string()
		var c_len := 1 if end_v >= 3 else mini(c_str.length(), 2)
		syl = w.left(end_v + c_len)
	else:
		syl = w.left(end_v)
	if syl.length() > 2 and syl.unicode_at(syl.length() - 1) == syl.unicode_at(syl.length() - 2):
		syl = syl.left(syl.length() - 1)
	return syl.left(max_len)


# A batch of distinct suggestions, for anywhere that wants to offer a choice
# rather than a single roll. Gives up rather than looping forever if the
# word lists can't produce enough uniques.
static func generate_batch(count: int, rng: RandomNumberGenerator = null) -> Array:
	var out: Array = []
	var attempts := 0
	while out.size() < count and attempts < count * 20:
		var candidate := generate(rng)
		if candidate not in out:
			out.append(candidate)
		attempts += 1
	return out
