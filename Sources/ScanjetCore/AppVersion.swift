/// Generated from `VERSION` by `scripts/embed-version.sh`. Do not edit.
public enum AppVersion: Sendable {
    public static let marketing = "1.2.0"
    public static let build = "1.2.0"

    public static var display: String {
        if build == marketing { return marketing }
        return "\(marketing) (\(build))"
    }

    public static var cliLine: String {
        if build == marketing { return "scanjet \(marketing)" }
        return "scanjet \(marketing) (\(build))"
    }
}
