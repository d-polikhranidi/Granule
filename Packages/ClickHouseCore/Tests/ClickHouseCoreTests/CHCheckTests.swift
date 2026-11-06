import ClickHouseCore
import Foundation
import Testing

@Suite struct CHLocalCheckTests {
    private func messages(_ statement: String) -> [String] {
        CHSQL.localProblems(in: statement).map { "\(($0.range.map { (statement as NSString).substring(with: $0) }) ?? "-")|\($0.message)" }
    }

    @Test func openQuotesCommentsAndBrackets() {
        #expect(CHSQL.localProblems(in: "SELECT 'it''s', `a b`, (1 + [2, 3][1]) /* ok */ FROM t").isEmpty)
        #expect(messages("SELECT 'open") == ["'open|This string has no closing quote."])
        #expect(messages("SELECT 'escaped\\'") == ["'escaped\\'|This string has no closing quote."])
        #expect(messages("SELECT `name FROM t").count == 1)
        #expect(messages("SELECT 1 /* never closed").first?.hasPrefix("/*|") == true)
        #expect(messages("SELECT count( FROM t") == ["(|This bracket isn't closed: no )."])
        #expect(messages("SELECT 1)") == [")|This bracket closes none."])
        #expect(messages("SELECT [1, 2)").count == 2)
        #expect(messages("SELECT {id} ") == ["{id}|A parameter is {name:Type}: this one has no type."])
    }

    @Test func scalarSubqueriesAreTold() {
        #expect(CHSQL.mayHaveScalarSubquery("SELECT (SELECT max(x) FROM t) AS m"))
        #expect(CHSQL.mayHaveScalarSubquery("SELECT * FROM t WHERE x = (SELECT 1)"))
        #expect(!CHSQL.mayHaveScalarSubquery("SELECT * FROM t WHERE x IN (SELECT x FROM u)"))
        #expect(!CHSQL.mayHaveScalarSubquery("SELECT * FROM (SELECT 1) JOIN (SELECT 2) USING (x)"))
    }
}

@Suite(.enabled(if: TestServer.isAvailable, "CH_TEST_URL names no server"), .serialized)
struct CHServerCheckTests {
    @Test func syntaxErrorsArePlaced() async throws {
        let client = try await TestServer.connected()
        let statement = "SELECT 'Юникод', count( FROM numbers(10)"
        let problems = try await client.check(statement)
        let problem = try #require(problems.first)
        #expect(problem.range.map { (statement as NSString).substring(with: $0) } == "(")
        #expect(problem.message.hasPrefix("Syntax error at (."))
        let typo = "SELECT number FROM numbers(10) GROPU BY number"
        let other = try #require(try await client.check(typo).first)
        #expect(other.range.map { (typo as NSString).substring(with: $0) } == "BY")
    }

    @Test func unknownNamesAreFoundWithSuggestions() async throws {
        let client = try await TestServer.connected()
        let statement = "SELECT numbr, count() FROM numbers(10) GROUP BY number"
        let problem = try #require(try await client.check(statement).first)
        #expect(problem.range.map { (statement as NSString).substring(with: $0) } == "numbr")
        #expect(problem.suggestions.contains("number"))
        #expect(!problem.message.contains("in scope"))
        let function = "SELECT cuont() FROM numbers(10)"
        let unknown = try #require(try await client.check(function).first)
        #expect(unknown.range.map { (function as NSString).substring(with: $0) } == "cuont")
        #expect(unknown.suggestions.contains("count"))
    }

    @Test func goodStatementsAndHeavyOnesPass() async throws {
        let client = try await TestServer.connected()
        #expect(try await client.check("SELECT number, toString(number) FROM numbers(10) WHERE number IN (SELECT 1) ORDER BY number").isEmpty)
        #expect(try await client.check("CREATE TABLE IF NOT EXISTS t (x UInt8) ENGINE = Memory").isEmpty)
        #expect(try await client.check("SELECT 1 FORMAT JSONEachRow").isEmpty)
        // A scalar subquery the server would run: stopped by the limit, no verdict, not an error.
        let started = ContinuousClock.now
        #expect(try await client.check("SELECT (SELECT sum(sipHash64(number)) FROM numbers_mt(100000000000))", limit: 0.5).isEmpty)
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
