// Logic tests for the pure Core sources (compiled with Sources/Core/*.swift as main.swift by ios-test.sh):
// serving scaling, nutrient sums, last-writer-wins merging of sync payloads, outbox persistence,
// lenient decoding, day keys and the server's time zone, display units, server setup links, the Apple Health
// daily totals, the demo fixture, and AI logging (config, model, job and draft decoding from Tests/Fixtures,
// draft editing math, error copy, photo resizing with EXIF and GPS stripped, the speed settings, elapsed_ms and
// cancelled jobs, the progress timer, and what a hidden job does when it finishes).
import CoreGraphics
import Foundation
import ImageIO

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() { failures += 1; print("FAIL line \(line): \(message)") }
}
func near(_ a: Double?, _ b: Double, _ eps: Double = 0.001) -> Bool { a.map { abs($0 - b) < eps } ?? false }

// Day keys follow the server's zone (GET /v1/meta). The fixtures below use a zone with US DST dates, so the
// DST checks mean something wherever the tests run.
check(Days.initialZone(nil).identifier == TimeZone.current.identifier, "before the first sync: the phone's zone")
check(Days.initialZone("Not/AZone").identifier == TimeZone.current.identifier, "an unknown cached zone falls back to the phone's")
check(Days.initialZone("Asia/Tokyo").identifier == "Asia/Tokyo", "the cached server zone")
Days.setZone(TimeZone(identifier: "America/Chicago")!)

// MARK: Serving scaling

let yogurt = Food(id: "y", name: "Greek yogurt", brand: "Fage", serving: Serving(amount: 1, unit: "container", grams: 170),
                  portions: [Portion(label: "1 cup", grams: 245)], nutrients: ["kcal": 90, "protein": 18, "sodium": 65])
check(yogurt.servingLabel == "container (170 g)", "serving label: \(yogurt.servingLabel)")
let e1 = yogurt.entry(servings: 1.5, meal: .breakfast, day: "2026-11-08")
check(near(e1.kcal, 135) && near(e1.nutrients["protein"], 27) && near(e1.grams, 255), "1.5 servings scale kcal, protein and grams")
check(e1.nutrients["fat"] == nil, "unknown stays unknown when scaling")
check(e1.detailLine(.metric) == "1.5 container · 255 g", "detail line: \(e1.detailLine(.metric))")
check(near(yogurt.servings(amount: 340, unit: .grams), 2), "grams → servings")
check(near(yogurt.servings(amount: 1, unit: .portion(0)), 245.0 / 170), "portion → servings by weight")
check(near(yogurt.amount(servings: 2, in: .grams), 340), "unit change keeps grams")
check(near(yogurt.amount(servings: 1, in: .ounces), 170 / 28.349523125), "ounces")
check(yogurt.amountUnits(.metric) == [.serving, .portion(0), .grams, .ounces], "unit menu order")
let noWeight = Food(id: "n", name: "Mystery", nutrients: ["kcal": 100])
check(noWeight.amountUnits(.us) == [.serving], "no gram weight: servings only")
check(near(noWeight.servings(amount: 50, unit: .grams), 1) && near(noWeight.servings(amount: 3, unit: .ounces), 1),
      "no weight: grams and ounces fall back to one serving, never counted as servings")
check(near(noWeight.servings(amount: 2, unit: .portion(0)), 1), "no weight: a portion falls back to one serving")
check(noWeight.normalized(amount: 150, unit: .grams) == (1, .serving) && noWeight.normalized(amount: 2.5, unit: .serving) == (2.5, .serving),
      "normalized keeps servings and drops units that need a weight")
check(yogurt.normalized(amount: 150, unit: .grams) == (150, .grams) && !noWeight.offers(.grams) && yogurt.offers(.ounces),
      "a food with a weight keeps grams")
let rescaled = e1.rescaled(servings: 3)
check(near(rescaled.kcal, 270) && near(rescaled.grams, 510) && rescaled.servings == 3, "rescale entry snapshot")
check(e1.rescaled(servings: 0).servings == 1.5, "non-positive servings are ignored")
check(near(NutritionMath.kcalFromMacros(protein: 30, carbs: 40, fat: 10), 370), "4/4/9")
check(NutritionMath.kcalFromMacros(protein: nil, carbs: nil, fat: nil) == nil, "no macros, no kcal")
let shares = NutritionMath.macroKcalShares(["protein": 25, "carbs": 25, "fat": 0])
check(near(shares.protein, 0.5) && near(shares.fat, 0), "macro kcal shares")

// MARK: Recipe math

let oatsFood = Food(id: "oats", name: "Oats", serving: Serving(amount: 1, unit: "cup", grams: 80),
                    nutrients: ["kcal": 300, "protein": 10, "fiber": 8])
let milkFood = Food(id: "milk", name: "Milk", serving: Serving(amount: 1, unit: "cup", grams: 244),
                    nutrients: ["kcal": 120, "protein": 8, "calcium": 300])
let saltFood = Food(id: "salt", name: "Salt", nutrients: ["sodium": 2300])
// Same numbers as the server's recipes_are_recomputed_on_the_server test: 2 cups oats + 244 g milk, 2 servings.
let milkServings = milkFood.servings(amount: 244, unit: .grams)
check(near(milkServings, 1) && near(RecipeMath.servings(of: milkFood, grams: 122), 0.5), "component grams → servings")
check(RecipeMath.servings(of: saltFood, grams: 5) == nil, "no serving weight: grams can't convert")
let oatsRecipe = RecipeMath.totals([.init(food: oatsFood, servings: 2), .init(food: milkFood, servings: milkServings)], recipeServings: 2)
check(near(oatsRecipe.total["kcal"], 720) && near(oatsRecipe.perServing["kcal"], 360) && near(oatsRecipe.perServing["protein"], 14),
      "per-serving = component totals / servings: \(oatsRecipe.perServing)")
check(near(oatsRecipe.perServing["fiber"], 8) && near(oatsRecipe.perServing["calcium"], 150), "keys known in any component are summed")
check(near(oatsRecipe.totalGrams, 404) && near(oatsRecipe.gramsPerServing, 202), "serving weight when every component has one")
check(oatsRecipe.partial == ["fiber", "calcium"], "missing nutrients propagate as partial: \(oatsRecipe.partial)")
check(oatsRecipe.perServing["fat"] == nil, "unknown in every component stays unknown")
let portionScaled = RecipeMath.totals([.init(food: yogurt, servings: yogurt.servings(amount: 1, unit: .portion(0)))], recipeServings: 1)
check(near(portionScaled.perServing["kcal"], 90 * 245 / 170), "portions scale by weight")
let salted = RecipeMath.totals([.init(food: oatsFood, servings: 1), .init(food: saltFood, servings: 0.25)], recipeServings: 4)
check(salted.gramsPerServing == nil && near(salted.perServing["sodium"], 143.75) && salted.partial.contains("kcal"),
      "a weightless component drops the serving weight and marks kcal partial")
check(RecipeMath.totals([.init(food: oatsFood, servings: 0)], recipeServings: 2).total.isEmpty, "zero-serving components are ignored")
check(near(RecipeMath.totals([.init(food: oatsFood, servings: 1)], recipeServings: 0).perServing["kcal"], 300),
      "non-positive recipe servings count as 1, like the server")
let built = RecipeMath.recipe(name: "Overnight oats", parts: [.init(food: oatsFood, servings: 2), .init(food: milkFood, servings: 1)], recipeServings: 2)
check(built.kind == .recipe && built.source == "recipe" && built.recipeServings == 2 && built.id != nil, "recipe row shape")
check(built.components == [Component(foodID: "oats", servings: 2), Component(foodID: "milk", servings: 1)], "components by food id")
check(near(built.kcal, 360) && built.serving.unit == "serving" && near(built.serving.grams, 202), "per-serving nutrients and serving weight")
let builtJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(built)) as! [String: Any]
check(builtJSON["kind"] as? String == "recipe" && builtJSON["recipe_servings"] as? Double == 2
      && (builtJSON["components"] as? [[String: Any]])?.first?["food_id"] as? String == "oats", "recipe wire format")
var edited = built
edited.favorite = true
let rebuilt = RecipeMath.recipe(name: "Oats for 4", parts: [.init(food: oatsFood, servings: 4)], recipeServings: 4, base: edited)
check(rebuilt.id == built.id && rebuilt.favorite && rebuilt.name == "Oats for 4" && near(rebuilt.kcal, 300), "editing keeps identity")
let logged = rebuilt.entry(servings: 1.5, meal: .breakfast, day: "2026-11-08")
check(near(logged.kcal, 450) && near(logged.grams, 120) && logged.foodID == built.id, "a recipe logs like any food")
let demoRecipes = DemoData.recipes
check(demoRecipes.count >= 4 && demoRecipes.allSatisfy { r in
    r.components.allSatisfy { c in DemoData.allFoods.contains { $0.id == c.foodID } } && (r.kcal ?? 0) > 0
}, "demo recipes point at demo foods and have nutrients")

// MARK: Nutrient sums and day summaries

let sum = NutritionMath.sum([["kcal": 100, "protein": 10], ["kcal": 50.5, "fiber": 2], [:]])
check(near(sum["kcal"], 150.5) && near(sum["protein"], 10) && near(sum["fiber"], 2) && sum["fat"] == nil, "sum keeps unknowns unknown")
check(NutritionMath.percent(96, of: 150) == 64 && NutritionMath.percent(5, of: 0) == nil && NutritionMath.percent(nil, of: 10) == nil, "percent of target")

let day = "2026-11-08"
var water = Entry(day: day, meal: .snack, name: "Water", nutrients: ["water": 500])
water.loggedAt = 1
var lunch = Entry(day: day, meal: .lunch, name: "Bowl", nutrients: ["kcal": 700, "protein": 50, "vit_d": 2])
lunch.loggedAt = 3
var lunch2 = Entry(day: day, meal: .lunch, name: "Coke", nutrients: ["kcal": 140, "sodium": 45])
lunch2.loggedAt = 2
var gone = Entry(day: day, meal: .lunch, name: "Deleted", nutrients: ["kcal": 999])
gone.deleted = true
let other = Entry(day: "2026-11-07", meal: .lunch, name: "Other day", nutrients: ["kcal": 1])
let s = DaySummary(day: day, entries: [water, lunch, lunch2, gone, other])
check(near(s.kcal, 840) && near(s.waterMl, 500), "day totals skip tombstones and other days; water counted")
check(s.entries(.lunch).map(\.name) == ["Coke", "Bowl"], "meal rows ordered by logged_at, water hidden")
check(s.entries(.snack).isEmpty && s.foodEntryCount == 2, "water isn't a food entry")
check(near(s.kcal(.lunch), 840) && near(s.kcal(.dinner), 0), "per-meal kcal")
check(s.isPartial("vit_d") && !s.isPartial("kcal"), "partial data when an entry lacks a nutrient")
var goals = Goals()
goals.targets = ["kcal": 2350, "protein": 150, "sodium": 2300, "vit_d": 20, "fiber": 33]
goals.overrides = ["protein": 160]
goals.mealSplit = ["lunch": 0.35]
check(goals.target("protein") == 160, "overrides win")
check(near(goals.mealTarget(.lunch), 822.5) && goals.mealTarget(.dinner) == nil, "meal split target")
check(s.lowest(goals: goals, minEntries: 1).first?.info.key == "vit_d", "lowest target nutrient")
check(s.lowest(goals: goals, minEntries: 2).isEmpty, "needs two entries of data")
goals.targets["sodium"] = 40
check(s.exceededLimits(goals: goals).first?.info.key == "sodium", "exceeded limit")

// MARK: LWW merge of sync payloads

var db = LocalDatabase()
var row = Entry(id: "e", day: day, meal: .lunch, name: "new", nutrients: ["kcal": 10])
row.updatedAt = 200
var merge = db.merge(SyncPayload(version: 5, entries: [row]))
check(db.entries["e"]?.name == "new" && db.version == 5 && merge.arrivedEntryIDs == ["e"], "first row arrives")
var older = row
older.name = "old"; older.updatedAt = 100
merge = db.merge(SyncPayload(version: 4, entries: [older]))
check(db.entries["e"]?.name == "new" && db.version == 5 && merge.changedDays.isEmpty, "older write ignored, version never goes back")
var tie = row
tie.name = "tie"
db.merge(SyncPayload(version: 6, entries: [tie]))
check(db.entries["e"]?.name == "tie", "tie goes to the incoming row, like the server")
var moved = tie
moved.day = "2026-11-09"; moved.updatedAt = 300
merge = db.merge(SyncPayload(version: 7, entries: [moved]))
check(merge.changedDays == [day, "2026-11-09"], "moving a day touches both days")
let sparse = try! JSONDecoder().decode(Entry.self, from: Data(#"{"id":"e","deleted":true,"updated_at":400,"version":8}"#.utf8))
db.merge(SyncPayload(version: 8, entries: [sparse]))
check(db.entries["e"]?.deleted == true && db.entries["e"]?.name == "tie" && db.entries["e"]?.updatedAt == 400, "sparse tombstone keeps known fields")
var stale = moved
stale.deleted = false; stale.updatedAt = 350
db.merge(SyncPayload(version: 9, entries: [stale]))
check(db.entries["e"]?.deleted == true, "a stale copy can't resurrect a tombstone")
var g1 = Goals(); g1.updatedAt = 10; g1.targets = ["kcal": 2000]
var g2 = Goals(); g2.updatedAt = 5; g2.targets = ["kcal": 1500]
db.merge(SyncPayload(version: 10, goals: [g1]))
merge = db.merge(SyncPayload(version: 11, goals: [g2]))
check(db.goals?.kcal == 2000 && !merge.goalsChanged, "goals LWW")
let unsaved = Food(id: nil, name: "catalog", nutrients: [:])
db.merge(SyncPayload(version: 12, foods: [unsaved]))
check(db.foods.isEmpty, "foods without ids are ignored")
var local = row
local.id = "local"; local.updatedAt = 900
db.put(local)
var server = local
server.updatedAt = 800; server.name = "server"
db.merge(SyncPayload(version: 13, entries: [server]))
check(db.entries["local"]?.updatedAt == 900, "a newer optimistic local write survives an older server copy")

// Out-of-order sync responses: the server recomputes goals without changing updated_at, so versions decide
var ooo = LocalDatabase()
var goalsOld = Goals(); goalsOld.updatedAt = 50; goalsOld.version = 12; goalsOld.targets = ["kcal": 2000]
var goalsNew = goalsOld; goalsNew.version = 15; goalsNew.targets = ["kcal": 2200]
ooo.merge(SyncPayload(version: 15, goals: [goalsNew]))
merge = ooo.merge(SyncPayload(version: 12, goals: [goalsOld]))
check(ooo.goals?.kcal == 2200 && !merge.goalsChanged && ooo.version == 15,
      "an older response arriving late can't regress recomputed goals or move the cursor back")
var goalsNewer = goalsNew; goalsNewer.version = 16; goalsNewer.targets = ["kcal": 2300]
ooo.merge(SyncPayload(version: 16, goals: [goalsNewer]))
check(ooo.goals?.kcal == 2300, "a newer server version with the same updated_at is taken")
var oooEntry = Entry(id: "o", day: day, meal: .lunch, name: "v9", nutrients: [:]); oooEntry.updatedAt = 100; oooEntry.version = 9
var oooStale = oooEntry; oooStale.name = "v7"; oooStale.version = 7
ooo.merge(SyncPayload(version: 9, entries: [oooEntry]))
ooo.merge(SyncPayload(version: 7, entries: [oooStale]))
check(ooo.entries["o"]?.name == "v9" && ooo.version == 16, "a lower version of an entry is ignored at the same timestamp")
var oooLocal = oooEntry; oooLocal.name = "local edit"; oooLocal.updatedAt = 300
ooo.put(oooLocal)
var oooServer = oooEntry; oooServer.name = "other device"; oooServer.updatedAt = 200; oooServer.version = 20
ooo.merge(SyncPayload(version: 20, entries: [oooServer]))
check(ooo.entries["o"]?.name == "local edit", "a higher server version still loses to a newer unacknowledged local write")
var oooEcho = oooLocal; oooEcho.version = 21
ooo.merge(SyncPayload(version: 21, entries: [oooEcho]))
check(ooo.entries["o"]?.version == 21, "the server's echo of the local write brings its version")
let tieNoVersion = { () -> Entry in var e = oooEcho; e.name = "unversioned"; e.version = nil; return e }()
ooo.merge(SyncPayload(version: 22, entries: [tieNoVersion]))
check(ooo.entries["o"]?.name == "unversioned", "without a version, LWW by updated_at decides")

// Outbox replay on launch: the cache is saved after a delay, so it can miss a write the outbox holds
var staleCache = LocalDatabase()
var cachedEntry = Entry(id: "c", day: day, meal: .lunch, name: "before", servings: 1, nutrients: ["kcal": 100]); cachedEntry.updatedAt = 100
var cachedFood = Food(id: "cf", name: "Cached food", nutrients: [:]); cachedFood.updatedAt = 100
var doomed = cachedEntry; doomed.id = "d"; doomed.name = "to delete"
var synced = cachedEntry; synced.id = "s"; synced.name = "newer from another device"; synced.updatedAt = 500
staleCache.put(cachedEntry); staleCache.put(cachedFood); staleCache.put(doomed); staleCache.put(synced)
var pending = Outbox()
var editedEntry = cachedEntry; editedEntry.name = "after"; editedEntry.servings = 2; editedEntry.updatedAt = 200
pending.enqueue(.upsert(.entries, editedEntry))
var newEntry = cachedEntry; newEntry.id = "n"; newEntry.name = "new offline"; newEntry.day = "2026-11-07"; newEntry.updatedAt = 210
pending.enqueue(.upsert(.entries, newEntry))
var renamedFood = cachedFood; renamedFood.name = "Renamed"; renamedFood.updatedAt = 220
pending.enqueue(.upsert(.foods, renamedFood))
pending.enqueue(.delete(.entries, id: "d", at: 230))
var olderOutboxed = synced; olderOutboxed.name = "older queued copy"; olderOutboxed.updatedAt = 400
pending.enqueue(.upsert(.entries, olderOutboxed))
var pendingGoals = Goals(); pendingGoals.updatedAt = 240; pendingGoals.overrides = ["protein": 170]
pending.enqueue(.upsert(.goals, pendingGoals))
let replayURL = FileManager.default.temporaryDirectory.appending(path: "plate-replay-\(UUID().uuidString)/outbox.json")
try! pending.save(to: replayURL)
let reloaded = Outbox.load(from: replayURL)
var relaunched = try! JSONDecoder().decode(LocalDatabase.self, from: JSONEncoder().encode(staleCache))
relaunched.replay(reloaded)
try? FileManager.default.removeItem(at: replayURL.deletingLastPathComponent())
check(relaunched.entries["c"]?.name == "after" && relaunched.entries["c"]?.servings == 2 && relaunched.entries["c"]?.updatedAt == 200,
      "a queued edit missing from the cache is applied again on launch")
check(relaunched.entries["n"]?.name == "new offline" && relaunched.foods["cf"]?.name == "Renamed", "queued new rows and food edits too")
check(relaunched.entries["d"]?.deleted == true && relaunched.entries["d"]?.name == "to delete", "a queued delete keeps the known fields")
check(relaunched.entries["s"]?.name == "newer from another device", "a queued write never overrides a newer cached copy")
check(relaunched.goals?.overrides["protein"] == 170, "queued goals")
var nextEdit = relaunched.entries["c"]!; nextEdit.note = "later"; nextEdit.updatedAt = 300
var coalesced = reloaded
coalesced.enqueue(.upsert(.entries, nextEdit))
check(coalesced.items.first(where: { $0.mutation.key == "entries/c" })?.mutation.row.object?["servings"]?.double == 2,
      "a later edit of the row builds on the queued change instead of replacing it with the stale copy")

// Reset: the server's database is behind ours (SPEC "Server notes")
var ahead = LocalDatabase()
var keptFood = Food(id: "kept", name: "Server copy older", nutrients: ["kcal": 1]); keptFood.updatedAt = 100
var serverFood = keptFood; serverFood.name = "server"; serverFood.updatedAt = 50
var onlyLocal = Food(id: "local-only", name: "Only here", nutrients: [:]); onlyLocal.updatedAt = 10
var localRecipe = Food(id: "local-recipe", kind: .recipe, name: "Recipe", nutrients: [:]); localRecipe.updatedAt = 5
localRecipe.components = [Component(foodID: "local-only", servings: 1)]
var serverNewer = Food(id: "srv", name: "server newer", nutrients: [:]); serverNewer.updatedAt = 500
var localOlder = serverNewer; localOlder.name = "local older"; localOlder.updatedAt = 400
var goneHere = Food(id: "gone", name: "deleted here only", nutrients: [:]); goneHere.updatedAt = 7; goneHere.deleted = true
for f in [keptFood, onlyLocal, localRecipe, localOlder, goneHere] { ahead.put(f) }
var localEntry = Entry(id: "le", day: day, meal: .lunch, foodID: "local-only", name: "entry", nutrients: [:]); localEntry.updatedAt = 1
ahead.put(localEntry)
ahead.merge(SyncPayload(version: 900))
let resetJSON = #"{"version":40,"reset":true,"foods":[]}"#
check(try! JSONDecoder().decode(SyncPayload.self, from: Data(resetJSON.utf8)).reset, "reset decodes")
check(!(try! JSONDecoder().decode(SyncPayload.self, from: Data(#"{"version":3}"#.utf8))).reset, "reset defaults to false")
let resend = ahead.reset(to: SyncPayload(version: 40, reset: true, foods: [serverFood, serverNewer]))
check(ahead.version == 40, "a reset takes the server's version, so the next poll isn't ahead again")
check(ahead.foods["kept"]?.name == "Server copy older" && ahead.foods["srv"]?.name == "server newer" && ahead.foods["gone"] == nil,
      "local rows newer than the snapshot are kept, older ones lose, local-only tombstones are dropped")
check(resend.map(\.key) == ["foods/local-only", "foods/kept", "foods/local-recipe", "entries/le"],
      "re-sends rows missing from or older in the snapshot, ingredients before recipes before entries: \(resend.map(\.key))")
check(resend.allSatisfy { $0.op == "upsert" } && ahead.entries["le"] != nil, "re-sent as upserts, kept locally")
var restoredCopy = ahead.foods["kept"]!; restoredCopy.version = 41
ahead.merge(SyncPayload(version: 41, foods: [restoredCopy]))
check(ahead.foods["kept"]?.version == 41, "rows kept over a reset forget the old server's version, so the restored one's lower numbers apply")

// ids: the server kept an existing food for one we sent
var merging = LocalDatabase()
var dupFood = Food(id: "dup", name: "Banana", nutrients: ["kcal": 105], sourceRef: "usda:1"); dupFood.updatedAt = 10
var usesDup = Food(id: "r1", kind: .recipe, name: "Smoothie", nutrients: [:]); usesDup.updatedAt = 10
usesDup.components = [Component(foodID: "dup", servings: 1), Component(foodID: "milk", servings: 1)]
merging.put(dupFood); merging.put(usesDup)
merging.put(Entry(id: "de", day: day, meal: .snack, foodID: "dup", name: "Banana", nutrients: ["kcal": 105]))
let resent = merging.redirectFood("dup", to: "orig")
check(merging.entries["de"]?.foodID == "orig", "entries point at the stored food")
check(resent.map(\.id) == ["r1"] && merging.foods["r1"]?.components.map(\.foodID) == ["orig", "milk"]
      && (merging.foods["r1"]?.updatedAt ?? 0) > 10, "recipes are repointed and returned to send again")
check(merging.foods["dup"]?.deleted == true && merging.mergedTarget(of: "dup") == "orig" && !merging.isDeletedFood("dup"),
      "the local duplicate becomes a redirecting tombstone, not a deleted food")
check(merging.redirectFood("orig", to: "orig").isEmpty, "same id: nothing to do")
merging.forget(table: "entries", id: "de")
merging.forget(table: "foods", id: "r1")
check(merging.entries["de"] == nil && merging.foods["r1"] == nil, "a refused row is dropped so a full sync restores the server's copy")

// A deleted food stays deleted (a stale Food detail must not save it again)
var tomb = LocalDatabase()
var deletedFood = Food(id: "del", name: "Old", nutrients: [:]); deletedFood.deleted = true
tomb.put(deletedFood)
let serverMergeTomb = try! JSONDecoder().decode(Food.self, from: Data(#"{"id":"m","deleted":true,"updated_at":5,"merged_into":"keep"}"#.utf8))
tomb.merge(SyncPayload(version: 1, foods: [serverMergeTomb]))
check(tomb.isDeletedFood("del") && !tomb.isDeletedFood("m") && !tomb.isDeletedFood("unknown") && !tomb.isDeletedFood(nil),
      "deleted vs merged vs unknown foods")
check(tomb.mergedTarget(of: "m") == "keep" && tomb.mergedTarget(of: "del") == nil, "merge tombstones redirect")

// Cache round trip
let cacheData = try! JSONEncoder().encode(db)
let restored = try! JSONDecoder().decode(LocalDatabase.self, from: cacheData)
check(restored.version == db.version && restored.entries.count == db.entries.count && restored.goals?.kcal == 2000, "cache round trip")

// MARK: Outbox persistence

var outbox = Outbox()
let m1 = Mutation.upsert(.entries, row)
outbox.enqueue(m1)
var row2 = row; row2.name = "edit"
outbox.enqueue(Mutation.upsert(.entries, row2))
check(outbox.count == 1, "a newer write to the same row replaces the queued one")
let inFlight = Set(outbox.items.map(\.id))
var row3 = row; row3.name = "edit again"
outbox.enqueue(Mutation.upsert(.entries, row3), protecting: inFlight)
check(outbox.count == 2, "an in-flight write is kept, so the newer one still goes out")
outbox.enqueue(Mutation.delete(.foods, id: "f1", at: 5))
check(outbox.items.last?.mutation.key == "foods/f1" && outbox.items.last?.mutation.op == "delete", "delete mutation")
// Coalescing keeps the queued write's place
var ordered = Outbox()
var ea = row; ea.id = "a"
var eb = row; eb.id = "b"
ordered.enqueue(.upsert(.entries, ea))
ordered.enqueue(.upsert(.entries, eb))
ea.name = "a edited"
ordered.enqueue(.upsert(.entries, ea))
check(ordered.items.map(\.mutation.key) == ["entries/a", "entries/b"] && ordered.items[0].mutation.row.object?["name"]?.string == "a edited",
      "a coalesced write replaces the queued one in place")
var ingredient = Food(id: "ing", name: "Oats", nutrients: [:])
var recipe = Food(id: "rec", kind: .recipe, name: "Porridge", nutrients: [:])
var deps = Outbox()
deps.enqueue(.upsert(.foods, ingredient))
recipe.components = [Component(foodID: "ing", servings: 1)]
deps.enqueue(.upsert(.foods, recipe))
ingredient.name = "Rolled oats"
deps.enqueue(.upsert(.foods, ingredient))
check(deps.items.map(\.mutation.key) == ["foods/ing", "foods/rec"], "an edited ingredient still goes out before its recipe")
var later = Outbox()
let plainRecipe = Food(id: "rec", kind: .recipe, name: "Porridge", nutrients: [:])
later.enqueue(.upsert(.foods, plainRecipe))
later.enqueue(.upsert(.foods, ingredient))
later.enqueue(.upsert(.foods, recipe))
check(later.items.map(\.mutation.key) == ["foods/ing", "foods/rec"], "a recipe that now uses a newer queued food moves behind it")
var bulk = Outbox()
bulk.enqueue(.upsert(.entries, ea))
bulk.enqueue(contentsOf: [.upsert(.entries, ea), .upsert(.entries, eb)])
check(bulk.items.map(\.mutation.key) == ["entries/a", "entries/b"], "bulk re-sends skip rows already queued")

let url = FileManager.default.temporaryDirectory.appending(path: "plate-test-\(UUID().uuidString)/outbox.json")
try! outbox.save(to: url)
var loaded = Outbox.load(from: url)
check(loaded.items == outbox.items, "outbox survives a restart")
loaded.remove(inFlight)
check(loaded.count == 2 && !loaded.items.contains { inFlight.contains($0.id) }, "remove flushed items")
check(Outbox.load(from: url.deletingLastPathComponent().appending(path: "missing.json")).isEmpty, "missing file is an empty outbox")
try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
let wire = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(["mutations": [m1]])) as! [String: Any]
let first = (wire["mutations"] as! [[String: Any]])[0]
check(first["table"] as? String == "entries" && first["op"] as? String == "upsert"
      && (first["row"] as? [String: Any])?["id"] as? String == "e", "mutation wire shape")
var backoff = Backoff(cap: 8)
check([backoff.next(), backoff.next(), backoff.next(), backoff.next(), backoff.next()] == [1, 2, 4, 8, 8], "backoff doubles to the cap")

// MARK: Lenient decoding and unknown fields

let json = #"{"id":"f","name":"Oats","nutrients":{"kcal":150,"protein":"x","fat":-1,"iron":1.8},"serving":{"amount":0.5,"unit":"cup","grams":40},"photo_url":"https://x","favorite":1,"version":3}"#
let food = try! JSONDecoder().decode(Food.self, from: Data(json.utf8))
check(food.nutrients == ["kcal": 150, "iron": 1.8], "bad nutrient values dropped")
check(food.favorite && food.version == 3 && food.servingName == "0.5 cup", "lenient fields")
let back = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(food)) as! [String: Any]
check(back["photo_url"] as? String == "https://x", "unknown fields round-trip")
let payload = try! JSONDecoder().decode(SyncPayload.self, from: Data(#"{"version":42,"entries":[{"id":"a","day":"2026-11-08","meal":"brunch","name":"x","nutrients":{}}],"health_days":[{"id":"2026-11-08","day":"2026-11-08","weight_kg":72.1,"steps":null}]}"#.utf8))
check(payload.version == 42 && payload.entries.first?.meal == .snack && payload.foods.isEmpty, "payload with missing tables and an unknown meal")
check(payload.healthDays.first?.weightKg == 72.1 && payload.healthDays.first?.steps == nil, "health day nulls")
let huge = try! JSONDecoder().decode(Entry.self, from: Data(#"{"id":"h","day":"2026-11-08","name":"x","updated_at":1e300,"logged_at":-9.3e18,"version":9.2e18,"nutrients":{}}"#.utf8))
check(huge.updatedAt == 0 && huge.loggedAt == 0 && huge.version == nil, "out-of-range integers read as unknown instead of trapping")
check(Int(saturating: 1e300) == .max && Int(saturating: -1e300) == .min && Int(saturating: .nan) == 0 && Int(saturating: 2.9) == 2,
      "saturating conversion")
check(NutritionMath.percent(1e300, of: 1) == .max, "a huge percent clamps")

// MARK: Days and formatting

let noonFixture = Days.date("2026-11-08")
check(Days.key(noonFixture) == "2026-11-08", "day key round trip")
check(Days.add(1, to: "2026-11-01") == "2026-11-02" && Days.add(-1, to: "2026-03-08") == "2026-03-07", "day arithmetic across DST")
check(Days.weekStart("2026-11-08") == "2026-11-02", "weeks start Monday")
let lateMar7 = Days.calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30))!
let lateMar7Ms = Int(lateMar7.timeIntervalSince1970) * 1000 + 123
let movedMs = Days.moving(loggedAt: lateMar7Ms, to: "2026-03-08")
let movedDate = Date(timeIntervalSince1970: Double(movedMs) / 1000)
let movedParts = Days.calendar.dateComponents([.hour, .minute], from: movedDate)
check(Days.key(movedDate) == "2026-03-08" && movedParts.hour == 23 && movedParts.minute == 30 && movedMs % 1000 == 123
      && movedMs - lateMar7Ms == 23 * 3_600_000, "moving an entry across DST keeps its wall-clock time on the new day")
check(Days.key(Date(timeIntervalSince1970: Double(Days.moving(loggedAt: movedMs, to: "2026-11-01")) / 1000)) == "2026-11-01"
      && Days.moving(loggedAt: 0, to: "2026-03-08") == 0, "moving across the fall change; unknown stays unknown")
check(Days.title("2026-11-07", today: "2026-11-08") == "Yesterday" && Days.title("2026-11-06", today: "2026-11-08") == "Fri, Nov 6", "titles")
func at(_ h: Int, _ m: Int) -> Date { Days.calendar.date(bySettingHour: h, minute: m, second: 0, of: noonFixture)! }
check(Days.meal(at: at(10, 29)) == .breakfast && Days.meal(at: at(10, 30)) == .lunch && Days.meal(at: at(14, 59)) == .lunch
      && Days.meal(at: at(20, 59)) == .dinner && Days.meal(at: at(21, 0)) == .snack, "meal from time of day")
check(Fmt.trim(1.5) == "1.5" && Fmt.trim(2) == "2" && Fmt.servings(1.5) == "1½", "trim and fractions")
check(Fmt.kcal(nil) == "–", "missing is an en dash")
check(!Fmt.trim(1e20).isEmpty && !Fmt.servings(1e20).isEmpty && !Fmt.servings(-1e19).isEmpty && Fmt.trim(.infinity) == "–"
      && Fmt.servings(.nan) == "–", "huge and non-finite amounts format without trapping")
let realNow = Days.now
Days.now = { Days.date("2026-11-08").addingTimeInterval(11.99 * 3600) }
let beforeMidnight = Days.today
Days.now = { Days.date("2026-11-08").addingTimeInterval(12.01 * 3600) }
check(beforeMidnight == "2026-11-08" && Days.today == "2026-11-09", "today follows the clock across midnight (not cached)")
Days.now = realNow

// MARK: Trends math

check(TrendRange.week.days(endingAt: "2026-11-08") == ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05",
                                                      "2026-11-06", "2026-11-07", "2026-11-08"], "7-day range, oldest first")
check(TrendRange.quarter.days(endingAt: "2026-11-08").count == 90 && TrendRange.quarter.days(endingAt: "2026-11-08").first == "2026-08-11", "90-day range")
check(near(TrendMath.mean([1, nil, 3]), 2) && TrendMath.mean([nil, nil]) == nil, "mean skips unknowns")

func trendDay(_ d: String, _ n: [NutrientMap]) -> DaySummary {
    DaySummary(day: d, entries: n.enumerated().map { i, m in var e = Entry(day: d, meal: .lunch, name: "x\(i)", nutrients: m); e.loggedAt = i; return e })
}
var tg = Goals()
tg.targets = ["kcal": 2000, "protein": 150, "vit_d": 20, "potassium": 3400, "iron": 8, "fiber": 30, "sodium": 2300, "vit_c": 90]
tg.limits = ["sodium"]
let week = [
    trendDay("2026-11-01", [["kcal": 2000, "protein": 100, "vit_d": 2, "potassium": 1700, "iron": 8, "sodium": 3000, "fiber": 30], ["kcal": 100]]),
    trendDay("2026-11-02", []),
    trendDay("2026-11-03", [["kcal": 1800, "protein": 160, "vit_d": 6, "potassium": 3400, "iron": 12, "sodium": 1500, "fiber": 15]]),
    trendDay("2026-11-04", [["kcal": 1500, "protein": 120, "potassium": 1700, "iron": 4, "sodium": 2000, "fiber": 30, "vit_c": 10]]),
]
let vitD = TrendMath.average("vit_d", over: week, goals: tg)
check(vitD?.daysWithData == 2 && near(vitD?.average, 4) && near(vitD?.fraction, 0.2) && vitD?.partialDays == 1,
      "averages count only days with data, empty days and missing days don't drag them to zero")
check(TrendMath.average("vit_c", over: week, goals: tg)?.daysWithData == 1 && TrendMath.average("zinc", over: week, goals: tg) == nil, "no target, no average")
let weak = TrendMath.weakest(week, goals: tg, count: 3, minDays: 2)
check(weak.map(\.key) == ["vit_d", "potassium", "fiber"], "weakest ranks by average % of target, skips 1-day data, macros and limits: \(weak.map(\.key))")
check(!weak.contains { $0.key == "sodium" || $0.key == "protein" }, "limits and protein aren't weakest candidates")
let lim = TrendMath.limits(week, goals: tg)
check(lim.count == 1 && lim[0].key == "sodium" && lim[0].daysOver == 1 && near(lim[0].average, 6500.0 / 3), "limits average separately, counting days over")
check([0.1, 0.25, 0.49, 0.5, 0.99, 1, 1.4].map(TrendMath.heatBucket) == [0, 1, 1, 2, 2, 3, 3], "heatmap buckets")
let heat = TrendMath.heatmapKeys(week, goals: tg, count: 3)
check(heat == ["vit_d", "potassium", "fiber"], "heatmap rows: most often below target, then lowest; no limits, macros or 1-day data: \(heat)")
check(TrendMath.dayFraction(week[1], "vit_d", target: 20) == nil && TrendMath.dayFraction(week[3], "vit_d", target: 20) == nil
      && near(TrendMath.dayFraction(week[2], "vit_d", target: 20), 0.3), "day fraction is nil without data")
check(TrendMath.chunks(Array(1...10), size: 4) == [[1, 2], [3, 4, 5, 6], [7, 8, 9, 10]], "weeks end on the last day")
let split = TrendMath.macroSplit(week)
check(near(split.protein, 1) && near(split.fat, 0), "macro split without carbs or fat is all protein")
let split2 = TrendMath.macroSplit([trendDay("2026-11-05", [["protein": 25, "carbs": 25]]), trendDay("2026-11-06", [["fat": 400.0 / 9]]), trendDay("2026-11-07", [])])
check(near(split2.protein, 1.0 / 6) && near(split2.carbs, 1.0 / 6) && near(split2.fat, 2.0 / 3), "macro split weighs days by kcal: \(split2)")
let wt = TrendMath.weightTrend([(day: "2026-11-03", kg: 72), (day: "2026-11-01", kg: 74), (day: "2026-11-02", kg: 73)])
check(wt.map(\.day) == ["2026-11-01", "2026-11-02", "2026-11-03"] && near(wt[0].trend, 74) && near(wt[1].trend, 73.9)
      && near(wt[2].trend, 73.71), "weight trend: sorted, EWMA seeded with the first weigh-in")
check(near(NutritionMath.ewma([10, 20], alpha: 0.5).last, 15), "ewma alpha")

// MARK: Nutrient detail

var eggs1 = Entry(day: day, meal: .breakfast, foodID: "egg", name: "Eggs", nutrients: ["kcal": 180, "vit_d": 2, "sodium": 180])
eggs1.loggedAt = 1
var eggs2 = Entry(day: day, meal: .dinner, foodID: "egg", name: "Eggs", nutrients: ["kcal": 90, "vit_d": 1, "sodium": 90])
eggs2.loggedAt = 5
var salmon = Entry(day: day, meal: .lunch, foodID: "sal", name: "Salmon", nutrients: ["kcal": 280, "vit_d": 17, "sodium": 2400])
salmon.loggedAt = 3
var quick = Entry(day: day, meal: .snack, name: "Quick add", nutrients: ["kcal": 200, "protein": 10])
quick.loggedAt = 4
let detailDay = DaySummary(day: day, entries: [eggs1, eggs2, salmon, quick, water])
let vd = detailDay.status("vit_d", goals: tg)
check(near(vd.amount, 20) && vd.missing == 1 && vd.entryCount == 4 && vd.isPartial && vd.isMet && !vd.isOver, "partial data: ≥ amount with a missing count")
let na = detailDay.status("sodium", goals: tg)
check(na.isLimit && na.isOver && near(na.excess, 370) && !na.isMet, "a limit past its limit")
let zn = detailDay.status("zinc", goals: tg)
check(zn.amount == nil && zn.fraction == nil && !zn.isPartial, "unknown is not zero")
var wg = Goals(); wg.waterMl = 2000
check(near(detailDay.status("water", goals: wg).amount, 500) && near(detailDay.status("water", goals: wg).target, 2000), "water uses water entries and water_ml")
check(detailDay.foodEntries.map(\.name) == ["Eggs", "Salmon", "Eggs", "Quick add"], "food entries in meal order")
let src = TrendMath.topSources(detailDay.foodEntries, key: "vit_d")
check(src.map(\.name) == ["Salmon", "Eggs"] && src[1].entries == 2 && near(src[1].amount, 3) && near(src[0].share, 0.85), "top sources grouped by food")
check(TrendMath.topSources(detailDay.foodEntries, key: "zinc").isEmpty, "no sources for an unknown nutrient")
let best = TrendMath.bestSources([Food(id: "a", name: "Salmon", nutrients: ["kcal": 280, "vit_d": 17]),
                                  Food(id: "b", name: "Milk", nutrients: ["kcal": 122, "vit_d": 2.9]),
                                  Food(id: "c", name: "Tea", nutrients: ["kcal": 2, "vit_d": 1]),
                                  Food(id: "d", name: "Rice", nutrients: ["kcal": 205])], key: "vit_d")
check(best.map(\.food.name) == ["Salmon", "Milk"] && near(best[0].per100kcal, 17.0 / 2.8), "best sources per 100 kcal skip near-zero kcal foods")

// MARK: Display units

// Conversions use the exact factors.
check(UnitFactor.kgPerLb == 0.45359237 && UnitFactor.gPerOz == 28.349523125 && UnitFactor.mlPerFlOz == 29.5735295625, "exact factors")
check(near(BodyWeightUnit.lb.fromKg(116), 255.736224, 0.000001) && near(BodyWeightUnit.lb.toKg(1), 0.45359237, 1e-12), "kg ↔ lb")
check(near(FoodWeightUnit.oz.fromGrams(255), 8.99486, 0.000001) && near(FoodWeightUnit.oz.toGrams(8), 226.796185, 1e-9), "g ↔ oz")
check(near(VolumeUnit.flOz.toMl(8), 236.5882365, 1e-9) && near(VolumeUnit.flOz.fromMl(3000), 101.442, 0.001), "ml ↔ fl oz")
check(BodyWeightUnit.kg.fromKg(72.1) == 72.1 && FoodWeightUnit.g.toGrams(255) == 255 && VolumeUnit.ml.toMl(250) == 250, "metric is identity")
check(abs(FoodWeightUnit.oz.fromGrams(FoodWeightUnit.oz.toGrams(8)) - 8) < 1e-12, "oz round trip is exact")

// Formatting and rounding.
check(Fmt.foodWeight(255, .us) == "9 oz" && Fmt.foodWeight(245, .us) == "8.6 oz" && Fmt.foodWeight(255, .metric) == "255 g",
      "entry weights: \(Fmt.foodWeight(255, .us)), \(Fmt.foodWeight(245, .us))")
check(Fmt.foodWeight(340, .us) == "12 oz" && Fmt.foodWeight(283.5, .us) == "10 oz" && Fmt.foodWeight(14, .us) == "0.5 oz",
      "oz: whole from 10, 0.1 below: \(Fmt.foodWeight(283.5, .us)) \(Fmt.foodWeight(14, .us))")
check(Fmt.foodWeight(1, .us) == "0.04 oz" && Fmt.foodWeight(0, .us) == "0 oz" && Fmt.foodWeight(9.5, .metric) == "9.5 g",
      "a sliver of an ounce keeps two decimals: \(Fmt.foodWeight(1, .us))")
check(Fmt.bodyWeight(116, .us) == "255.7 lb" && Fmt.bodyWeight(72.1, .metric) == "72.1 kg" && Fmt.bodyWeightValue(116, .metric) == "116.0",
      "body weight to 0.1: \(Fmt.bodyWeight(116, .us))")
check(Fmt.bodyWeightShort(116, .us) == "256 lb" && Fmt.bodyWeightShort(116, .metric) == "116 kg" && Fmt.bodyWeightShort(115.8, .metric) == "115.8 kg",
      "basis weight: \(Fmt.bodyWeightShort(116, .us))")
check(Fmt.weightRate(-0.3, .metric) == "↓ 0.3 kg/wk" && Fmt.weightRate(-0.3, .us) == "↓ 0.7 lb/wk" && Fmt.weightRate(0.01, .us) == "→ 0.0 lb/wk"
      && Fmt.weightRate(nil, .us) == nil, "weekly rate: \(Fmt.weightRate(-0.3, .us) ?? "nil")")
check(Fmt.perBodyWeight(1.8, .us) == "0.8 g per lb" && Fmt.perBodyWeight(2.0, .us) == "0.9 g per lb" && Fmt.perBodyWeight(1.8, .metric) == "1.8 g per kg",
      "protein per body weight")
check(Fmt.volume(236.5882365, .us) == "8 fl oz" && Fmt.volume(250, .metric) == "250 ml" && Fmt.volume(500, .us) == "17 fl oz", "fl oz whole")
check(Fmt.waterProgress(1250, goal: 3000, .metric) == ("1.25", " / 3.0 L") && Fmt.waterProgress(1250, goal: 3000, .us) == ("42", " / 101 fl oz"),
      "water card: \(Fmt.waterProgress(1250, goal: 3000, .us))")
check(Fmt.waterGoal(3000, .us) == "101 fl oz" && Fmt.waterGoal(3000, .metric) == "3.0 L", "water goal")
check(Fmt.height(185, .us) == "6′1″" && Fmt.height(185, .metric) == "185 cm" && Fmt.height(182.6, .us) == "6′0″" && Fmt.height(152.4, .us) == "5′0″",
      "height: \(Fmt.height(185, .us)) \(Fmt.height(182.6, .us))")

// Labels that are only a measure follow the units; everything else stays.
check(Fmt.measureLabel("100 g", .us) == "3.5 oz" && Fmt.measureLabel("100 g", .metric) == "100 g" && Fmt.measureLabel("1 cup", .us) == "1 cup",
      "measure labels: \(Fmt.measureLabel("100 g", .us))")
check(Fmt.measureLabel("4 oz", grams: 113, .metric) == "113 g" && Fmt.measureLabel("4 oz", .us) == "4 oz" && Fmt.measureLabel("1 lb", .us) == "1 lb",
      "an imperial label in metric uses the known grams")
check(Fmt.measureLabel("240 ml", .us) == "8.1 fl oz" && Fmt.measureLabel("12 fl oz", .metric) == "355 ml" && Fmt.isWeightLabel("g") && !Fmt.isWeightLabel("240 ml"),
      "volume labels: \(Fmt.measureLabel("240 ml", .us))")

// Foods and entries in display units; the stored label stays metric.
check(yogurt.servingLabel == "container (170 g)" && yogurt.servingLabel(.us) == "container (6 oz)" && yogurt.servingLabel(.metric) == "container (170 g)",
      "display serving label: \(yogurt.servingLabel(.us))")
check(e1.detailLine(.us) == "1.5 container · 9 oz", "US detail line: \(e1.detailLine(.us))")
check(yogurt.servingSummary(.us) == "1 container · 6 oz" && yogurt.servingSummary(.metric) == "1 container · 170 g", "summary: \(yogurt.servingSummary(.us))")
check(yogurt.amountUnits(.us) == [.serving, .portion(0), .ounces, .grams], "US unit menu puts ounces first")
check(yogurt.unitLabel(.portion(0), .us) == "1 cup" && yogurt.defaultAmount(.us) == (.serving, 1), "a named serving starts at one serving")
let per100 = Food(id: "r", name: "Rice", serving: Serving(amount: 100, unit: "g", grams: 100), nutrients: ["kcal": 130])
check(per100.servingLabel(.us) == "3.5 oz" && per100.servingLabel(.metric) == "100 g" && per100.servingSummary(.us) == "3.5 oz", "a 100 g serving")
let start = per100.defaultAmount(.us)
check(start.unit == .ounces && near(start.amount, 100 / 28.349523125, 1e-9) && near(per100.servings(amount: start.amount, unit: start.unit), 1, 1e-12)
      && per100.defaultAmount(.metric) == (.serving, 1), "a bare-gram serving starts in ounces in US units, at exactly one serving")
let byGrams = Entry(day: "2026-11-08", meal: .lunch, name: "Rice", servings: 2.55, servingLabel: "100 g", grams: 255, nutrients: [:])
check(byGrams.detailLine(.metric) == "255 g" && byGrams.detailLine(.us) == "9 oz", "a bare-gram label reads as the total: \(byGrams.detailLine(.us))")
let waterEntry = Entry(day: "2026-11-08", meal: .lunch, name: "Water", servings: 236.588, servingLabel: "ml", nutrients: ["water": 236.588])
check(waterEntry.detailLine(.us) == "8 fl oz" && waterEntry.detailLine(.metric) == "237 ml", "water entries: \(waterEntry.detailLine(.us))")
let loose = Entry(day: "2026-11-08", meal: .lunch, name: "Salsa", servingLabel: "g", grams: nil, nutrients: [:])
check(loose.detailLine(.us) == "0.04 oz" && loose.detailLine(.metric) == "1 g", "grams without a weight: servings are grams")

// Round trips: 8 oz entered is 8 oz shown, through storage at three decimals.
var drift = 0
for tenths in stride(from: 1, through: 1000, by: 1) {
    let oz = Double(tenths) / 10
    let stored = NutritionMath.round3(FoodWeightUnit.oz.toGrams(oz))
    let shownBack = Fmt.foodInput(FoodWeightUnit.oz.fromGrams(stored), .oz)
    if shownBack != Fmt.foodInput(oz, .oz) { drift += 1 }
}
check(drift == 0, "0.1 to 100 oz survive grams at 3 decimals: \(drift) drifted")
let eightOz = yogurt.servings(amount: 8, unit: .ounces)
let logged8 = yogurt.entry(servings: eightOz, meal: .lunch, day: "2026-11-08")
check(Fmt.foodWeight(logged8.grams ?? 0, .us) == "8 oz" && near(yogurt.amount(servings: logged8.servings, in: .ounces), 8, 0.001),
      "8 oz logged reads 8 oz: \(Fmt.foodWeight(logged8.grams ?? 0, .us))")
var flDrift = 0
for floz in 1...200 {
    let ml = NutritionMath.round3(VolumeUnit.flOz.toMl(Double(floz)))
    if Fmt.volumeValue(ml, .us) != "\(floz)" { flDrift += 1 }
}
check(flDrift == 0, "1 to 200 fl oz survive ml at 3 decimals")

// Typed input: unchanged text keeps the exact metric value; edited text converts exactly.
let field = MetricInput(grams: 170, .oz)
check(field.initialText == "6" && field.metric(from: "6") == 170, "unchanged field keeps 170 g, not \(FoodWeightUnit.oz.toGrams(6))")
check(near(field.metric(from: "8"), 226.796185, 1e-9) && near(field.metric(from: "8,5"), 240.970946, 1e-6) && field.metric(from: "") == nil
      && field.metric(from: "x") == nil, "edited field converts")
check(MetricInput(grams: 245, .oz).initialText == "8.64" && MetricInput(grams: 170, .g).initialText == "170"
      && MetricInput(grams: nil, .oz).initialText == "" && MetricInput(grams: nil, .oz).metric(from: "") == nil, "initial text")
let waterField = MetricInput(ml: 3000, .flOz)
check(waterField.initialText == "101.44" && waterField.metric(from: "101.44") == 3000 && near(waterField.metric(from: "100"), 2957.35295625, 1e-6),
      "water goal field: \(waterField.initialText)")
check(Fmt.decimal(8.995, decimals: 1) == "9" && Fmt.decimal(8.64, decimals: 2) == "8.64" && Fmt.parse(" 8,5 ") == 8.5 && Fmt.parse("-1") == nil,
      "decimal and parse")

// Defaults per locale, storage and keys.
check(Units.defaults(for: .us) == .us && Units.defaults(for: .metric) == .metric, "US and metric locales")
check(Units.defaults(for: .uk) == Units(weight: .lb, food: .g, water: .ml, height: .ftIn), "UK: pounds and feet for people, grams and ml for food")
check(Units.defaults(for: Locale(identifier: "en_US").measurementSystem) == .us
      && Units.defaults(for: Locale(identifier: "de_DE").measurementSystem) == .metric
      && Units.defaults(for: Locale(identifier: "en_GB").measurementSystem).food == .g, "locales resolve")
check(Units.us.system == .us && Units.metric.system == .metric && Units(weight: .kg, food: .oz, water: .ml, height: .cm).system == nil
      && Units(.us) == .us, "system of a mix is nil")
let saved = Units(weight: .lb, food: .g, water: .flOz, height: .cm).stored
check(Units.load({ saved[$0] }, fallback: .metric) == Units(weight: .lb, food: .g, water: .flOz, height: .cm), "stored units load back")
check(Units.load({ _ in nil }, fallback: .us) == .us && Units.load({ $0 == Units.Key.food ? "stone" : nil }, fallback: .metric) == .metric,
      "missing or unknown values fall back to the locale")
let healthKeys: Set<String> = ["sent", "lastSync", "requested", "lastDailySync"]
check(Set(Units.Key.all).count == 4 && Units.Key.all.allSatisfy { !healthKeys.contains($0) && !$0.hasPrefix("anchor.") && $0.hasPrefix("units.") },
      "unit keys never collide with the health sync's keys")
let suite = "plate.units.test.\(UUID().uuidString)"
if let d = UserDefaults(suiteName: suite) {
    Units.us.save(to: d)
    check(Units.load({ d.string(forKey: $0) }, fallback: .metric) == .us, "save and load through UserDefaults")
    d.removePersistentDomain(forName: suite)
}

// MARK: Meal reminders (which notifications should exist)

let rDay = "2026-11-09"
func rAt(_ day: String, _ h: Int, _ m: Int) -> Date { ReminderPlan.fireDate(day: day, minutes: h * 60 + m) }
func rEntry(_ day: String, _ meal: Meal, _ name: String = "Bowl", kcal: Double = 500, protein: Double? = 30,
            source: String = "app") -> Entry {
    var n: NutrientMap = ["kcal": kcal]
    if let protein { n["protein"] = protein }
    var e = Entry(day: day, meal: meal, name: name, nutrients: n, source: source)
    e.loggedAt = Int(rAt(day, 12, 0).timeIntervalSince1970 * 1000)
    return e
}
func rPlan(_ entries: [Entry], at now: Date, _ settings: ReminderSettings = ReminderSettings(),
           goals: Goals? = nil) -> [PlannedReminder] {
    ReminderPlan.plan(settings, now: now, goals: goals, summary: { d in DaySummary(day: d, entries: entries) })
}
func rIDs(_ plan: [PlannedReminder]) -> [String] {
    plan.map { $0.id.replacingOccurrences(of: ReminderPlan.prefix, with: "") }
}

let rDefaults = ReminderSettings()
check(rDefaults.enabled && rDefaults.breakfast == .init(on: true, minutes: 630) && rDefaults.lunch == .init(on: true, minutes: 870)
      && rDefaults.dinner == .init(on: true, minutes: 1230) && rDefaults.summary == .init(on: false, minutes: 1290),
      "defaults: on, 10:30 / 14:30 / 20:30, summary 21:30 off")
check(rIDs(rPlan([], at: rAt(rDay, 9, 0))) == ["2026-11-09.breakfast", "2026-11-09.lunch", "2026-11-09.dinner",
                                               "2026-11-10.breakfast", "2026-11-10.lunch", "2026-11-10.dinner"],
      "nothing logged at 9:00: today's three and tomorrow's three, in time order")
let rLunchAt = rPlan([], at: rAt(rDay, 9, 0))[1].fireAt
check(Days.key(rLunchAt) == rDay && Days.calendar.dateComponents([.hour, .minute], from: rLunchAt) == DateComponents(hour: 14, minute: 30),
      "lunch fires at 14:30 in the server's zone")
check(rIDs(rPlan([rEntry(rDay, .lunch, source: "agent")], at: rAt(rDay, 12, 0))) == ["2026-11-09.dinner", "2026-11-10.breakfast",
                                                                                   "2026-11-10.lunch", "2026-11-10.dinner"],
      "at noon: breakfast's time has passed, lunch the agent already logged is skipped")
check(!rIDs(rPlan([], at: rAt(rDay, 14, 30))).contains("2026-11-09.lunch")
      && rIDs(rPlan([], at: rAt(rDay, 14, 29))).contains("2026-11-09.lunch"), "a reminder at exactly now is already due, not pending")
let rLogged = [rEntry(rDay, .breakfast), rEntry(rDay, .lunch), rEntry(rDay, .dinner)]
check(rIDs(rPlan(rLogged, at: rAt(rDay, 8, 0))) == ["2026-11-10.breakfast", "2026-11-10.lunch", "2026-11-10.dinner"],
      "every meal logged today: only tomorrow's")
var rWater = Entry(day: rDay, meal: .lunch, name: "Water", nutrients: ["water": 250])
rWater.loggedAt = 1
var rGone = rEntry(rDay, .lunch)
rGone.deleted = true
check(rIDs(rPlan([rWater, rGone, rEntry(rDay, .snack)], at: rAt(rDay, 12, 0))).contains("2026-11-09.lunch"),
      "water, a deleted entry and a snack don't count as lunch")
check(rIDs(rPlan([rEntry("2026-11-10", .breakfast)], at: rAt(rDay, 22, 0))) == ["2026-11-10.lunch", "2026-11-10.dinner"],
      "late evening: tomorrow's breakfast already logged (planned ahead) is skipped")
check(rIDs(rPlan([], at: rAt(rDay, 23, 59))).count == 3, "just before midnight: tomorrow's three")

var rOff = ReminderSettings()
rOff.enabled = false
check(rPlan([], at: rAt(rDay, 9, 0), rOff).isEmpty, "master switch off: nothing")
var rNoLunch = ReminderSettings()
rNoLunch.lunch.on = false
rNoLunch.dinner.minutes = 19 * 60
check(rIDs(rPlan([], at: rAt(rDay, 12, 0), rNoLunch)) == ["2026-11-09.dinner", "2026-11-10.breakfast", "2026-11-10.dinner"]
      && rPlan([], at: rAt(rDay, 12, 0), rNoLunch)[0].fireAt == rAt(rDay, 19, 0), "unchecked meals are skipped; edited times are used")

let rYesterday = rPlan([rEntry("2026-11-08", .lunch)], at: rAt(rDay, 9, 0))
check(rYesterday.filter(\.sameAsYesterday).map(\.id) == [ReminderPlan.prefix + "2026-11-09.lunch"],
      "Same as yesterday is offered only where the day before has that meal")
check(rPlan([rEntry(rDay, .dinner)], at: rAt(rDay, 9, 0)).first { $0.id.hasSuffix("2026-11-10.dinner") }?.sameAsYesterday == true,
      "tomorrow's dinner offers today's dinner")
let rCopy = rPlan([], at: rAt(rDay, 9, 0))
check(rCopy[1].title == "Lunch? 🍽" && rCopy[1].body == "Snap a photo or tap to log." && rCopy[0].title.hasPrefix("Breakfast?")
      && !rCopy.contains { $0.body.contains("!") || $0.title.contains("!") }, "short, warm copy, no exclamation marks")

var rSummaryOn = ReminderSettings()
rSummaryOn.summary.on = true
var rGoals = Goals()
rGoals.targets = ["kcal": 2190, "protein": 150]
rGoals.overrides = ["protein": 160]
let rDayLog = [rEntry(rDay, .breakfast, kcal: 600, protein: 40), rEntry(rDay, .lunch, kcal: 1250, protein: 52)]
let rWithSummary = rPlan(rDayLog, at: rAt(rDay, 15, 0), rSummaryOn, goals: rGoals)
check(rIDs(rWithSummary) == ["2026-11-09.dinner", "2026-11-09.summary", "2026-11-10.breakfast", "2026-11-10.lunch", "2026-11-10.dinner"],
      "summary at 21:30 for today only")
check(rWithSummary[1].title == "Today" && rWithSummary[1].body == "1,850 / 2,190 kcal · 92 / 160 g protein",
      "summary line: \(rWithSummary[1].body)")
check(ReminderPlan.summaryLine(DaySummary(day: rDay, entries: rDayLog), goals: nil) == "1,850 kcal · 92 g protein", "no goals: amounts only")
check(ReminderPlan.summaryLine(DaySummary(day: rDay, entries: rDayLog + [rEntry(rDay, .snack, kcal: 100, protein: nil)]), goals: rGoals)
      == "1,950 / 2,190 kcal · ≥ 92 / 160 g protein", "partial protein reads ≥, never as a shortfall")
check(!rIDs(rPlan([], at: rAt(rDay, 15, 0), rSummaryOn)).contains("2026-11-09.summary"), "no summary of an empty day")
check(!rIDs(rPlan(rDayLog, at: rAt(rDay, 21, 30), rSummaryOn)).contains { $0.hasSuffix("summary") }, "summary time passed")

check(ReminderPlan.parse(ReminderPlan.prefix + "2026-11-09.lunch")! == ("2026-11-09", .meal(.lunch))
      && ReminderPlan.parse(ReminderPlan.prefix + "2026-11-09.summary")! == ("2026-11-09", .summary)
      && ReminderPlan.parse("plate.reminder.test") == nil && ReminderPlan.parse("other.2026-11-09.lunch") == nil
      && ReminderPlan.parse(ReminderPlan.prefix + "2026-11-09.snack") == nil, "identifiers round trip")
let rDelivered = ["2026-11-08.dinner", "2026-11-08.summary", "2026-11-09.breakfast", "2026-11-09.lunch", "2026-11-09.summary"]
    .map { ReminderPlan.prefix + $0 } + ["someone.else"]
check(rIDs(ReminderPlan.plan(ReminderSettings(), now: .distantPast, goals: nil, summary: { DaySummary(day: $0, entries: []) })).isEmpty == false, "plan works from any date")
check(ReminderPlan.staleDelivered(rDelivered, now: rAt(rDay, 15, 0), summary: { DaySummary(day: $0, entries: [rEntry(rDay, .lunch)]) })
      .map { $0.replacingOccurrences(of: ReminderPlan.prefix, with: "") } == ["2026-11-08.dinner", "2026-11-08.summary", "2026-11-09.lunch"],
      "clear yesterday's and a logged meal's delivered reminders; keep an unlogged breakfast and today's summary")

let rSpring = ReminderPlan.fireDate(day: "2026-03-08", minutes: 10 * 60 + 30)
check(Days.calendar.dateComponents([.hour, .minute], from: rSpring) == DateComponents(hour: 10, minute: 30)
      && ReminderPlan.fireDate(day: "2026-03-09", minutes: 630).timeIntervalSince(rSpring) == 24 * 3600
      && ReminderPlan.fireDate(day: "2026-03-08", minutes: 630).timeIntervalSince(ReminderPlan.fireDate(day: "2026-03-07", minutes: 630)) == 23 * 3600,
      "wall-clock times across the DST change")
check(ReminderPlan.timeLabel(630) == "10:30 AM" && ReminderPlan.timeLabel(0) == "12:00 AM" && ReminderPlan.timeLabel(870) == "2:30 PM"
      && ReminderPlan.timeLabel(720) == "12:00 PM", "time labels")

var rStored: [String: Any] = [:]
var rCustom = ReminderSettings()
rCustom.enabled = false
rCustom.lunch = .init(on: false, minutes: 13 * 60)
rCustom.summary.on = true
for (k, v) in rCustom.stored { rStored[k] = v }
check(ReminderSettings.load { rStored[$0] } == rCustom && rStored.keys.allSatisfy { $0.hasPrefix("reminders.") }, "settings round trip under reminders.*")
check(ReminderSettings.load { _ in nil } == ReminderSettings()
      && ReminderSettings.load { $0 == "reminders.lunch.time" ? 5000 : nil }.lunch.minutes == 870, "missing or bad values keep defaults")

// MARK: Server time zone

let zoneDefaults = UserDefaults(suiteName: "plate-logic-tests-\(getpid())")!
let evening = Days.calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 21, minute: 0))!  // 9 PM Chicago
check(Days.key(evening) == "2026-11-08" && Days.meal(at: evening) == .snack, "fixture zone: Sunday evening")
check(Days.useServerZone("Asia/Tokyo", defaults: zoneDefaults) && Days.zone.identifier == "Asia/Tokyo"
      && zoneDefaults.string(forKey: Days.zoneKey) == "Asia/Tokyo", "the server's zone is applied and cached")
check(Days.key(evening) == "2026-11-09" && Days.meal(at: evening) == .lunch && Days.weekStart("2026-11-09") == "2026-11-09",
      "the same moment is Monday noon in Tokyo: the day key and meal match the server's")
check(!Days.useServerZone("Asia/Tokyo", defaults: zoneDefaults), "the same zone again changes nothing")
check(!Days.useServerZone("Mars/Olympus", defaults: zoneDefaults) && !Days.useServerZone(nil, defaults: zoneDefaults)
      && Days.zone.identifier == "Asia/Tokyo", "an unknown or missing zone keeps the current one")
check(Days.date("2026-11-09").timeIntervalSince(Days.calendar.startOfDay(for: Days.date("2026-11-09"))) == 12 * 3600, "noon in the new zone")
Days.forgetServerZone(defaults: zoneDefaults)
check(Days.zone.identifier == TimeZone.current.identifier && zoneDefaults.string(forKey: Days.zoneKey) == nil, "signed out: the phone's zone")
zoneDefaults.removePersistentDomain(forName: "plate-logic-tests-\(getpid())")
Days.setZone(TimeZone(identifier: "America/Chicago")!)

// MARK: Server setup

func normalized(_ s: String) -> String? { if case .success(let u) = ServerAddress.normalize(s) { return u } else { return nil } }
check(normalized("plate.example.com") == "https://plate.example.com", "https is added")
check(normalized("  https://box.tail1234.ts.net:8445/ ") == "https://box.tail1234.ts.net:8445", "spaces and a trailing slash go")
check(normalized("https://example.com/plate/v1/?x=1#y") == "https://example.com/plate", "a /v1 suffix, query and fragment go")
check(ServerAddress.normalize("http://plate.example.com") == .failure(.insecure), "plain http is refused")
check(ServerAddress.normalize("") == .failure(.empty) && ServerAddress.normalize("ftp://x") == .failure(.invalid)
      && ServerAddress.normalize("https://") == .failure(.invalid) && ServerAddress.normalize("not a host") == .failure(.invalid), "bad URLs")
check(ServerAddress.label("https://box.tail1234.ts.net:8445") == "box.tail1234.ts.net:8445"
      && ServerAddress.label("https://example.com/plate") == "example.com/plate", "labels")
let link = SetupLink.make(url: "https://box.tail1234.ts.net:8445", token: "abc+/=123")
check(link.hasPrefix("plate://setup?url=https%3A%2F%2Fbox.tail1234.ts.net%3A8445&token="), "setup link: \(link)")
check(SetupLink.parse(link) == SetupLink(url: "https://box.tail1234.ts.net:8445", token: "abc+/=123"), "setup link round trip")
check(SetupLink.parse("  plate://setup?url=plate.example.com/&token=t0k \n") == SetupLink(url: "https://plate.example.com", token: "t0k"),
      "pasted link with whitespace; the url is normalized")
check(SetupLink.parse("plate://setup?url=https://plate.example.com&token=t") == SetupLink(url: "https://plate.example.com", token: "t"),
      "an unencoded url still reads")
check(SetupLink.parse("plate://setup?url=http://plate.example.com&token=t") == nil && SetupLink.parse("plate://setup?url=https://x.com") == nil
      && SetupLink.parse("plate://other?url=https://x.com&token=t") == nil && SetupLink.parse("https://x.com/setup?url=https://x.com&token=t") == nil
      && SetupLink.parse("plate://setup?url=https://x.com&token=") == nil, "insecure, incomplete or foreign links are refused")

// MARK: Apple Health daily totals

check(HealthDaysPlan.startDay(lastSent: nil, today: "2026-11-08") == "2026-10-10", "first run: the last 30 days, today included")
check(HealthDaysPlan.startDay(lastSent: "2026-11-07", today: "2026-11-08") == "2026-11-05", "then from two days before the last day sent")
check(HealthDaysPlan.startDay(lastSent: "2026-01-01", today: "2026-11-08") == "2026-10-10", "never more than 30 days back")
check(HealthDaysPlan.startDay(lastSent: "2026-12-01", today: "2026-11-08") == "2026-11-06", "a last day in the future counts as today")
let hBody = HealthDaysPlan.body(days: [
    HealthDayTotals(day: "2026-11-08", weightKg: 80.456, activeKcal: 512.34, basalKcal: 1702.06, steps: 9012.6, exerciseMin: 31.04),
    HealthDayTotals(day: "2026-11-06"),
    HealthDayTotals(day: "2026-11-07", steps: 4000),
], profile: HealthProfileFacts(dob: "1990-04-01", sex: nil, heightCm: 180.34))
let hDays = hBody["days"] as! [[String: Any]]
check(hDays.map { $0["day"] as! String } == ["2026-11-07", "2026-11-08"], "empty days are left out, the rest in order")
check(hDays[1]["weight_kg"] as? Double == 80.46 && hDays[1]["active_kcal"] as? Double == 512.3 && hDays[1]["steps"] as? Double == 9013
      && hDays[1]["exercise_min"] as? Double == 31, "rounded values")
check(hDays[0]["weight_kg"] is NSNull && hDays[0]["steps"] as? Double == 4000, "unknown is null within a day")
let hProfile = hBody["profile"] as! [String: Any]
check(hProfile["dob"] as? String == "1990-04-01" && hProfile["height_cm"] as? Double == 180.3 && hProfile["sex"] == nil,
      "only known profile facts are sent (null would clear the server's)")
check(HealthDaysPlan.body(days: [], profile: HealthProfileFacts())["profile"] == nil, "no profile when nothing is known")
check((try? JSONSerialization.data(withJSONObject: hBody)) != nil, "the body is valid JSON")

// MARK: Demo fixture

let demo = DemoData.database(today: "2026-11-08")
let days = Set(demo.liveEntries.map(\.day))
check(days.count >= 70 && days.count <= 90 && days.contains("2026-11-08") && !days.contains("2026-10-30"), "90 days with gaps")
check(DaySummary(day: "2026-11-07", entries: Array(demo.entries.values)).entries(.dinner).isEmpty == false, "yesterday has a dinner")
check(demo.goals?.basis?.tdee != nil && demo.healthDays.count == 120 && demo.foods.values.contains { $0.kind == .recipe }, "goals, health days, recipes")

// MARK: AI logging: config, models, jobs and drafts from SPEC-shaped fixtures

func fixture(_ name: String) -> Data {
    (try? Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/\(name).json"))) ?? Data()
}
let agentConfig = try? JSONDecoder().decode(AgentConfig.self, from: fixture("agent-config"))
check(agentConfig?.model == "google/gemini-2.5-flash" && agentConfig?.hasKey == true && agentConfig?.isConfigured == true,
      "config: model and key")
check(agentConfig?.keyDots == "••1234" && agentConfig?.provider == .openRouter && agentConfig?.maxJobsPerDay == 60,
      "config: key hint shows as ••1234, OpenRouter preset")
check(agentConfig?.today.jobs == 3 && near(agentConfig?.today.cost, 0.0124) && agentConfig?.month.cost == nil
      && agentConfig?.month.tokens == 227_765, "config: usage today and month, unknown cost stays nil")
check(agentConfig?.usesDefaultPrompt == true && agentConfig?.effectivePrompt == "You log meals for one person in Plate.",
      "config: a null system_prompt uses the default")
check(AgentFormat.usage(agentConfig!.today) == "3 logs · $0.012" && AgentFormat.usage(agentConfig!.month) == "41 logs · 227.8k tokens",
      "usage lines: \(AgentFormat.usage(agentConfig!.today)) / \(AgentFormat.usage(agentConfig!.month))")
let emptyConfig = try? JSONDecoder().decode(AgentConfig.self, from: fixture("agent-config-empty"))
check(emptyConfig?.isConfigured == false && emptyConfig?.provider == .custom && emptyConfig?.keyHint == nil && emptyConfig?.autoLog == true,
      "config: no key, a custom provider")
check(emptyConfig?.usesDefaultPrompt == false && emptyConfig?.effectivePrompt == "Only log what is on the plate.", "config: custom instructions")
let sparseConfig = try? JSONDecoder().decode(AgentConfig.self, from: Data(#"{"has_key": true}"#.utf8))
check(sparseConfig?.baseURL == AgentProvider.openRouterURL && sparseConfig?.isConfigured == false, "config: a sparse reply defaults to OpenRouter, no model")
if let c = agentConfig, let data = try? JSONEncoder().encode(c), let back = try? JSONDecoder().decode(AgentConfig.self, from: data) {
    check(back == c, "config round-trips through the cache")
} else { check(false, "config encodes") }

func changeJSON(_ c: AgentConfigChange) -> [String: JSONValue] {
    (try? JSONDecoder().decode([String: JSONValue].self, from: c.body())) ?? [:]
}
check(changeJSON(AgentConfigChange(apiKey: "sk-or-abc")) == ["api_key": .string("sk-or-abc")], "PUT sends only the key")
check(changeJSON(AgentConfigChange(apiKey: "")) == ["api_key": .string("")], "an empty key clears it")
check(changeJSON(AgentConfigChange(model: "m", autoLog: true)) == ["model": .string("m"), "auto_log": .bool(true)], "model and auto-log")
check(changeJSON(AgentConfigChange(systemPrompt: .some(nil))) == ["system_prompt": .null]
      && changeJSON(AgentConfigChange(systemPrompt: .some(""))) == ["system_prompt": .null]
      && changeJSON(AgentConfigChange(systemPrompt: .some("Be brief"))) == ["system_prompt": .string("Be brief")]
      && changeJSON(AgentConfigChange()).isEmpty, "system_prompt: text sets, nil or empty resets, absent leaves it")
check(AgentProvider(baseURL: "https://openrouter.ai/api/v1/") == .openRouter && AgentProvider(baseURL: "https://api.openai.com/v1") == .custom,
      "provider from the base URL")

let modelList = try? JSONDecoder().decode(AgentModelList.self, from: fixture("agent-models"))
check(modelList?.models.map(\.id) == ["google/gemini-2.5-flash", "local/llava", "qwen2.5-vl:7b"], "models: objects and bare ids")
check(modelList?.models[0].priceLine == "$0.30 in · $2.50 out" && modelList?.models[1].priceLine == nil
      && modelList?.models[2].name == "qwen2.5-vl:7b", "model prices per 1M tokens: \(modelList?.models[0].priceLine ?? "nil")")
check(AgentFormat.price(15) == "$15" && AgentFormat.price(0.075) == "$0.075" && AgentFormat.price(0) == "free", "price formatting")

let running = try? JSONDecoder().decode(AgentJob.self, from: fixture("agent-job-running"))
check(running?.status == .running && running?.step == "Searching: rice white cooked" && running?.draft == nil, "job: running with a step")
let failedJob = try? JSONDecoder().decode(AgentJob.self, from: fixture("agent-job-failed"))
check(failedJob?.status == .failed && AgentFailure.classify(message: failedJob?.error).kind == .invalidKey, "job: failed, invalid key")
let draftJob = try? JSONDecoder().decode(AgentJob.self, from: fixture("agent-job-draft"))
let draft = draftJob?.draft
check(draftJob?.status == .draft && draft?.items.count == 3 && draft?.preview.count == 3 && draft?.isEditable == true,
      "job: a draft with items and preview entries")
check(draft?.preview[0].name == "Rice, white, cooked" && draft?.preview[0].meal == .dinner && draft?.preview[1].foodID != nil
      && near(draftJob?.usage?.cost, 0.0061), "draft: preview entries decode as Entry")
check(near(draft?.kcal, 988) && near(draft?.totals["protein"], 43.9) && draft?.totals["carbs"] == 51, "draft totals: unknown stays unknown")
check(draft?.summary.hasPrefix("Dinner:") == true, "draft summary")
let confirmed = try? JSONDecoder().decode(AgentConfirmed.self, from: fixture("agent-confirm"))
check(confirmed?.entries.first?.id == "e1" && confirmed?.version == 912 && confirmed?.entries.first?.version == 912, "confirm reply")
let loggedJob = try? JSONDecoder().decode(AgentJob.self, from: Data(#"{"status":"logged","logged":[{"entry":{"id":"x","day":"2026-11-09","meal":"lunch","name":"Soup","nutrients":{"kcal":200}}}]}"#.utf8))
check(loggedJob?.status == .logged && loggedJob?.entries.map(\.id) == ["x"], "an auto-logged job's entries, when the reply has them")
let builtJob = try? JSONDecoder().decode(AgentJob.self, from: Data(#"{"job":"j","status":"logged","meal":"dinner","date":"2026-11-09","created_at":1762740000000,"draft":null,"entries":[{"id":"z","day":"2026-11-09","meal":"dinner","name":"Rice","nutrients":{"kcal":200}}],"version":77}"#.utf8))
check(builtJob?.meal == .dinner && builtJob?.date == "2026-11-09" && builtJob?.createdAt == 1762740000000 && builtJob?.version == 77
      && builtJob?.entries.map(\.id) == ["z"] && builtJob?.draft == nil, "the server's job reply: defaults, entries and version once logged")
let confirmToday = try? JSONDecoder().decode(AgentConfirmed.self, from: Data(#"{"entries":[{"id":"a","day":"2026-11-09","meal":"lunch","name":"Soup"}],"version":5,"today":{"kcal":900}}"#.utf8))
check(confirmToday?.entries.count == 1 && confirmToday?.version == 5, "confirm with today")
check((try? JSONDecoder().decode(AgentJobCreated.self, from: Data(#"{"job":"abc"}"#.utf8)))?.job == "abc", "202 job id")

// Job body: base64 image, trimmed text, barcodes, meal and date.
let jobBody = (try? AgentJobInput(image: Data([1, 2, 3]), text: "  half the rice \n", barcodes: ["0049000028911"], meal: .lunch, day: "2026-11-09").body())
    .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
check(jobBody["image"] == .string("AQID") && jobBody["text"] == .string("half the rice") && jobBody["meal"] == .string("lunch")
      && jobBody["date"] == .string("2026-11-09") && jobBody["barcodes"] == .array([.string("0049000028911")]), "job body")
let textOnly = (try? AgentJobInput(text: "2 eggs", meal: .breakfast, day: "2026-11-09").body())
    .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
check(textOnly["image"] == nil && textOnly["barcodes"] == nil && AgentJobInput(text: "  ", meal: .snack, day: "d").isEmpty, "text-only body")

// Job body: a base64 made ahead of time (while the note was typed) is sent as is.
var preEncoded = AgentJobInput(image: Data([1, 2, 3]), text: nil, meal: .lunch, day: "2026-11-09")
preEncoded.imageBase64 = Data([1, 2, 3]).base64EncodedString()
check((try? preEncoded.body()).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }?["image"] == .string("AQID"),
      "a pre-encoded image goes into the body unchanged")

// MARK: AI logging: speed settings, elapsed_ms and cancelled jobs

let speedConfig = try? JSONDecoder().decode(AgentConfig.self, from: Data(#"{"has_key":true,"model":"m","reasoning_effort":"medium","verify_matches":true}"#.utf8))
check(speedConfig?.reasoningEffort == .medium && speedConfig?.effort == .medium && speedConfig?.verifyMatches == true
      && speedConfig?.hasSpeedSettings == true, "config: reasoning_effort and verify_matches")
check(agentConfig?.reasoningEffort == nil && agentConfig?.verifyMatches == nil && agentConfig?.effort == .low
      && agentConfig?.hasSpeedSettings == false, "config: an older server without the fields shows the default (Fast) and says so")
let oddEffort = try? JSONDecoder().decode(AgentConfig.self, from: Data(#"{"reasoning_effort":"minimal","verify_matches":0}"#.utf8))
check(oddEffort?.reasoningEffort == AgentEffort.none && oddEffort?.verifyMatches == false, "config: minimal is Fastest, 0 is false")
check((try? JSONDecoder().decode(AgentConfig.self, from: Data(#"{"reasoning_effort":"ultra"}"#.utf8)))?.effort == .low,
      "config: an unknown effort falls back to the default")
if let c = speedConfig, let data = try? JSONEncoder().encode(c), let back = try? JSONDecoder().decode(AgentConfig.self, from: data) {
    check(back == c && back.reasoningEffort == .medium, "speed settings round-trip through the cache")
} else { check(false, "speed config encodes") }
check(AgentEffort.allCases.map(\.title) == ["Fastest", "Fast", "Balanced", "Thorough"]
      && AgentEffort.allCases.map(\.rawValue) == ["none", "low", "medium", "high"] && AgentEffort.standard == .low, "speed titles map to reasoning_effort")
check(changeJSON(AgentConfigChange(reasoningEffort: AgentEffort.none)) == ["reasoning_effort": .string("none")]
      && changeJSON(AgentConfigChange(reasoningEffort: .high, verifyMatches: false)) == ["reasoning_effort": .string("high"), "verify_matches": .bool(false)]
      && changeJSON(AgentConfigChange(verifyMatches: true)) == ["verify_matches": .bool(true)], "PUT sends only the speed fields being changed")

let timedJob = try? JSONDecoder().decode(AgentJob.self, from: Data(#"{"status":"running","step":"Searching: rice","elapsed_ms":12345}"#.utf8))
check(timedJob?.elapsedMs == 12345 && timedJob?.status == .running, "job: elapsed_ms")
check(running?.elapsedMs == nil, "job: no elapsed_ms from an older server")
check((try? JSONDecoder().decode(AgentJob.self, from: Data(#"{"status":"running","elapsed_ms":-5}"#.utf8)))?.elapsedMs == nil, "job: a negative elapsed_ms is ignored")
let cancelledJob = try? JSONDecoder().decode(AgentJob.self, from: Data(#"{"status":"cancelled","elapsed_ms":4100,"draft":null}"#.utf8))
check(cancelledJob?.status == .cancelled && cancelledJob?.draft == nil && cancelledJob?.elapsedMs == 4100, "job: cancelled")
check(AgentJobStatus(wire: "canceled") == .cancelled && AgentJobStatus(wire: "error") == .failed && AgentJobStatus(wire: "queued") == .running
      && AgentJobStatus(wire: nil) == .running && AgentJobStatus(wire: "LOGGED") == .logged, "job status: lenient spellings")

// MARK: AI logging: the progress timer

let t0 = Date(timeIntervalSince1970: 1_000_000)
var clock = AgentClock(start: t0)
check(clock.seconds(at: t0) == 0 && clock.seconds(at: t0.addingTimeInterval(12.7)) == 12 && clock.label(at: t0.addingTimeInterval(12.7)) == "12 s",
      "the timer ticks locally: 12 s")
check(clock.seconds(at: t0.addingTimeInterval(-3)) == 0, "never negative")
check(AgentClock.label(59) == "59 s" && AgentClock.label(60) == "1 min" && AgentClock.label(65) == "1 min 5 s" && AgentClock.label(-1) == "0 s",
      "labels past a minute")
clock.correct(elapsedMs: 10_800, at: t0.addingTimeInterval(10))
check(clock.start == t0, "a small difference (upload, latency) isn't corrected")
clock.correct(elapsedMs: 20_000, at: t0.addingTimeInterval(10))
check(clock.seconds(at: t0.addingTimeInterval(10)) == 20 && clock.seconds(at: t0.addingTimeInterval(15)) == 25,
      "the server says it has run longer (the phone was asleep): the timer jumps ahead")
var behind = AgentClock(start: t0)
behind.correct(elapsedMs: 5_000, at: t0.addingTimeInterval(9))
check(behind.seconds(at: t0.addingTimeInterval(9)) == 9 && behind.seconds(at: t0.addingTimeInterval(11)) == 9
      && behind.seconds(at: t0.addingTimeInterval(14)) == 10 && behind.seconds(at: t0.addingTimeInterval(20)) == 16,
      "the server says less: the display holds, never runs backwards, then follows the server")
check(!clock.isSlow(at: t0) && AgentClock(start: t0).isSlow(at: t0.addingTimeInterval(30)) && !AgentClock(start: t0).isSlow(at: t0.addingTimeInterval(29.9)),
      "taking longer than usual from 30 s")
check(!AgentClock(start: t0).confirmsCancel(at: t0.addingTimeInterval(10)) && AgentClock(start: t0).confirmsCancel(at: t0.addingTimeInterval(10.5)),
      "Cancel asks first past 10 s")

// MARK: AI logging: hidden jobs (background continuation)

func arrive(_ state: AgentRunState, fg: Bool = true, modal: Bool = false, allowed: Bool = true) -> AgentArrival {
    AgentArrival.decide(state, meal: .lunch, summary: "Lunch: soup, about 400 kcal", foreground: fg, modalOpen: modal, notificationsAllowed: allowed)
}
check(arrive(.draft(kcal: 780)) == .reopen && arrive(.failed("Out of credit")) == .reopen,
      "in front with nothing modal: the draft (or the error) opens again")
check(arrive(.draft(kcal: 780), modal: true) == .notify(title: "Your lunch draft is ready", body: "Lunch: soup, about 400 kcal"),
      "a sheet is open: a notification instead")
check(arrive(.draft(kcal: 780), fg: false) == .notify(title: "Your lunch draft is ready", body: "Lunch: soup, about 400 kcal"),
      "in the background: a notification")
check(arrive(.logged(kcal: 780)) == .toast, "auto-logged in front: the undo toast")
check(arrive(.logged(kcal: 780), fg: false) == .notify(title: "Logged lunch · 780 kcal", body: "Lunch: soup, about 400 kcal Tap to undo."),
      "auto-logged in the background: Logged lunch · 780 kcal")
check(arrive(.failed("Out of credit"), fg: false) == .notify(title: "Couldn't draft your lunch", body: "Out of credit. Tap to try again."),
      "a failure in the background says so")
check(arrive(.draft(kcal: 1), fg: false, allowed: false) == .later && arrive(.draft(kcal: 1), modal: true, allowed: false) == .later
      && arrive(.logged(kcal: 1), modal: true, allowed: false) == .toast, "no notifications: the pill waits (an auto-log still toasts)")
check(arrive(.cancelled) == .drop && arrive(.cancelled, fg: false) == .drop && arrive(.done) == .drop && arrive(.running) == .later,
      "cancelled: nothing to show")
check(AgentArrival.notification(.draft(kcal: 1), meal: .snack, summary: "  ")?.body == "Tap to check it and log it."
      && AgentArrival.notification(.draft(kcal: 1), meal: .snack, summary: nil)?.title == "Your snack draft is ready", "notification fallbacks")

let ra = UUID(), rb = UUID(), rc = UUID()
check(AgentPill.make([]) == nil && AgentPill.make([(ra, .running, false)]) == nil, "no pill while the sheet is on screen")
check(AgentPill.make([(ra, .running, true)]) == AgentPill(kind: .working, runID: ra, count: 1)
      && AgentPill.make([(ra, .running, true)])?.title == "Working…", "a hidden job: Working…")
check(AgentPill.make([(ra, .running, true), (rb, .draft(kcal: 5), true)]) == AgentPill(kind: .ready, runID: rb, count: 2),
      "a finished draft beats one still working")
check(AgentPill.make([(ra, .failed("x"), true), (rb, .logged(kcal: 1), true), (rc, .cancelled, true)]) == AgentPill(kind: .failed, runID: ra, count: 1),
      "logged and cancelled jobs need nothing; a failure still shows")
check(AgentPill.make([(ra, .running, true), (rb, .running, true)])?.runID == rb, "the newest working job")
check(AgentRunState.running.isRunning && AgentRunState.draft(kcal: 1).isFinished && AgentRunState.cancelled.isFinished, "run states")

// MARK: AI logging: draft editing math (mirrors the server's rescale_entry)

if let d = draft {
    let grams = d.settingGrams(90, at: 0)
    check(near(grams?.preview[0].grams, 90) && near(grams?.preview[0].kcal, 117) && near(grams?.preview[0].servings, 0.569, 0.001),
          "grams scale the entry: \(String(describing: grams?.preview[0].servings))")
    check(grams?.items[0].object?["grams"] == .number(90) && grams?.items[0].object?["catalog"] == .string("rice white cooked"),
          "a catalog item keeps its query and gets the new grams")
    let servings = d.settingServings(3, at: 1)
    check(servings?.items[1].object?["servings"] == .number(3) && near(servings?.preview[1].kcal, 171) && near(servings?.preview[1].grams, 78),
          "servings scale a food item and its entry")
    let named = d.settingServings(1, at: 2)
    check(named?.items[2].object?["servings"] == .number(1) && named?.items[2].object?["grams"] == .number(170)
          && near(named?.preview[2].kcal, 320) && named?.items[2].object?["nutrients"] == d.items[2].object?["nutrients"],
          "a named item scales servings and its total grams; per-serving nutrients stay")
    check(near(d.settingGrams(90, at: 0)?.kcal, 871), "the total follows an edit")
    check(d.settingGrams(0, at: 0) == nil && d.settingServings(-1, at: 0) == nil && d.settingServings(1, at: 9) == nil,
          "bad amounts and indexes are refused")
    let removed = d.removing(1)
    check(removed.items.count == 2 && removed.preview.map(\.id) == ["p1", "p3"] && near(removed.kcal, 874), "remove an item")
    check(d.removing(0).removing(0).removing(0).isEmpty, "removing everything empties the draft")
    let moved = d.moving(to: .lunch)
    check(moved.preview.allSatisfy { $0.meal == .lunch } && moved.items.allSatisfy { $0.object?["meal"] == .string("lunch") }, "move to another meal")
    check(d.settingServings(1.137, at: 0) == d, "the same amount is no edit")
    var extra = d
    extra.items[0] = .object((d.items[0].object ?? [:]).merging(["matched": .string("x"), "id": .string("y")]) { a, _ in a })
    check(extra.confirmItems[0].object?.keys.sorted() == ["catalog", "grams", "meal"] && extra.confirmItems.count == 3,
          "confirm sends only documented item fields")
    let neither = AgentDraft.scale(item: .object(["food": .string("f")]), by: 2, entry: Entry(day: "d", meal: .lunch, name: "x", servings: 1.5, nutrients: [:]))
    check(neither.object?["servings"] == .number(3), "an item with no amount gets servings from its entry")
}
let demoDraft = DemoAgent.draft(text: nil, hasPhoto: true, meal: .dinner, day: "2026-11-08")
check(demoDraft.preview.map(\.name) == ["Atlantic salmon, baked", "Jasmine rice, cooked", "Avocado"] && demoDraft.isEditable
      && demoDraft.preview.allSatisfy { $0.source == "agent" && $0.day == "2026-11-08" }, "demo photo draft: \(demoDraft.summary)")
let demoText = DemoAgent.draft(text: "2 eggs and toast with avocado", hasPhoto: false, meal: .breakfast, day: "2026-11-08")
check(demoText.preview.map(\.name) == ["Egg, whole, scrambled", "Sourdough toast", "Avocado"] && demoText.preview[0].servings == 2,
      "demo text draft: \(demoText.preview.map(\.name))")

// MARK: AI logging: friendly errors

let errorCases: [(Int, String, AgentFailure.Kind)] = [
    (0, "API key is invalid", .invalidKey), (401, "", .invalidKey), (400, "no API key is set", .noKey),
    (402, "out of credit", .outOfCredit), (0, "Insufficient credits", .outOfCredit), (404, "unknown model foo/bar", .unknownModel),
    (0, "the job timed out after 3 minutes", .timeout), (429, "daily limit of 60 AI logs reached", .dailyLimit),
    (429, "slow down", .busy), (500, "the model didn't propose a meal", .server), (502, "upstream error", .server),
    // The server's own words (server/src/agent.rs and llm.rs).
    (400, "AI logging needs an API key first: add one in Settings (or `food agent config --key-stdin`)", .noKey),
    (400, "AI logging needs a model first: pick one in Settings (or `food agent config --model ID`)", .noModel),
    (502, "API key is invalid", .invalidKey), (502, "out of credit: add credit with your provider (or pick a cheaper model)", .outOfCredit),
    (502, "unknown model \"x/y\": check the model id (`food agent models`)", .unknownModel),
    (502, "\"x/y\" can't do this (no endpoints found); pick a model with image input and tool calling", .unknownModel),
    (0, "timed out waiting for the model", .timeout), (429, "2 AI jobs are already running; try again in a moment", .busy),
    (429, "the daily limit of 60 AI jobs is reached; it resets at midnight (raise it in Settings)", .dailyLimit),
    (502, "rate limited by the provider; try again in a minute (slow down)", .busy), (0, "the model declined: no", .server),
]
for (status, message, kind) in errorCases {
    check(AgentFailure.classify(status: status, message: message).kind == kind, "error \(status) ‘\(message)’ → \(kind)")
}
for kind in [AgentFailure.Kind.noKey, .noModel, .invalidKey, .outOfCredit, .unknownModel, .timeout, .dailyLimit, .busy, .server] {
    check(AgentFailure.classify(message: DemoAgent.errorMessage(kind)).kind == kind, "demo error text for \(kind) classifies back")
}
check(AgentFailure(.offline).canRetry && AgentFailure(.timeout).canRetry && !AgentFailure(.invalidKey).canRetry
      && AgentFailure(.unknownModel).needsSettings && !AgentFailure(.outOfCredit).needsSettings, "retry and settings hints")

// MARK: AI logging: photos (resize, upright, no EXIF or GPS)

check(AgentImage.fittedSize(width: 4032, height: 3024) == (1024, 768) && AgentImage.fittedSize(width: 3000, height: 4000) == (768, 1024),
      "long edge to 1024")
check(AgentImage.fittedSize(width: 800, height: 600) == (800, 600) && AgentImage.fittedSize(width: 5000, height: 10) == (1024, 2)
      && AgentImage.fittedSize(width: 0, height: 5) == (0, 0), "small images keep their size; never zero")

/// A 3000 × 2000 photo, left half red and right half blue, tagged orientation 6 (rotate 90° to show), with
/// EXIF, GPS and TIFF metadata like a phone camera writes.
func cameraJPEG() -> Data? {
    let w = 3000, h = 2000
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
    guard let image = ctx.makeImage() else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
    let props: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:09 12:30:00", kCGImagePropertyExifLensModel: "iPhone back camera"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

/// The RGB of the pixel at (x, y), y from the top.
func pixel(_ data: Data, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    guard let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let i = (y * img.width + x) * 4
    return (Int(base[i]), Int(base[i + 1]), Int(base[i + 2]))
}

if let original = cameraJPEG() {
    check(AgentImage.metadataKeys(original).isSuperset(of: ["{GPS}", "{Exif}", "{TIFF}"]), "the fixture photo carries GPS, EXIF and TIFF")
    let prepared = AgentImage.prepare(original)
    check(prepared != nil, "prepare reads a camera JPEG")
    if let prepared {
        let size = AgentImage.pixelSize(prepared)
        check(size?.width == 683 && size?.height == 1024, "upright portrait, 1024 long edge: \(String(describing: size))")
        let keys = AgentImage.metadataKeys(prepared)
        check(!keys.contains("{GPS}") && !keys.contains("{TIFF}") && !keys.contains("{ExifAux}"), "no GPS or TIFF metadata: \(keys.sorted())")
        let exif = (CGImageSourceCreateWithData(prepared as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any])?["{Exif}"] as? [String: Any]
        check(exif?[kCGImagePropertyExifDateTimeOriginal as String] == nil && exif?[kCGImagePropertyExifLensModel as String] == nil,
              "no camera EXIF survives: \(String(describing: exif))")
        let orientation = (CGImageSourceCreateWithData(prepared as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any])?[kCGImagePropertyOrientation as String] as? Int
        check(orientation == nil || orientation == 1, "no orientation tag left to apply")
        // Orientation 6 turns the left (red) half to the top.
        let top = pixel(prepared, x: 340, y: 100), bottom = pixel(prepared, x: 340, y: 920)
        check((top?.r ?? 0) > 200 && (top?.b ?? 255) < 60 && (bottom?.b ?? 0) > 200 && (bottom?.r ?? 255) < 60,
              "pixels are rotated upright: top \(String(describing: top)), bottom \(String(describing: bottom))")
        check(prepared.count < original.count && prepared.count < AgentImage.maxBytes, "smaller, and under the server's 1.5 MB")
        check(prepared.count <= AgentImage.targetBytes, "near the 150 to 250 KB target: \(prepared.count / 1024) KB")
        check(AgentImage.prepare(prepared).flatMap(AgentImage.pixelSize)?.height == 1024, "preparing twice keeps the size")
    }
} else { check(false, "make the fixture photo") }
check(AgentImage.prepare(Data("not an image".utf8)) == nil, "not an image")
// A busy photo (noise) over the target is encoded again lower, and still fits the server's limit.
var noise = [UInt8](repeating: 0, count: 1024 * 768 * 4)
var seed: UInt32 = 7
for i in noise.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; noise[i] = UInt8(truncatingIfNeeded: seed >> 24) }
if let provider = CGDataProvider(data: Data(noise) as CFData),
   let busy = CGImage(width: 1024, height: 768, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024 * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
   let first = AgentImage.encodeJPEG(busy, quality: AgentImage.quality), let small = AgentImage.prepare(image: busy) {
    check(first.count > AgentImage.targetBytes && small.count < first.count && small.count <= AgentImage.maxBytes,
          "a busy photo steps down from \(first.count / 1024) KB to \(small.count / 1024) KB")
} else { check(false, "make the busy photo") }
check(AgentImage.barcodeDigits(["0049000028911", " 5000112637922 ", "https://x.y", "12345", "0049000028911", "ABC123456", "123456789012345"])
      == ["0049000028911", "5000112637922"], "barcode digits: 6 to 14 digits, deduped")

print("\(checks - failures)/\(checks) checks passed")
if failures > 0 { exit(1) }
print("logic tests ok")
