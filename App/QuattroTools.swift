import CryptoKit
import Foundation

struct ToolOutput: Sendable {
    let text: String
    var file: WorkspaceFile? = nil
    var evidence: WebEvidence? = nil
}

struct ToolContext: Sendable {
    let conversation: String
    let before: Int64
    let web: Bool
    let files: [WorkspaceFile]
}

struct QuattroTools: Sendable {
    let archive: ChatArchive
    let workspace: ChatWorkspace
    let searcher: WebSearch
    let catalog = ToolCatalog.shared

    func execute(_ call: ToolCall, in context: ToolContext) async throws -> ToolOutput {
        try Task.checkCancellation()
        guard let definition = catalog[call.tool] else { throw LocalError(message: "Unknown tool ID: \(call.tool)") }
        if let conversion = definition.conversion {
            let value = try call.number("value")
            let measured = try conversion.apply(value)
            return ToolOutput(text: "\(ToolCatalog.format(value)) \(conversion.from.symbol) = \(ToolCatalog.format(measured)) \(conversion.to.symbol)")
        }
        switch call.tool {
        case "web.search":
            guard context.web else { throw LocalError(message: "Enable Web in the composer to send a search query.") }
            let evidence = try await searcher.find(call.text("query"))
            return ToolOutput(text: "Found \(evidence.sources.count) sources on \(evidence.provider).", evidence: evidence)
        case "history.search":
            let results = try await archive.recall(call.text("query"), in: context.conversation, before: context.before)
            let notes = results.map { "\($0.role.rawValue) · \($0.excerpt)" }
            return ToolOutput(text: notes.isEmpty ? "No matching earlier messages." : notes.joined(separator: "\n"))
        case "catalog.search":
            let results = catalog.find(try call.text("query"), limit: 9)
            let lines = results.map { "\($0.id)  \($0.example)" }
            return ToolOutput(text: lines.isEmpty ? "No matching tools." : lines.joined(separator: "\n"))
        case "file.write", "file.pdf":
            let name = try call.text("name")
            if call.tool == "file.pdf" && !name.lowercased().hasSuffix(".pdf") {
                throw LocalError(message: "Use a .pdf filename.")
            }
            let file = try await workspace.save(call.text("content"), name: name, conversation: context.conversation)
            return ToolOutput(text: "Created \(file.name).", file: file)
        case "file.read":
            let path = try call.text("path")
            let candidate = context.files.last(where: { $0.name == path || $0.id == path })?.id
            if let candidate {
                return ToolOutput(text: try await workspace.read(candidate, conversation: context.conversation))
            }
            let paths = try await workspace.list(conversation: context.conversation)
            guard let found = paths.last(where: { $0 == path || $0.hasSuffix("/" + path) }) else {
                throw LocalError(message: "No file named \(path) in this conversation.")
            }
            return ToolOutput(text: try await workspace.read(found, conversation: context.conversation))
        case "file.list":
            let paths = try await workspace.list(conversation: context.conversation)
            return ToolOutput(text: paths.isEmpty ? "This conversation has no files." : paths.joined(separator: "\n"))
        case "file.zip":
            var used: Set<String> = []
            let files = context.files.reversed().filter {
                !$0.name.hasSuffix(".zip") && used.insert($0.name).inserted
            }.reversed()
            let file = try await workspace.archive(Array(files), name: call.text("name", default: "project.zip"),
                                                   conversation: context.conversation)
            return ToolOutput(text: "Created \(file.name).", file: file)
        case "text.count":
            let text = try call.text("text")
            let words = text.split(whereSeparator: \.isWhitespace).count
            let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
            return ToolOutput(text: "\(words) words · \(lines) lines · \(text.count) characters · \(text.utf8.count) bytes")
        case "text.uppercase": return ToolOutput(text: try call.text("text").uppercased())
        case "text.lowercase": return ToolOutput(text: try call.text("text").lowercased())
        case "text.trim": return ToolOutput(text: try call.text("text").split(whereSeparator: \.isWhitespace).joined(separator: " "))
        case "text.sort_lines":
            return ToolOutput(text: try call.text("text").components(separatedBy: .newlines)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n"))
        case "text.unique_lines":
            var seen: Set<String> = []
            return ToolOutput(text: try call.text("text").components(separatedBy: .newlines)
                .filter { seen.insert($0).inserted }.joined(separator: "\n"))
        case "text.replace":
            let find = try call.text("find")
            guard !find.isEmpty else { throw LocalError(message: "Enter text to find.") }
            return ToolOutput(text: try call.text("text").replacingOccurrences(of: find, with: call.text("replacement")))
        case "text.slug":
            let text = try call.text("text")
            let normalized = text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return ToolOutput(text: ToolCatalog.words(normalized).joined(separator: "-"))
        case "text.extract_urls":
            return ToolOutput(text: Self.extract(try call.text("text"), pattern: #"https?://[^\s<>"']+"#)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)]")) }.joined(separator: "\n"))
        case "text.extract_emails":
            return ToolOutput(text: Self.extract(try call.text("text"), pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#)
                .joined(separator: "\n"))
        case "text.extract_numbers":
            return ToolOutput(text: Self.extract(try call.text("text"), pattern: Self.numberPattern).joined(separator: "\n"))
        case "data.json_format":
            return ToolOutput(text: try Self.stringify(Self.json(call.text("text"))))
        case "data.json_keys":
            let value = try Self.json(call.text("text"))
            if let object = value as? [String: Any] { return ToolOutput(text: object.keys.sorted().joined(separator: "\n")) }
            if let array = value as? [Any] { return ToolOutput(text: array.indices.map(String.init).joined(separator: ", ")) }
            throw LocalError(message: "Provide a JSON object or array.")
        case "data.json_to_csv":
            guard let objects = try Self.json(call.text("text")) as? [[String: Any]], !objects.isEmpty else {
                throw LocalError(message: "Provide a nonempty JSON array of objects.")
            }
            let columns = Set(objects.flatMap(\.keys)).sorted()
            guard !columns.isEmpty else { throw LocalError(message: "The objects contain no columns.") }
            let rows = try objects.map { item in
                try columns.map { key in
                    guard let value = item[key], !(value is NSNull) else { return "" }
                    if let text = value as? String { return text }
                    return try Self.stringify(value, pretty: false)
                }
            }
            return ToolOutput(text: CSV.write([columns] + rows))
        case "data.csv_to_json":
            let rows = try CSV.parse(call.text("text"))
            guard let columns = rows.first, Set(columns).count == columns.count,
                  columns.allSatisfy({ !$0.isEmpty }) else { throw LocalError(message: "CSV needs unique, nonempty headers.") }
            let objects = try rows.dropFirst().map { row in
                guard row.count == columns.count else { throw LocalError(message: "A CSV row has the wrong number of columns.") }
                return Dictionary(uniqueKeysWithValues: zip(columns, row))
            }
            return ToolOutput(text: try Self.stringify(objects))
        case "data.csv_count":
            let rows = try CSV.parse(call.text("text"))
            guard let headers = rows.first else { throw LocalError(message: "Provide some CSV data.") }
            return ToolOutput(text: "\(rows.count - 1) data rows · \(headers.count) columns\n" + headers.joined(separator: ", "))
        case "data.statistics":
            let numbers = try Self.numbers(call.text("text")).sorted()
            let middle = numbers.count / 2
            let median = numbers.count.isMultiple(of: 2) ? numbers[middle - 1] / 2 + numbers[middle] / 2 : numbers[middle]
            let sum = numbers.reduce(0, +)
            guard sum.isFinite else { throw LocalError(message: "The total is out of range.") }
            let lines = [("Sum", sum), ("Mean", sum / Double(numbers.count)), ("Median", median),
                         ("Min", numbers[0]), ("Max", numbers[numbers.count - 1])]
            return ToolOutput(text: "Count \(numbers.count)\n" + lines.map { "\($0.0) \(ToolCatalog.format($0.1))" }.joined(separator: "\n"))
        case "math.calculate":
            let a = try call.number("a")
            let b = try call.number("b")
            let op = try call.text("op").trimmingCharacters(in: .whitespaces)
            let answer: Double
            switch op {
            case "+": answer = a + b
            case "-", "−": answer = a - b
            case "*", "×": answer = a * b
            case "/", "÷": answer = a / b
            case "^", "**": answer = pow(a, b)
            case "%": answer = b == 0 ? .nan : a.truncatingRemainder(dividingBy: b)
            default: throw LocalError(message: "Use +, −, ×, ÷, ^ or %.")
            }
            return try Self.measurement(answer)
        case "math.percentage":
            return try Self.measurement(call.number("percent") / 100 * call.number("amount"))
        case "math.percent_change":
            let before = try call.number("before")
            return try Self.measurement((call.number("after") - before) / before * 100, unit: "%")
        case "math.ratio":
            let a = try Self.integer(call.number("a"))
            let b = try Self.integer(call.number("b"))
            guard b != 0 else { throw LocalError(message: "The second value must be nonzero.") }
            var x = abs(a), y = abs(b)
            while y != 0 { (x, y) = (y, x % y) }
            let sign = b < 0 ? -1 : 1
            return ToolOutput(text: "\(sign * a / x):\(sign * b / x)")
        case "math.circle":
            let radius = try call.number("radius")
            guard radius >= 0 else { throw LocalError(message: "The radius must be positive or zero.") }
            return try Self.measurements([("Area", .pi * radius * radius), ("Circumference", 2 * .pi * radius)])
        case "math.hypotenuse": return try Self.measurement(hypot(call.number("a"), call.number("b")))
        case "math.compound_growth":
            let periods = try call.number("periods")
            let multiplier = try 1 + call.number("percent") / 100
            guard periods >= 0, multiplier >= 0 else { throw LocalError(message: "Use nonnegative periods and a rate of −100% or higher.") }
            return try Self.measurement(call.number("principal") * pow(multiplier, periods))
        case "audio.wavelength":
            let rate = try call.number("hertz")
            let speed = try call.number("metersPerSecond", default: 343)
            guard rate > 0, speed > 0 else { throw LocalError(message: "Use a positive frequency and sound speed.") }
            return try Self.measurement(speed / rate, unit: " m")
        case "audio.samples":
            let seconds = try call.number("seconds")
            let hertz = try call.number("hertz")
            guard seconds >= 0, hertz > 0 else { throw LocalError(message: "Use a valid duration and sample rate.") }
            return try Self.measurement((seconds * hertz).rounded(), unit: " samples")
        case "electrical.ohm":
            let amps = try call.number("amps")
            let ohms = try call.number("ohms")
            guard ohms >= 0 else { throw LocalError(message: "Use nonnegative resistance.") }
            return try Self.measurements([("Volts", amps * ohms), ("Watts", amps * amps * ohms)])
        case "electrical.parallel":
            let resistances = try Self.numbers(call.text("text"))
            guard resistances.allSatisfy({ $0 > 0 }) else { throw LocalError(message: "Each resistance must be positive.") }
            return try Self.measurement(1 / resistances.reduce(0) { $0 + 1 / $1 }, unit: " Ω")
        case "encode.base64": return ToolOutput(text: try Data(call.text("text").utf8).base64EncodedString())
        case "decode.base64":
            let data = try call.text("text").split(whereSeparator: \.isWhitespace).joined()
            guard let decoded = Data(base64Encoded: data), let text = String(data: decoded, encoding: .utf8) else {
                throw LocalError(message: "Provide valid Base64 that decodes to UTF-8 text.")
            }
            return ToolOutput(text: text)
        case "encode.url":
            let ascii = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            return ToolOutput(text: try call.text("text").addingPercentEncoding(withAllowedCharacters: ascii) ?? "")
        case "decode.url":
            guard let decoded = try call.text("text").removingPercentEncoding else {
                throw LocalError(message: "The percent escapes are invalid.")
            }
            return ToolOutput(text: decoded)
        case "hash.sha256":
            let hash = SHA256.hash(data: try Data(call.text("text").utf8))
            return ToolOutput(text: hash.map { String(format: "%02x", $0) }.joined())
        case "time.now":
            let zone = try call.text("zone", default: TimeZone.current.identifier)
            guard let timezone = TimeZone(identifier: zone) else {
                throw LocalError(message: "Use an IANA timezone, for example Asia/Riyadh.")
            }
            let format = ISO8601DateFormatter()
            format.timeZone = timezone
            return ToolOutput(text: "\(format.string(from: Date())) · \(zone)")
        case "time.days_between":
            let (_, calendar) = Self.dateFormat()
            let from = try Self.date(call.text("from"))
            let to = try Self.date(call.text("to"))
            return ToolOutput(text: "\(calendar.dateComponents([.day], from: from, to: to).day ?? 0) days")
        case "time.add_days":
            let (formatter, calendar) = Self.dateFormat()
            let date = try Self.date(call.text("date"))
            let days = try Self.integer(call.number("days"))
            guard abs(days) <= 1_000_000, let result = calendar.date(byAdding: .day, value: days, to: date) else {
                throw LocalError(message: "That date is out of range.")
            }
            return ToolOutput(text: formatter.string(from: result))
        case "time.weekday":
            let date = try Self.date(call.text("date"))
            let (formatter, _) = Self.dateFormat()
            formatter.dateFormat = "EEEE"
            return ToolOutput(text: formatter.string(from: date))
        default: throw LocalError(message: "The selected tool is unavailable.")
        }
    }

    private static let numberPattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?"#

    private static func extract(_ text: String, pattern: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func numbers(_ text: String) throws -> [Double] {
        let fields = text.split { $0.isWhitespace || $0 == "," || $0 == ";" }
        let values = fields.compactMap { Double($0) }
        guard !values.isEmpty, values.count == fields.count, values.allSatisfy(\.isFinite) else {
            throw LocalError(message: "Enter finite numbers separated by commas or spaces.")
        }
        return values
    }

    private static func integer(_ value: Double) throws -> Int {
        guard abs(value) <= 1_000_000_000_000, value.rounded(.towardZero) == value else {
            throw LocalError(message: "Use a whole number within the supported range.")
        }
        return Int(value)
    }

    private static func measurement(_ value: Double, unit: String = "") throws -> ToolOutput {
        guard value.isFinite else { throw LocalError(message: "The result is undefined or out of range.") }
        return ToolOutput(text: ToolCatalog.format(value) + unit)
    }

    private static func measurements(_ values: [(String, Double)]) throws -> ToolOutput {
        let lines = try values.map { label, value in "\(label) \(try measurement(value).text)" }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }

    private static func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private static func stringify(_ value: Any, pretty: Bool = true) throws -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.fragmentsAllowed, .prettyPrinted, .sortedKeys] : [.fragmentsAllowed, .sortedKeys]
        return try String(decoding: JSONSerialization.data(withJSONObject: value, options: options), as: UTF8.self)
    }

    private static func dateFormat() -> (DateFormatter, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter, calendar)
    }

    private static func date(_ input: String) throws -> Date {
        let (formatter, _) = dateFormat()
        guard let date = formatter.date(from: input), formatter.string(from: date) == input else {
            throw LocalError(message: "Use a valid date in YYYY-MM-DD format.")
        }
        return date
    }
}

enum CSV {
    static func parse(_ input: String) throws -> [[String]] {
        enum Mode { case plain, quoting, afterQuote }
        let text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !text.isEmpty else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var mode = Mode.plain
        for character in text {
            if mode == .quoting {
                if character == "\"" { mode = .afterQuote } else { field.append(character) }
                continue
            }
            if mode == .afterQuote && character == "\"" {
                field.append(character)
                mode = .quoting
                continue
            }
            switch character {
            case ",", "\n":
                row.append(field)
                field = ""
                mode = .plain
                if character == "\n" {
                    rows.append(row)
                    row = []
                }
            case "\"" where field.isEmpty:
                mode = .quoting
            default:
                guard mode != .afterQuote, character != "\"" else {
                    throw LocalError(message: "A CSV field has unexpected quotes or text.")
                }
                field.append(character)
            }
        }
        guard mode != .quoting else { throw LocalError(message: "A CSV field has an unclosed quote.") }
        if text.last != "\n" {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func write(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { value in
                if value.contains(where: { $0 == "\"" || $0 == "," || $0.isNewline }) {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }
}
