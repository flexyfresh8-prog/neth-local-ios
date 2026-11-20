import Foundation

enum ToolArgument: Codable, Equatable, Sendable {
    case text(String), number(Double), flag(Bool)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .flag(let flag): try value.encode(flag)
        }
    }
}

struct ToolCall: Codable, Equatable, Sendable {
    let tool: String
    let arguments: [String: ToolArgument]

    static func parseCommand(_ input: String) throws -> ToolCall? {
        let parts = input.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard parts.first == "/tool" else { return nil }
        guard parts.count >= 2 else { throw LocalError(message: "Use /tool followed by a tool ID.") }
        let data = Data((parts.count == 3 ? String(parts[2]) : "{}").utf8)
        guard let arguments = try? JSONDecoder().decode([String: ToolArgument].self, from: data) else {
            throw LocalError(message: "Use a JSON object for tool arguments, with text, numbers or true/false values.")
        }
        return ToolCall(tool: String(parts[1]), arguments: arguments)
    }

    func text(_ key: String, default fallback: String? = nil) throws -> String {
        switch arguments[key] {
        case .text(let value): return value
        case .number(let value): return ToolCatalog.format(value)
        case .flag(let value): return value ? "true" : "false"
        case nil:
            if let fallback { return fallback }
            throw LocalError(message: "“\(key)” is required.")
        }
    }

    func number(_ key: String, default fallback: Double? = nil) throws -> Double {
        let number: Double?
        switch arguments[key] {
        case .number(let value): number = value
        case .text(let value): number = Double(value.trimmingCharacters(in: .whitespaces))
        default: number = fallback
        }
        guard let number, number.isFinite else { throw LocalError(message: "“\(key)” needs a finite number.") }
        return number
    }
}

struct ToolDefinition: Identifiable, Sendable {
    let id: String
    let title: String
    let category: String
    let summary: String
    let example: String
    let keywords: Set<String>
    let conversion: UnitConversion?
}

struct ConversionUnit: Sendable {
    let id: String
    let symbol: String
    let factor: Double
    let offset: Double
    let aliases: [String]

    init(_ id: String, _ symbol: String, _ factor: Double, _ aliases: String = "", offset: Double = 0) {
        self.id = id
        self.symbol = symbol
        self.factor = factor
        self.offset = offset
        self.aliases = aliases.split(separator: "|").map(String.init)
    }

    func matches(_ text: String) -> Bool {
        if symbol == text { return true }
        let normalized = text.lowercased().replacingOccurrences(of: "_", with: " ")
        let name = id.replacingOccurrences(of: "-", with: " ")
        return normalized == name || normalized == name + "s" || aliases.contains(normalized)
    }
}

struct UnitConversion: Sendable {
    let family: String
    let from: ConversionUnit
    let to: ConversionUnit
    var id: String { "convert.\(family).\(from.id).to.\(to.id)" }

    func apply(_ value: Double) throws -> Double {
        let base = value * from.factor + from.offset
        let converted = (base - to.offset) / to.factor
        guard value.isFinite, converted.isFinite else { throw LocalError(message: "That conversion is out of range.") }
        if family == "temperature", base < -0.000_001 {
            throw LocalError(message: "The temperature is below absolute zero.")
        }
        return converted
    }
}

struct ToolCatalog: Sendable {
    static let shared = ToolCatalog()
    let tools: [ToolDefinition]
    private let byID: [String: ToolDefinition]
    private let core: [ToolDefinition]

    private init() {
        let core = Self.operations.map { operation in
            ToolDefinition(id: operation.id, title: operation.title, category: operation.category,
                           summary: operation.summary, example: operation.example,
                           keywords: Set(Self.words(operation.keywords)), conversion: nil)
        }
        self.core = core
        let conversions = Self.units.flatMap { (family, units) in
            units.flatMap { from in
                units.filter { $0.id != from.id }.map { to in
                    let action = UnitConversion(family: family, from: from, to: to)
                    let words = [family, from.id, from.symbol, to.id, to.symbol] + from.aliases + to.aliases
                    return ToolDefinition(id: action.id, title: "\(from.symbol) → \(to.symbol)",
                                          category: family.capitalized,
                                          summary: "Convert \(from.id.replacingOccurrences(of: "-", with: " ")) to \(to.id.replacingOccurrences(of: "-", with: " ")).",
                                          example: #"{"value":1}"#,
                                          keywords: Set(words.flatMap(Self.words)), conversion: action)
                }
            }
        }
        tools = core + conversions
        byID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
    }

    subscript(_ id: String) -> ToolDefinition? { byID[id] }
    var actionCount: Int { core.count }
    var conversionCount: Int { tools.count - core.count }

    func find(_ query: String, category: String? = nil, limit: Int = 100) -> [ToolDefinition] {
        let words = Self.words(query)
        return Array(tools.lazy.filter { item in
            (category == nil || item.category == category)
                && words.allSatisfy { word in
                    item.id.contains(word) || item.keywords.contains { $0.hasPrefix(word) }
                }
        }.prefix(limit))
    }

    func shortlist(_ question: String, web: Bool, limit: Int = 6) -> [ToolDefinition] {
        let words = Set(Self.words(String(question.prefix(1200))))
        let intent = words.intersection(["convert", "calculate", "compute", "format", "extract", "validate", "sort",
                                         "count", "decode", "encode", "summarize", "search", "find", "compare",
                                         "remove", "dedupe", "round", "what", "how", "when", "make", "create"])
        let ranked = core.compactMap { item -> (ToolDefinition, Int)? in
            if item.id == "web.search" && !web { return nil }
            if item.category == "Files" { return nil }
            let score = words.intersection(item.keywords).count
            return score >= 2 || (score == 1 && !intent.isEmpty) ? (item, score) : nil
        }
        return ranked.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0.id < $1.0.id) }
            .prefix(limit).map(\.0)
    }

    func directConversion(_ input: String) -> ToolCall? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        guard let match = Self.measurement.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let value = Double(ns.substring(with: match.range(at: 1))) else { return nil }
        let from = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let to = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
        for (family, units) in Self.units {
            if let source = units.first(where: { $0.matches(from) }),
               let destination = units.first(where: { $0.matches(to) }), source.id != destination.id {
                return ToolCall(tool: UnitConversion(family: family, from: source, to: destination).id,
                                arguments: ["value": .number(value)])
            }
        }
        return nil
    }

    static func words(_ input: String) -> [String] {
        input.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func format(_ number: Double) -> String {
        String(format: "%.11g", locale: Locale(identifier: "en_US_POSIX"), number == 0 ? 0 : number)
    }

    private static let measurement = try! NSRegularExpression(
        pattern: #"(?i)([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)\s*([a-zµμ°²³/ _-]{1,35}?)\s+(?:into|to|in)\s+([a-zµμ°²³/ _-]{1,35}?)(?:\s+please)?\s*[?.!]*$"#)

    private static let operations: [(id: String, title: String, category: String, summary: String, example: String, keywords: String)] = [
        ("web.search", "Search the web", "Search", "Fetch public result titles, snippets and source links.", #"{"query":"iPad A16 specs"}"#, "web internet online sources recent news search"),
        ("history.search", "Search this conversation", "Search", "Find older messages in the active chat.", #"{"query":"speaker enclosure"}"#, "history earlier previous remember conversation messages"),
        ("catalog.search", "Find a tool", "Search", "Find tool IDs and argument examples.", #"{"query":"kilometer mile"}"#, "tools catalog capabilities"),
        ("file.write", "Create a text or code file", "Files", "Create a file from supplied text in this chat.", #"{"name":"hello.py","content":"print('Hello')"}"#, "file code create write save export"),
        ("file.pdf", "Create a PDF", "Files", "Typeset text into a paginated PDF.", #"{"name":"Notes.pdf","content":"My notes"}"#, "file pdf document create export"),
        ("file.read", "Read a chat file", "Files", "Preview a generated text file from this chat.", #"{"path":"README.md"}"#, "file read preview show"),
        ("file.list", "List chat files", "Files", "List the files created in this conversation.", #"{}"#, "file files list artifacts"),
        ("file.zip", "Archive chat files", "Files", "Package this conversation's files in a ZIP.", #"{"name":"project.zip"}"#, "file zip archive bundle compress"),
        ("text.count", "Count words and lines", "Text", "Count characters, words, lines and UTF-8 bytes.", #"{"text":"Some text"}"#, "count words lines characters length characters"),
        ("text.uppercase", "Uppercase text", "Text", "Convert text to uppercase.", #"{"text":"hello"}"#, "uppercase capitals capitalize upper"),
        ("text.lowercase", "Lowercase text", "Text", "Convert text to lowercase.", #"{"text":"HELLO"}"#, "lowercase lower"),
        ("text.trim", "Normalize whitespace", "Text", "Collapse runs of whitespace to one space.", #"{"text":" a   b "}"#, "trim remove normalize whitespace clean spaces"),
        ("text.sort_lines", "Sort lines", "Text", "Sort lines alphabetically.", #"{"text":"b\na"}"#, "sort order lines alphabetically"),
        ("text.unique_lines", "Deduplicate lines", "Text", "Remove duplicate lines and keep their first order.", #"{"text":"a\nb\na"}"#, "duplicates remove dedupe unique lines"),
        ("text.replace", "Replace text", "Text", "Replace every occurrence of an exact string.", #"{"text":"Hello, X","find":"X","replacement":"Sam"}"#, "replace substitute string occurrences"),
        ("text.slug", "Create a URL slug", "Text", "Normalize text for URLs and filenames.", #"{"text":"My project"}"#, "slug url title filename normalize"),
        ("text.extract_urls", "Extract URLs", "Text", "Find HTTP and HTTPS URLs in text.", #"{"text":"See https://example.org."}"#, "extract links urls http"),
        ("text.extract_emails", "Extract email addresses", "Text", "Find email addresses in text.", #"{"text":"Mail name@example.org"}"#, "extract emails email addresses"),
        ("text.extract_numbers", "Extract numbers", "Text", "Find signed decimal numbers in text.", #"{"text":"23 dB and -3.5 dB"}"#, "extract number numbers decimals"),
        ("data.json_format", "Format JSON", "Data", "Validate and pretty-print JSON.", #"{"text":"{\"a\":1}"}"#, "json format pretty validate"),
        ("data.json_keys", "List JSON keys", "Data", "List top-level object keys or array indices.", #"{"text":"{\"a\":1}"}"#, "json keys inspect data"),
        ("data.json_to_csv", "JSON to CSV", "Data", "Convert a JSON array of objects to CSV.", #"{"text":"[{\"name\":\"A\",\"score\":7}]"}"#, "json csv convert table spreadsheet"),
        ("data.csv_to_json", "CSV to JSON", "Data", "Convert header-based CSV to structured JSON.", #"{"text":"name,score\nA,7"}"#, "csv json convert table spreadsheet"),
        ("data.csv_count", "Count CSV rows", "Data", "Count records and report the header columns.", #"{"text":"x,y\n1,2"}"#, "csv table rows columns count"),
        ("data.statistics", "Summarize numbers", "Data", "Compute count, sum, mean, median, min and max.", #"{"text":"1, 2, 3.5"}"#, "average mean median stats statistics numbers sum min max"),
        ("math.calculate", "Calculate", "Math", "Add, subtract, multiply, divide, exponentiate or find a remainder.", #"{"a":4,"op":"*","b":5}"#, "calculate math arithmetic add subtract multiply divide product remainder"),
        ("math.percentage", "Find a percentage", "Math", "Calculate a percentage of an amount.", #"{"percent":15,"amount":200}"#, "percent percentage discount proportion"),
        ("math.percent_change", "Percentage change", "Math", "Calculate signed percentage change between two values.", #"{"before":100,"after":120}"#, "percent change increase decrease percentage"),
        ("math.ratio", "Simplify an integer ratio", "Math", "Reduce a ratio by the greatest common divisor.", #"{"a":1920,"b":1080}"#, "ratio aspect fraction simplify"),
        ("math.circle", "Circle dimensions", "Math", "Compute area and circumference from a radius.", #"{"radius":5}"#, "circle area circumference radius geometry"),
        ("math.hypotenuse", "Hypotenuse", "Math", "Compute the hypotenuse of a right triangle.", #"{"a":3,"b":4}"#, "triangle hypotenuse pythagorean"),
        ("math.compound_growth", "Compound growth", "Math", "Calculate growth with a fixed rate per period.", #"{"principal":100,"percent":5,"periods":4}"#, "compound growth interest appreciation"),
        ("audio.wavelength", "Sound wavelength", "Engineering", "Calculate wavelength from frequency and speed of sound.", #"{"hertz":50,"metersPerSecond":343}"#, "audio sound bass wavelength frequency"),
        ("audio.samples", "Audio sample count", "Engineering", "Calculate samples from duration and sampling rate.", #"{"seconds":10,"hertz":48000}"#, "audio samples sample rate duration"),
        ("electrical.ohm", "Ohm’s law", "Engineering", "Compute voltage and power from current and resistance.", #"{"amps":2,"ohms":4}"#, "ohm volts amps resistance voltage current watts"),
        ("electrical.parallel", "Parallel resistance", "Engineering", "Compute equivalent resistance of parallel resistors.", #"{"text":"4, 4, 8"}"#, "parallel series resistor impedance ohms"),
        ("encode.base64", "Encode Base64", "Encoding", "Encode UTF-8 text as Base64.", #"{"text":"Hello"}"#, "base64 encode encoding"),
        ("decode.base64", "Decode Base64", "Encoding", "Decode Base64 text as UTF-8.", #"{"text":"SGVsbG8="}"#, "base64 decode decoding"),
        ("encode.url", "Encode URL text", "Encoding", "Percent-encode a UTF-8 value.", #"{"text":"hello world"}"#, "url encode percent query"),
        ("decode.url", "Decode URL text", "Encoding", "Resolve percent escapes.", #"{"text":"hello%20world"}"#, "url decode percent"),
        ("hash.sha256", "SHA-256 text digest", "Encoding", "Compute the SHA-256 digest of UTF-8 text.", #"{"text":"Hello"}"#, "hash sha256 checksum digest"),
        ("time.now", "Time in a timezone", "Dates", "Show the current date and time in an IANA zone.", #"{"zone":"Asia/Riyadh"}"#, "time timezone clock date current now"),
        ("time.days_between", "Days between dates", "Dates", "Find the signed number of calendar days between ISO dates.", #"{"from":"2026-10-01","to":"2026-11-01"}"#, "date dates days between duration"),
        ("time.add_days", "Add days to a date", "Dates", "Add or subtract calendar days.", #"{"date":"2026-10-01","days":30}"#, "date add subtract days calendar"),
        ("time.weekday", "Day of week", "Dates", "Get the weekday for an ISO date.", #"{"date":"2026-11-20"}"#, "day weekday date calendar"),
    ]

    private static let units: [(String, [ConversionUnit])] = [
        ("length", [
            .init("nanometer", "nm", 1e-9), .init("micrometer", "µm", 1e-6, "um|micron|microns|micrometre"),
            .init("mil", "mil", 0.0000254), .init("millimeter", "mm", 0.001, "millimetre|millimetres"),
            .init("centimeter", "cm", 0.01, "centimetre|centimetres"), .init("meter", "m", 1, "metre|metres"),
            .init("kilometer", "km", 1000, "kilometre|kilometres"), .init("inch", "in", 0.0254, "inches"),
            .init("foot", "ft", 0.3048, "feet"), .init("yard", "yd", 0.9144),
            .init("mile", "mi", 1609.344), .init("nautical-mile", "nmi", 1852, "nautical miles"),
            .init("fathom", "fm", 1.8288)
        ]),
        ("area", [
            .init("square-millimeter", "mm²", 1e-6, "mm2"), .init("square-centimeter", "cm²", 0.0001, "cm2"),
            .init("square-meter", "m²", 1, "m2|sqm|square metres"), .init("are", "a", 100),
            .init("hectare", "ha", 10_000), .init("square-kilometer", "km²", 1_000_000, "km2"),
            .init("square-inch", "in²", 0.00064516, "in2|square inches"),
            .init("square-foot", "ft²", 0.09290304, "ft2|sqft|square feet"),
            .init("square-yard", "yd²", 0.83612736, "yd2"), .init("acre", "ac", 4046.8564224),
            .init("square-mile", "mi²", 2_589_988.110336, "mi2")
        ]),
        ("volume", [
            .init("microliter", "µL", 1e-6, "ul"), .init("milliliter", "mL", 0.001, "ml|cc|cm³|millilitres"),
            .init("liter", "L", 1, "l|litre|litres"), .init("cubic-meter", "m³", 1000, "m3"),
            .init("cubic-inch", "in³", 0.016387064, "in3|cubic inches"), .init("cubic-foot", "ft³", 28.316846592, "ft3|cubic feet"),
            .init("us-gallon", "US gal", 3.785411784, "gal|gallon|gallons"),
            .init("us-quart", "US qt", 0.946352946, "qt|quart|quarts"),
            .init("us-pint", "US pt", 0.473176473, "pt|pint|pints"),
            .init("us-cup", "US cup", 0.2365882365, "cup|cups"),
            .init("us-fluid-ounce", "US fl oz", 0.0295735295625, "fl oz|fluid ounce|fluid ounces"),
            .init("us-tablespoon", "US tbsp", 0.01478676478125, "tbsp|tablespoon|tablespoons"),
            .init("us-teaspoon", "US tsp", 0.00492892159375, "tsp|teaspoon|teaspoons"),
            .init("imperial-gallon", "imp gal", 4.54609, "uk gallon|imperial gallons"),
            .init("imperial-pint", "imp pt", 0.56826125, "uk pint"),
            .init("imperial-fluid-ounce", "imp fl oz", 0.0284130625, "uk fluid ounce")
        ]),
        ("mass", [
            .init("microgram", "µg", 1e-9, "ug"), .init("milligram", "mg", 1e-6), .init("gram", "g", 0.001),
            .init("kilogram", "kg", 1, "kilogramme"), .init("tonne", "t", 1000, "metric ton|metric tons"),
            .init("carat", "ct", 0.0002), .init("grain", "gr", 0.00006479891),
            .init("ounce", "oz", 0.028349523125), .init("troy-ounce", "ozt", 0.0311034768, "troy ounces"),
            .init("pound", "lb", 0.45359237, "lbs"), .init("stone", "st", 6.35029318),
            .init("short-ton", "US ton", 907.18474, "us tons"), .init("long-ton", "imp ton", 1016.0469088, "uk ton")
        ]),
        ("speed", [
            .init("millimeter-per-second", "mm/s", 0.001), .init("centimeter-per-second", "cm/s", 0.01),
            .init("meter-per-second", "m/s", 1, "mps|meters per second|metres per second"),
            .init("kilometer-per-hour", "km/h", 1.0/3.6, "kmph|kph|kilometers per hour"),
            .init("kilometer-per-second", "km/s", 1000), .init("inch-per-second", "in/s", 0.0254),
            .init("foot-per-second", "ft/s", 0.3048, "feet per second"), .init("foot-per-minute", "ft/min", 0.00508),
            .init("mile-per-hour", "mph", 0.44704, "miles per hour"),
            .init("knot", "kn", 1852.0/3600.0, "kt|kts")
        ]),
        ("duration", [
            .init("nanosecond", "ns", 1e-9), .init("microsecond", "µs", 1e-6, "us"),
            .init("millisecond", "ms", 0.001), .init("second", "s", 1, "sec|secs"),
            .init("minute", "min", 60, "mins"), .init("hour", "h", 3600, "hr|hrs"),
            .init("day", "d", 86400), .init("week", "wk", 604800), .init("fortnight", "fn", 1_209_600),
            .init("julian-year", "a", 31_557_600, "julian years")
        ]),
        ("storage", [
            .init("bit", "bit", 0.125, "b"), .init("byte", "B", 1), .init("kilobit", "kb", 125),
            .init("kilobyte", "kB", 1000, "KB"), .init("megabit", "Mb", 125_000),
            .init("megabyte", "MB", 1e6), .init("gigabit", "Gb", 125e6), .init("gigabyte", "GB", 1e9),
            .init("terabit", "Tb", 125e9), .init("terabyte", "TB", 1e12),
            .init("kibibit", "Kib", 128), .init("kibibyte", "KiB", 1024),
            .init("mebibit", "Mib", 131072), .init("mebibyte", "MiB", 1048576),
            .init("gibibit", "Gib", 134217728), .init("gibibyte", "GiB", 1073741824),
            .init("tebibit", "Tib", 137438953472), .init("tebibyte", "TiB", 1099511627776)
        ]),
        ("pressure", [
            .init("pascal", "Pa", 1), .init("hectopascal", "hPa", 100, "mbar|millibar|millibars"),
            .init("kilopascal", "kPa", 1000), .init("megapascal", "MPa", 1e6), .init("bar", "bar", 100_000),
            .init("atmosphere", "atm", 101325), .init("torr", "Torr", 101325.0/760.0),
            .init("millimeter-mercury", "mmHg", 133.322387415), .init("inch-mercury", "inHg", 3386.388640341),
            .init("pound-per-square-inch", "psi", 6894.757293168, "pounds per square inch"),
            .init("kilopound-per-square-inch", "ksi", 6894757.293168)
        ]),
        ("energy", [
            .init("electronvolt", "eV", 1.602176634e-19), .init("joule", "J", 1),
            .init("kilojoule", "kJ", 1000), .init("megajoule", "MJ", 1e6), .init("erg", "erg", 1e-7),
            .init("calorie-thermochemical", "cal", 4.184, "calorie|calories"),
            .init("kilocalorie-thermochemical", "kcal", 4184, "kilocalorie|kilocalories"),
            .init("watt-hour", "Wh", 3600, "watt hours"),
            .init("kilowatt-hour", "kWh", 3_600_000, "kilowatt hours"),
            .init("btu-it", "BTU", 1055.05585262, "btu"), .init("foot-pound-force", "ft·lbf", 1.3558179483314, "ft-lb")
        ]),
        ("power", [
            .init("nanowatt", "nW", 1e-9), .init("microwatt", "µW", 1e-6, "uw"), .init("milliwatt", "mW", 0.001),
            .init("watt", "W", 1), .init("kilowatt", "kW", 1000), .init("megawatt", "MW", 1e6),
            .init("gigawatt", "GW", 1e9), .init("mechanical-horsepower", "hp", 745.69987158227, "horsepower"),
            .init("metric-horsepower", "PS", 735.49875), .init("btu-per-hour", "BTU/h", 1055.05585262/3600.0)
        ]),
        ("temperature", [
            .init("kelvin", "K", 1, "k"),
            .init("celsius", "°C", 1, "c|degc|degrees celsius", offset: 273.15),
            .init("fahrenheit", "°F", 5.0/9.0, "f|degf|degrees fahrenheit", offset: 273.15 - 32.0 * 5.0/9.0),
            .init("rankine", "°R", 5.0/9.0, "r")
        ]),
        ("angle", [
            .init("radian", "rad", 1), .init("degree", "°", .pi/180), .init("arcminute", "arcmin", .pi/10800),
            .init("arcsecond", "arcsec", .pi/648000), .init("turn", "rev", 2 * .pi, "revolution|revolutions"),
            .init("gradian", "gon", .pi/200, "grad"), .init("milliradian", "mrad", 0.001),
            .init("microradian", "µrad", 1e-6, "urad")
        ]),
        ("frequency", [
            .init("millihertz", "mHz", 0.001), .init("hertz", "Hz", 1, "hz"), .init("kilohertz", "kHz", 1000, "khz"),
            .init("megahertz", "MHz", 1e6), .init("gigahertz", "GHz", 1e9), .init("terahertz", "THz", 1e12),
            .init("cycles-per-minute", "rpm", 1.0/60.0, "bpm|cycles per minute"),
            .init("cycles-per-hour", "cycles/h", 1.0/3600.0)
        ]),
        ("force", [
            .init("millinewton", "mN", 0.001), .init("newton", "N", 1), .init("kilonewton", "kN", 1000),
            .init("meganewton", "MN", 1e6), .init("dyne", "dyn", 1e-5), .init("gram-force", "gf", 0.00980665),
            .init("kilogram-force", "kgf", 9.80665), .init("pound-force", "lbf", 4.4482216152605),
            .init("ounce-force", "ozf", 0.27801385095378)
        ]),
        ("data-rate", [
            .init("bit-per-second", "bps", 1), .init("kilobit-per-second", "kbps", 1000),
            .init("megabit-per-second", "Mbps", 1e6), .init("gigabit-per-second", "Gbps", 1e9),
            .init("terabit-per-second", "Tbps", 1e12), .init("byte-per-second", "B/s", 8),
            .init("kilobyte-per-second", "kB/s", 8000), .init("megabyte-per-second", "MB/s", 8e6),
            .init("gigabyte-per-second", "GB/s", 8e9), .init("kibibyte-per-second", "KiB/s", 8192),
            .init("mebibyte-per-second", "MiB/s", 8388608), .init("gibibyte-per-second", "GiB/s", 8589934592)
        ]),
    ]
}
