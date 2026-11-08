import Testing
@testable import ClickHouseCore

/// Arrays, tuples and maps laid out for the value's inspector, still ClickHouse's syntax.
@Suite struct CHValueLayoutTests {
    @Test func longValuesTakeALineAnItem() {
        let text = "[('a','b','c','d'),('e','f','g','h'),('i','j','k','l')]"
        #expect(CHValueLayout.laidOut(text, width: 30) == """
            [
              ('a', 'b', 'c', 'd'),
              ('e', 'f', 'g', 'h'),
              ('i', 'j', 'k', 'l')
            ]
            """)
        #expect(CHValueLayout.laidOut("[1,2,3]") == "[1, 2, 3]")
        #expect(CHValueLayout.laidOut("[]") == "[]")
    }

    @Test func stringsKeepWhatsInThem() {
        #expect(CHValueLayout.laidOut(#"['a,b','c\']d','(x)']"#) == #"['a,b', 'c\']d', '(x)']"#)
    }

    @Test func mapsAndNestingAndTimes() {
        let text = "{'first':[('2026-11-07 12:30:00',1),('2026-11-08 08:00:00',2)],'second':[]}"
        #expect(CHValueLayout.laidOut(text, width: 40) == """
            {
              'first': [
                ('2026-11-07 12:30:00', 1),
                ('2026-11-08 08:00:00', 2)
              ],
              'second': []
            }
            """)
    }

    @Test func namedTuplesFieldsAreLabeled() {
        let type = CHType(parsing: "Array(Tuple(id UInt32, tags Map(String, Tuple(score Float64, seen DateTime))))")
        let text = "[(1,{'a':(0.5,'2026-11-07 12:30:00')}),(2,{})]"
        #expect(CHValueLayout.laidOut(text, type: type, width: 80) == """
            [
              (id: 1, tags: {'a': (score: 0.5, seen: '2026-11-07 12:30:00')}),
              (id: 2, tags: {})
            ]
            """)
        // Unnamed fields, or a type that doesn't match the text: as it is.
        #expect(CHValueLayout.laidOut("[(1,'a')]", type: CHType(parsing: "Array(Tuple(UInt8, String))")) == "[(1, 'a')]")
        #expect(CHValueLayout.laidOut("[(1,'a')]", type: CHType(parsing: "Array(Tuple(x UInt8))")) == "[(1, 'a')]")
    }

    @Test func otherTextIsLeftAlone() {
        #expect(CHValueLayout.laidOut("hello") == nil)
        #expect(CHValueLayout.laidOut("[1,2") == nil)
        #expect(CHValueLayout.laidOut("[INFO] started") == nil)
        #expect(CHValueLayout.laysOut(CHType(parsing: "Array(Tuple(String, String))")))
        #expect(CHValueLayout.laysOut(CHType(parsing: "Nullable(Tuple(a UInt8))")))
        #expect(!CHValueLayout.laysOut(CHType(parsing: "String")))
    }
}
