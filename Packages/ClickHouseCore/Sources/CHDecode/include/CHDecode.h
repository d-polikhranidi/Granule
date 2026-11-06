// The loops over every value of a ClickHouse result: reading Native's strings,
// turning values into numbers (sorting, totals) and into text (cells, search,
// copy). C with -O3, so debug builds of the apps read millions of rows as fast.
#ifndef CHDECODE_H
#define CHDECODE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: Strings

/// Walks `rows` strings of Native's layout (a VarUInt length, then the bytes)
/// from `src`: the bytes they take in `src`, or -1 if `src` ends first (or a
/// length is past 2^31). `chars` gets the strings' bytes in all.
int64_t ch_scan_strings(const uint8_t *src, size_t src_count, size_t rows, size_t *chars);

/// Copies the strings `ch_scan_strings` walked: their bytes one after another
/// into `chars`, where each one ends into `ends` (`ends[i]`, from `base`).
void ch_copy_strings(const uint8_t *src, size_t rows, uint8_t *chars, uint32_t *ends, uint32_t base);

/// Reads a VarUInt (LEB128) from `src`: the bytes it takes, or -1 if `src`
/// ends first or it's longer than 10 bytes.
int64_t ch_read_varuint(const uint8_t *src, size_t src_count, uint64_t *value);

// MARK: Numbers

/// How a column's values are stored.
typedef enum {
    CH_I8, CH_U8, CH_I16, CH_U16, CH_I32, CH_U32, CH_I64, CH_U64,
    CH_I128, CH_U128, CH_I256, CH_U256, CH_F32, CH_F64, CH_BF16,
} ch_number_kind;

/// `dst[i]` = value `start + i` of `src` times `scale` (dates to seconds,
/// decimals and ticks to units), for `count` values.
void ch_numbers(ch_number_kind kind, const void *src, size_t start, size_t count, double scale, double *dst);

/// `dst[i]` = `dictionary[indexes[start + i]]` (a LowCardinality column).
void ch_gather_numbers(const double *dictionary, const uint32_t *indexes, size_t start, size_t count, double *dst);

/// NaN in `dst[i]` where `nulls[start + i]` isn't 0 (a Nullable column's NULLs).
void ch_apply_nulls(const uint8_t *nulls, size_t start, size_t count, double *dst);

// MARK: Text

/// Room for any value's text these write (an Int256 has 78 characters).
#define CH_TEXT_CAPACITY 96

/// An integer as ClickHouse writes it: the bytes written.
size_t ch_format_integer(ch_number_kind kind, const void *src, size_t index, char *out);

/// A decimal (an integer of `kind` scaled by 10^-`scale`) as ClickHouse
/// writes it: no trailing zeros after the point.
size_t ch_format_decimal(ch_number_kind kind, const void *src, size_t index, int scale, char *out);

/// A day (since 1970-01-01) as YYYY-MM-DD.
size_t ch_format_date(int64_t days, char *out);

/// Seconds since 1970 in local time (the offset applied) as YYYY-MM-DD hh:mm:ss,
/// and `fraction` of `precision` digits after a point if `precision` > 0.
size_t ch_format_datetime(int64_t seconds, int64_t fraction, int precision, char *out);

/// A time of day (or a duration) as ClickHouse's Time writes it: [-]h:mm:ss,
/// at least two digits of hours, and `fraction` of `precision` digits.
size_t ch_format_time(int64_t seconds, int64_t fraction, int precision, char *out);

/// A UUID from Native's 16 bytes (each half little-endian).
size_t ch_format_uuid(const uint8_t *bytes, char *out);

/// An IPv4 address from its UInt32.
size_t ch_format_ipv4(uint32_t address, char *out);

/// An IPv6 address from its 16 bytes (an IPv4-mapped one as ::ffff:a.b.c.d).
size_t ch_format_ipv6(const uint8_t *bytes, char *out);

/// A float's shortest digits as Swift's `description` writes them (`1e-07`,
/// `1.2345678901234568e+20`, `-0.0`, `inf`) as ClickHouse writes floats: a
/// whole number below 10^21, exponent form below 10^-6 (as JavaScript).
size_t ch_reformat_float(const char *shortest, size_t count, char *out);

// MARK: Text of many values

// Each writes the text of `count` values from value `start` one after another
// into `out` (room for `count` * CH_TEXT_CAPACITY bytes), where each ends
// (from `base`) into `ends`, and returns the bytes written. A value whose
// `nulls[i]` (if `nulls` isn't NULL) isn't 0 has no text.

size_t ch_format_integers(ch_number_kind kind, const void *src, const uint8_t *nulls, size_t start, size_t count,
                          char *out, uint32_t *ends, uint32_t base);
size_t ch_format_decimals(ch_number_kind kind, const void *src, const uint8_t *nulls, size_t start, size_t count, int scale,
                          char *out, uint32_t *ends, uint32_t base);
/// Date (UInt16 days, `wide` 0) or Date32 (Int32 days, `wide` 1).
size_t ch_format_dates(int wide, const void *src, const uint8_t *nulls, size_t start, size_t count,
                       char *out, uint32_t *ends, uint32_t base);
/// DateTime (UInt32 seconds, `precision` -1) or DateTime64 (Int64 ticks of
/// 10^-precision s) in local time: `offsets[i]` applies from `instants[i]`
/// (seconds since 1970) on, `offsets[0]` before `instants[0]` too.
size_t ch_format_datetimes(const void *src, int precision, const uint8_t *nulls, size_t start, size_t count,
                           const int64_t *instants, const int32_t *offsets, size_t zone_count,
                           char *out, uint32_t *ends, uint32_t base);
/// The least and most seconds of DateTime (`precision` -1) or DateTime64 values.
void ch_seconds_range(const void *src, int precision, size_t start, size_t count, int64_t *least, int64_t *most);
size_t ch_format_uuids(const uint8_t *src, const uint8_t *nulls, size_t start, size_t count, char *out, uint32_t *ends, uint32_t base);
size_t ch_format_ipv4s(const uint32_t *src, const uint8_t *nulls, size_t start, size_t count, char *out, uint32_t *ends, uint32_t base);

// MARK: Charts

/// The least and most of `count` values (NaN left out); NaN both for none.
void ch_range(const double *values, size_t count, double *least, double *most);

/// Whether `count` values (NaN left out) never go down.
int ch_is_ascending(const double *values, size_t count);

/// Points (`x[i]`, `y[i]`) into `buckets` buckets of x over [x0, x1]: each
/// bucket's least, most and sum of y and how many (NaN on either side left
/// out). The arrays have `buckets` entries; `least`/`most` start as +/-inf.
void ch_bucket(const double *x, const double *y, size_t count, double x0, double x1, size_t buckets,
               double *least, double *most, double *sum, uint32_t *counts);

#ifdef __cplusplus
}
#endif

#endif
