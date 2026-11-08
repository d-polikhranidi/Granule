# Granule

A native ClickHouse client for the Mac, iPad and iPhone, made for results of
any size. Rows appear as they arrive, and tens of millions of them sort,
search and scroll at once.

## What it does

**Results**
- Rows show while the query still runs, with the rows read of those expected, the memory used and the server's own figures when it ends. Stop ends the query on the server too.
- Sort by any column, search every column, and see totals. Selection and sort stay when a view refreshes.
- Values look the way ClickHouse writes them: times in their column's time zone, exact decimals, arrays, maps, tuples, JSON. A long value opens whole, with JSON laid out; on the Mac an inspector beside the result shows the value under the cursor and its whole row.
- Charts of a result: lines over time or bars by category, for millions of points.
- Number columns as data bars or a heatmap.
- Export to CSV, TSV, Parquet, Arrow or JSON lines. The server writes the file, so it can be larger than the screen's result. The rows as shown, sorted and searched, go to Excel or CSV.

**The editor**
- Highlighting, and completion from the server's own functions, settings and formats and from your tables and columns.
- Statements are checked as you type by the server itself, so syntax, names and types follow your server's version. A misspelled name gets the names it may be. INSERT, ALTER and DELETE are checked against the schema before they run.
- Query parameters (`{name:Type}`), history per connection, and tabs on the Mac.
- Run all statements of a script one after another in one session, so SET, USE and temporary tables carry on; the first that fails stops the rest and is selected.
- Saved queries, shared by every connection, and a history you can search.
- Format a statement with the server's own formatter.
- Query Details: a run's time, rows, bytes and memory from the server's log, next to the run of the same statement before it.

**Safeguards**
- On a production connection, a statement that drops, deletes or rewrites data runs only once you type the connection's name.
- A read-only connection writes nowhere, and a production one starts read only.
- A query the server estimates to read more than a billion rows (you choose the limit) asks first.
- Running something else while a statement that changes data still runs asks first, since what it already changed stays changed.

**The schema**
- Databases, tables and columns, with sizes and compression.
- A table's details: keys, partitions, parts, skip indexes, projections and the views that read it, plus its CREATE statement.

**The server**
- Health on one page: replicas behind, partitions with too many parts, failing mutations, a stuck replication queue, detached parts, disks nearly full, memory nearly all used, delayed inserts, dictionaries that failed to load, long queries and merges.
- Running, recent, failed and heaviest queries; merges, mutations, replicas and their queue; errors, disks, changed settings and metrics.
- Live views refresh every two seconds. A query or mutation can be killed from its row.
- On a cluster, every view can cover all of its servers at once.

**Explain**
- The plan as an outline, showing what the indexes skip: "reads 3 of 1,229 granules".
- The pipeline drawn as a graph of processors and streams.
- Both also as text, along with estimates and the query as the server rewrites it, and EXPLAIN ANALYZE on ClickHouse 26.7 and later.

**Connections**
- HTTP and HTTPS, including ClickHouse Cloud: a sleeping service is given time to wake.
- A certificate pinned by its fingerprint, your own authority, or a client certificate for servers that ask for one.
- Servers behind an SSH bastion, signed in with a key (ed25519 or ECDSA, a passphrase too) or a password. The bastion's key is checked, and the connection comes back by itself after sleep.
- Compression (LZ4 or ZSTD) only off the local network.
- Paste a URL to fill a connection in, or import the connections clickhouse-client keeps. Passwords and keys are kept in the Keychain.
- No server yet? Try it on ClickHouse's public playground, read only, from the empty list.

The app speaks English and Russian.

## Requirements

- macOS 14 or later; iPadOS and iOS 17 or later.
- ClickHouse 23.8 or later, over its HTTP interface (ports 8123 and 8443). It's tested on 23.8, 25.8, 26.3, 26.6, 26.8 and 26.10.

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

MIT (see [LICENSE](LICENSE)). [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists the third-party code it includes. Gingham is a separate binary under its own license.

ClickHouse is a trademark of ClickHouse, Inc. Granule is an independent client and isn't affiliated with or endorsed by ClickHouse, Inc.
