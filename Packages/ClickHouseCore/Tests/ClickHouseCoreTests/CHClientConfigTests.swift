import Foundation
import Testing
@testable import ClickHouseCore

/// clickhouse-client's connections as the viewer's: its native ports as HTTP's, Cloud over HTTPS.
@Suite struct CHClientConfigTests {
    @Test func xmlConnectionsAreRead() {
        let xml = """
            <config>
                <host>localhost</host>
                <user>me</user>
                <connections_credentials>
                    <connection>
                        <name>prod</name>
                        <hostname>ch.example.com</hostname>
                        <port>9440</port>
                        <secure>1</secure>
                        <user>reader</user>
                        <password>s3cret &amp; more</password>
                        <database>sales</database>
                    </connection>
                    <connection>
                        <name>abc.eu-west-1.aws.clickhouse.cloud</name>
                        <password>x</password>
                    </connection>
                    <connection>
                        <name>local http</name>
                        <hostname>127.0.0.1</hostname>
                        <port>18123</port>
                    </connection>
                </connections_credentials>
            </config>
            """
        let found = CHClientConfig.connections(in: Data(xml.utf8))
        #expect(found.count == 4)
        #expect(found[0].endpoint.host == "localhost" && found[0].endpoint.user == "me" && found[0].endpoint.port == 8123)
        let prod = found[1]
        #expect(prod.endpoint.name == "prod" && prod.endpoint.host == "ch.example.com")
        #expect(prod.endpoint.port == 8443 && prod.endpoint.isSecure && prod.nativePort == 9440)
        #expect(prod.endpoint.user == "reader" && prod.endpoint.database == "sales" && prod.password == "s3cret & more")
        let cloud = found[2]
        #expect(cloud.endpoint.host == "abc.eu-west-1.aws.clickhouse.cloud" && cloud.endpoint.name.isEmpty)
        #expect(cloud.endpoint.isSecure && cloud.endpoint.port == 8443 && cloud.endpoint.user == "default")
        #expect(found[3].endpoint.port == 18123 && !found[3].endpoint.isSecure && found[3].nativePort == nil)
    }

    @Test func yamlConnectionsAreRead() {
        let yaml = """
            # clickhouse-client
            host: db1
            connections_credentials:
              connection:
                - name: prod
                  hostname: "ch.example.com"
                  port: 9000
                  user: reader
                  password: 'pa:ss'   # quoted
                - name: staging
                  hostname: staging.example.com
                  secure: true
                  password: "abc #123" # a hash in a quoted value is the value's
            history_file: ~/.history
            """
        let found = CHClientConfig.connections(in: Data(yaml.utf8))
        #expect(found.map(\.endpoint.host) == ["db1", "ch.example.com", "staging.example.com"])
        #expect(found[1].endpoint.port == 8123 && found[1].nativePort == 9000 && found[1].password == "pa:ss")
        #expect(found[2].endpoint.isSecure && found[2].endpoint.port == 8443 && found[2].password == "abc #123")
        // A single connection as a mapping.
        let single = CHClientConfig.connections(in: Data("connections_credentials:\n  connection:\n    name: one\n    hostname: h\n".utf8))
        #expect(single.map(\.endpoint.host) == ["h"])
    }

    @Test func nothingToReadIsNothing() {
        #expect(CHClientConfig.connections(in: Data("<config><history_file>x</history_file></config>".utf8)).isEmpty)
        #expect(CHClientConfig.connections(in: Data("not: [a config".utf8)).isEmpty)
        #expect(CHClientConfig.connections(in: Data()).isEmpty)
    }
}
