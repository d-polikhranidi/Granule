@testable import ClickHouseCore
import Foundation
import Testing

@Suite struct CHTypeTests {
    @Test func typeNamesAreParsed() {
        #expect(CHType(parsing: "UInt64") == .uint64)
        #expect(CHType(parsing: "Nullable(String)") == .nullable(.string))
        #expect(CHType(parsing: "LowCardinality(Nullable(String))") == .lowCardinality(.nullable(.string)))
        #expect(CHType(parsing: "DateTime('Europe/Berlin')") == .dateTime(timeZone: "Europe/Berlin"))
        #expect(CHType(parsing: "DateTime64(3, 'UTC')") == .dateTime64(precision: 3, timeZone: "UTC"))
        #expect(CHType(parsing: "DateTime64(6)") == .dateTime64(precision: 6, timeZone: nil))
        #expect(CHType(parsing: "Decimal(18, 2)") == .decimal(precision: 18, scale: 2))
        #expect(CHType(parsing: "Decimal64(4)") == .decimal(precision: 18, scale: 4))
        #expect(CHType(parsing: "Map(String, Array(UInt8))") == .map(key: .string, value: .array(.uint8)))
        #expect(CHType(parsing: "Tuple(a UInt8, `b c` String)") == .tuple([CHTupleElement(name: "a", type: .uint8),
                                                                              CHTupleElement(name: "b c", type: .string)]))
        #expect(CHType(parsing: "Tuple(UInt8, Nullable(String))") == .tuple([CHTupleElement(type: .uint8), CHTupleElement(type: .nullable(.string))]))
        #expect(CHType(parsing: "Nested(x UInt8, y String)") == .array(.tuple([CHTupleElement(name: "x", type: .uint8),
                                                                               CHTupleElement(name: "y", type: .string)])))
        #expect(CHType(parsing: "Enum8('a' = 1, 'b\\'c' = -2)") == .enum8([CHEnumCase(name: "a", value: 1), CHEnumCase(name: "b'c", value: -2)]))
        #expect(CHType(parsing: "Variant(String, UInt64)") == .variant([.string, .uint64]))
        #expect(CHType(parsing: "Dynamic(max_types=10)") == .dynamic)
        #expect(CHType(parsing: "JSON(max_dynamic_paths=10, a.b UInt32, SKIP c)") == .json)
        #expect(CHType(parsing: "SimpleAggregateFunction(sum, UInt64)") == .uint64)
        #expect(CHType(parsing: "IntervalSecond") == .interval("Second"))
        #expect(CHType(parsing: "AggregateFunction(uniq, UInt64)") == .unsupported("AggregateFunction(uniq, UInt64)"))
        #expect(!CHType(parsing: "Array(AggregateFunction(uniq, UInt64))").isReadable)
        #expect(CHType(parsing: "FixedString(16)") == .fixedString(16))
        #expect(CHType(parsing: "Time64(3)") == .time64(precision: 3))
    }

    @Test func statementsAreSplitOutsideStringsAndComments() {
        let text = "SELECT 'a;b' -- c;d\n; SELECT `x;y` FROM t /* ; */ ;\n\n  ;SHOW TABLES"
        let ranges = CHSQL.statements(text)
        let statements = ranges.map { (text as NSString).substring(with: $0) }
        #expect(statements == ["SELECT 'a;b'", "SELECT `x;y` FROM t", "SHOW TABLES"])
        #expect(CHSQL.statement(at: 3, in: text) == ranges[0])
        #expect(CHSQL.statement(at: (text as NSString).length, in: text) == ranges[2])
    }

    @Test func statementsAreToldApart() {
        #expect(CHSQL.kind(of: "  -- note\n select 1") == .read)
        #expect(CHSQL.kind(of: "WITH 1 AS x SELECT x") == .read)
        #expect(CHSQL.kind(of: "(SELECT 1)") == .read)
        #expect(CHSQL.kind(of: "INSERT INTO t VALUES (1)") == .other)
        #expect(CHSQL.kind(of: "SET max_threads = 1") == .other)
        #expect(CHSQL.formatClause(of: "SELECT 1 FORMAT JSONEachRow") == "JSONEachRow")
        #expect(CHSQL.formatClause(of: "SELECT 'FORMAT CSV'") == nil)
        #expect(CHSQL.parameters(of: "SELECT {id:UInt64}, {name: String}, {id:UInt64}") == [
            CHSQL.Parameter(name: "id", type: "UInt64"), CHSQL.Parameter(name: "name", type: "String"),
        ])
    }

    @Test func endpointsAreParsedFromURLs() throws {
        let cloud = try #require(CHEndpoint.parse("https://default:secret@abc.eu-west-1.aws.clickhouse.cloud:8443/analytics"))
        #expect(cloud.endpoint.host == "abc.eu-west-1.aws.clickhouse.cloud")
        #expect(cloud.endpoint.isSecure && cloud.endpoint.port == 8443 && cloud.endpoint.isCloud)
        #expect(cloud.endpoint.database == "analytics" && cloud.password == "secret")
        let native = try #require(CHEndpoint.parse("clickhouse://reader@db.local:9440?secure=true"))
        #expect(native.endpoint.port == 8443 && native.endpoint.isSecure && native.endpoint.user == "reader")
        let bare = try #require(CHEndpoint.parse("localhost"))
        #expect(bare.endpoint.port == 8123 && !bare.endpoint.isSecure)
    }

    @Test func serverErrorsAreParsed() {
        let error = CHServerError(text: "Code: 60. DB::Exception: Unknown table expression identifier 'x' in scope SELECT * FROM x. (UNKNOWN_TABLE) (version 26.6.1.1193 (official build))\n")
        #expect(error.code == 60)
        #expect(error.name == "UNKNOWN_TABLE")
        #expect(error.message == "Unknown table expression identifier 'x' in scope SELECT * FROM x.")
    }
}
