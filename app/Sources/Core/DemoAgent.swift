// `-PlateDemo YES` fixtures for AI logging: a configured OpenRouter setup with usage, a model list, the
// built-in instructions, the step texts a job shows, and a realistic draft made from the demo foods
// (a photo becomes salmon, rice and avocado; text is matched word by word).
import Foundation

enum DemoAgent {
    static func config(configured: Bool = true) -> AgentConfig {
        var c = AgentConfig()
        c.baseURL = AgentProvider.openRouterURL
        c.model = configured ? "google/gemini-2.5-flash" : ""
        c.hasKey = configured
        c.keyHint = configured ? "…4f2a" : nil
        c.today = AgentUsage(jobs: 3, promptTokens: 14_210, completionTokens: 1_884, cost: 0.0124)
        c.month = AgentUsage(jobs: 41, promptTokens: 201_455, completionTokens: 26_310, cost: 0.1873)
        c.defaultSystemPrompt = defaultPrompt
        return c
    }

    static let models: [AgentModel] = [
        AgentModel(id: "anthropic/claude-sonnet-4.5", name: "Anthropic: Claude Sonnet 4.5", contextLength: 1_000_000, promptPrice: 3, completionPrice: 15),
        AgentModel(id: "anthropic/claude-haiku-4.5", name: "Anthropic: Claude Haiku 4.5", contextLength: 200_000, promptPrice: 1, completionPrice: 5),
        AgentModel(id: "google/gemini-2.5-flash", name: "Google: Gemini 2.5 Flash", contextLength: 1_048_576, promptPrice: 0.3, completionPrice: 2.5),
        AgentModel(id: "google/gemini-2.5-pro", name: "Google: Gemini 2.5 Pro", contextLength: 1_048_576, promptPrice: 1.25, completionPrice: 10),
        AgentModel(id: "meta-llama/llama-4-maverick", name: "Meta: Llama 4 Maverick", contextLength: 1_048_576, promptPrice: 0.15, completionPrice: 0.6),
        AgentModel(id: "mistralai/mistral-medium-3.1", name: "Mistral: Mistral Medium 3.1", contextLength: 131_072, promptPrice: 0.4, completionPrice: 2),
        AgentModel(id: "openai/gpt-4.1-mini", name: "OpenAI: GPT-4.1 Mini", contextLength: 1_047_576, promptPrice: 0.4, completionPrice: 1.6),
        AgentModel(id: "openai/gpt-5-mini", name: "OpenAI: GPT-5 Mini", contextLength: 400_000, promptPrice: 0.25, completionPrice: 2),
        AgentModel(id: "qwen/qwen2.5-vl-72b-instruct", name: "Qwen: Qwen2.5 VL 72B Instruct", contextLength: 32_000, promptPrice: 0.25, completionPrice: 0.75),
        AgentModel(id: "x-ai/grok-4-fast", name: "xAI: Grok 4 Fast", contextLength: 2_000_000, promptPrice: 0.2, completionPrice: 0.5),
    ]

    static let defaultPrompt = """
    You log meals for one person in Plate, a self-hosted food tracker. You get a photo of a meal, a few words, \
    or both, and you propose the entries to log. The person confirms your draft before anything is written, \
    unless they turned on automatic logging.

    Work like the food command's own logging workflow. Name each thing on the plate, estimate its weight in \
    grams from the plate, the cutlery and the packaging, and search for it before you guess. Prefer the \
    person's own foods (they log these often), then the USDA catalog, then Open Food Facts. When a barcode \
    is given, look it up first: a product's label beats any estimate.

    Use catalog items with grams for whole foods ("rice white cooked", 180 g), the person's foods by id \
    with servings for things they've logged before, and a named item with kcal and macros only when \
    nothing matches, such as a restaurant dish. Never invent micronutrients.

    Call propose_meal with the full list, read back the matched names and sizes, and propose again if a \
    match is wrong. Finish with one short line: the meal, about how many kcal, and the protein.
    """

    /// What the server says when a job fails, as the demo's `-PlateAgentError <kind>` reports it.
    static func errorMessage(_ kind: AgentFailure.Kind) -> String {
        switch kind {
        case .noKey: "AI logging needs an API key first: add one in Settings (or `food agent config --key-stdin`)"
        case .noModel: "AI logging needs a model first: pick one in Settings (or `food agent config --model ID`)"
        case .invalidKey: "API key is invalid"
        case .outOfCredit: "out of credit: add credit with your provider (or pick a cheaper model)"
        case .unknownModel: "unknown model \"google/gemini-9-ultra\": check the model id (`food agent models`)"
        case .timeout: "timed out waiting for the model"
        case .offline: "connection refused"
        case .dailyLimit: "the daily limit of 60 AI jobs is reached; it resets at midnight (raise it in Settings)"
        case .busy: "rate limited by the provider; try again in a minute (slow down)"
        case .server: "the model didn't propose a meal"
        }
    }

    /// What a running job says, in order (about 2 s in all).
    static let steps = ["Looking at your plate", "Searching: salmon baked", "Searching: rice jasmine cooked",
                        "Checking portions", "Putting your meal together"]
    static let textSteps = ["Reading your note", "Searching your foods", "Checking portions", "Putting your meal together"]

    /// A draft from the demo foods: a photo is a salmon plate; text is matched by name.
    static func draft(text: String?, hasPhoto: Bool, meal: Meal, day: String) -> AgentDraft {
        var picks: [(Food, Double)] = []
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty { picks = match(text) }
        if picks.isEmpty {
            let byID = Dictionary(DemoData.foods.compactMap { f in f.id.map { ($0, f) } }, uniquingKeysWith: { a, _ in a })
            picks = [("demo-salmon", 1.0), ("demo-rice", 1.0), ("demo-avocado", 1.0)].compactMap { id, s in byID[id].map { ($0, s) } }
        }
        let note = hasPhoto ? "from photo" : "from text"
        var preview: [Entry] = []
        var items: [JSONValue] = []
        for (food, servings) in picks {
            var e = food.entry(servings: servings, meal: meal, day: day, source: "agent", note: note)
            e.loggedAt = nowMs()
            preview.append(e)
            items.append(.object(["food": .string(food.id ?? ""), "servings": .number(servings), "meal": .string(meal.rawValue),
                                  "date": .string(day), "note": .string(note)]))
        }
        let kcal = NutritionMath.sum(preview.map(\.nutrients))["kcal"] ?? 0
        let protein = NutritionMath.sum(preview.map(\.nutrients))["protein"] ?? 0
        let list: String
        if picks.map({ $0.0.id }) == ["demo-salmon", "demo-rice", "demo-avocado"] {
            list = "a baked salmon fillet, a cup of jasmine rice and half an avocado"
        } else {
            let names = preview.map { $0.name.components(separatedBy: ",")[0].lowercased() }
            list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? "your meal"
        }
        let summary = "\(meal.title): \(list), about \(Fmt.kcal(kcal)) kcal and \(Fmt.grams(protein)) g protein."
        return AgentDraft(items: items, preview: preview, summary: summary.capitalizedFirstLetter)
    }

    /// "2 eggs and toast with avocado" → eggs × 2, toast × 1, avocado × 1 (demo foods only).
    static func match(_ text: String) -> [(Food, Double)] {
        let parts = text.lowercased()
            .replacingOccurrences(of: " with ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: "&", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let numbers = ["a": 1.0, "an": 1, "one": 1, "two": 2, "three": 3, "half": 0.5]
        var out: [(Food, Double)] = []
        for part in parts {
            var words = part.split(separator: " ").map(String.init)
            var servings = 1.0
            if let first = words.first, let n = Double(first) ?? numbers[first] { servings = n; words.removeFirst() }
            let stems = words.map { $0.hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : $0 }.filter { $0.count > 2 }
            let best = DemoData.allFoods.filter { $0.kind != .recipe }.max { a, b in score(a, stems) < score(b, stems) }
            if let best, score(best, stems) > 0, !out.contains(where: { $0.0.id == best.id }) { out.append((best, servings)) }
        }
        return out
    }

    private static func score(_ food: Food, _ stems: [String]) -> Int {
        let hay = food.name.lowercased()
        return stems.filter { hay.contains($0) }.count
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
