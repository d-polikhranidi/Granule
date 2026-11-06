# Clickhouse Viewer

*A working name: the app will be renamed before its release.*

A native ClickHouse client for the Mac, iPad and iPhone, made for results of
any size. Rows appear as they arrive, and tens of millions of them sort,
search and scroll at once.

## What it does

**Results**
- Rows show while the query still runs, with the rows read of those expected, the memory used and the server's own figures when it ends. Stop ends the query on the server too.
- Sort by any column, search every column, and see totals. Selection and sort stay when a view refreshes.
- Values look the way ClickHouse writes them: times in their column's time zone, exact decimals, arrays, maps, tuples, JSON. A long value opens whole, with JSON laid out; on the Mac an inspector beside the result shows the value under the cursor and its whole row.
- Charts of a result: lines over time or bars by category, for millions of points.
- Export to CSV, TSV, Parquet, Arrow or JSON lines. The server writes the file, so it can be larger than the screen's result.

**The editor**
- Highlighting, and completion from the server's own functions, settings and formats and from your tables and columns.
- Statements are checked as you type by the server itself, so syntax, names and types follow your server's version. A misspelled name gets the names it may be. INSERT, ALTER and DELETE are checked against the schema before they run.
- Query parameters (`{name:Type}`), history per connection, and tabs on the Mac.

**The schema**
- Databases, tables and columns, with sizes and compression.
- A table's details: keys, partitions, parts, skip indexes, projections and the views that read it, plus its CREATE statement.

**The server**
- Running, recent, failed and heaviest queries; merges, mutations, replicas and their queue; errors, disks, changed settings and metrics.
- Live views refresh every two seconds. A query or mutation can be killed from its row.
- On a cluster, every view can cover all of its servers at once.

**Explain**
- The plan as an outline, showing what the indexes skip: "reads 3 of 1,229 granules".
- The pipeline drawn as a graph of processors and streams.
- Both also as text, along with estimates and the query as the server rewrites it.

**Connections**
- HTTP and HTTPS, including ClickHouse Cloud: a sleeping service is given time to wake.
- A certificate pinned by its fingerprint, your own authority, or a client certificate for servers that ask for one.
- Servers behind an SSH bastion, signed in with a key or a password. The bastion's key is checked, and the connection comes back by itself after sleep.
- A read-only mode, and compression only off the local network.
- Paste a URL to fill a connection in. Passwords and keys are kept in the Keychain.

## Requirements

- macOS 14 or later; iPadOS and iOS 17 or later.
- ClickHouse 23.8 or later, over its HTTP interface (ports 8123 and 8443). It's tested on 23.8 and 26.6.

## Building

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
Tools/generate.sh release
open ClickHouseViewer.xcodeproj
```

The table comes from [Gingham](https://github.com/digitalglobeby/Gingham), and its binary is fetched by Swift Package Manager. `Shared/GinghamKey.swift` holds a free key for this app's bundle id (`by.digitalglobe.Clickhouse-Viewer`). Built under another bundle id, a table shows its first 10,000 rows.

## Privacy

The app collects nothing and has no tracking. It talks only to the servers you add. Connections are kept on your device, and their passwords and keys are kept in the Keychain.

## License

MIT (see [LICENSE](LICENSE)), which also lists the third-party code it includes. Gingham is a separate binary under its own license.
