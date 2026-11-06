import Gingham

/// Gingham's free key for this open-source app: every row of a result shown.
/// It unlocks only the bundle id by.digitalglobe.Clickhouse-Viewer (with
/// another, tables show up to `GHLicense.freeRowLimit` rows).
enum GinghamKey {
    static let key = "GH1.eyJidW5kbGVzIjpbImJ5LmRpZ2l0YWxnbG9iZS5DbGlja2hvdXNlLVZpZXdlciJdLCJlZGl0aW9uIjoib3Blbi1zb3VyY2UiLCJpZCI6IkdILTIwMjYtT1NTLTAwMDEiLCJpc3N1ZWQiOiIyMDI2LTExLTA2IiwibGljZW5zZWUiOiJDbGlja2hvdXNlIFZpZXdlciAob3BlbiBzb3VyY2UsIGRpZ2l0YWxnbG9iZWJ5KSIsIm1ham9yIjoxLCJ2IjoxfQ.VeA8SyxLnbsrGI81xXav2nVoz4Ac_5ezFEB96_blkGTHHxrhd9RyYQfoe-CslGhoCuC8UNymlIh9GC6Nz6PeDQ"

    static func register() {
        GHLicense.register(key)
    }
}
