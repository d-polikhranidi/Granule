#include "CHDecode.h"

#include <arpa/inet.h>
#include <math.h>
#include <string.h>
#include <sys/socket.h>

// MARK: Strings

int64_t ch_read_varuint(const uint8_t *src, size_t src_count, uint64_t *value) {
    uint64_t result = 0;
    for (size_t i = 0; i < src_count && i < 10; i++) {
        uint8_t byte = src[i];
        result |= (uint64_t)(byte & 0x7F) << (7 * i);
        if (!(byte & 0x80)) {
            *value = result;
            return (int64_t)(i + 1);
        }
    }
    return -1;
}

int64_t ch_scan_strings(const uint8_t *src, size_t src_count, size_t rows, size_t *chars) {
    size_t at = 0, total = 0;
    for (size_t row = 0; row < rows; row++) {
        // Most strings are shorter than 128 bytes: one length byte.
        if (at < src_count && src[at] < 0x80) {
            size_t length = src[at];
            at += 1;
            if (length > src_count - at) return -1;
            at += length;
            total += length;
            continue;
        }
        uint64_t length;
        int64_t used = ch_read_varuint(src + at, src_count - at, &length);
        if (used < 0 || length > (1u << 31)) return -1;
        at += (size_t)used;
        if (length > src_count - at) return -1;
        at += (size_t)length;
        total += (size_t)length;
    }
    *chars = total;
    return (int64_t)at;
}

void ch_copy_strings(const uint8_t *src, size_t rows, uint8_t *chars, uint32_t *ends, uint32_t base) {
    size_t at = 0;
    uint32_t end = base;
    uint8_t *out = chars;
    for (size_t row = 0; row < rows; row++) {
        size_t length;
        if (src[at] < 0x80) {
            length = src[at];
            at += 1;
        } else {
            uint64_t value;
            at += (size_t)ch_read_varuint(src + at, 10, &value);
            length = (size_t)value;
        }
        // Short strings by 16-byte copies where the input has room; memcpy
        // of a variable length is a library call that costs more than them.
        if (length <= 16) {
            for (size_t i = 0; i < length; i++) out[i] = src[at + i];
        } else {
            memcpy(out, src + at, length);
        }
        out += length;
        at += length;
        end += (uint32_t)length;
        ends[row] = end;
    }
}

// MARK: Numbers

/// A 128- or 256-bit integer (little-endian 64-bit limbs) as a double.
static double wide_to_double(const uint64_t *limbs, int count, int is_signed) {
    uint64_t value[4];
    memcpy(value, limbs, (size_t)count * 8);
    int negative = is_signed && (value[count - 1] >> 63);
    if (negative) {
        // Two's complement: invert and add one.
        unsigned carry = 1;
        for (int i = 0; i < count; i++) {
            value[i] = ~value[i] + carry;
            carry = carry && value[i] == 0;
        }
    }
    double result = 0;
    for (int i = count - 1; i >= 0; i--) result = result * 18446744073709551616.0 + (double)value[i];
    return negative ? -result : result;
}

void ch_numbers(ch_number_kind kind, const void *src, size_t start, size_t count, double scale, double *dst) {
#define CONVERT(type) do { \
        const type *values = (const type *)src + start; \
        if (scale == 1) { for (size_t i = 0; i < count; i++) dst[i] = (double)values[i]; } \
        else { for (size_t i = 0; i < count; i++) dst[i] = (double)values[i] * scale; } \
    } while (0)
    switch (kind) {
    case CH_I8: CONVERT(int8_t); break;
    case CH_U8: CONVERT(uint8_t); break;
    case CH_I16: CONVERT(int16_t); break;
    case CH_U16: CONVERT(uint16_t); break;
    case CH_I32: CONVERT(int32_t); break;
    case CH_U32: CONVERT(uint32_t); break;
    case CH_I64: CONVERT(int64_t); break;
    case CH_U64: CONVERT(uint64_t); break;
    case CH_F32: CONVERT(float); break;
    case CH_F64: CONVERT(double); break;
    case CH_BF16: {
        const uint16_t *values = (const uint16_t *)src + start;
        for (size_t i = 0; i < count; i++) {
            uint32_t bits = (uint32_t)values[i] << 16;
            float value;
            memcpy(&value, &bits, 4);
            dst[i] = (double)value * scale;
        }
        break;
    }
    case CH_I128: case CH_U128: case CH_I256: case CH_U256: {
        int limbs = (kind == CH_I128 || kind == CH_U128) ? 2 : 4;
        int is_signed = kind == CH_I128 || kind == CH_I256;
        const uint64_t *values = (const uint64_t *)src + start * (size_t)limbs;
        for (size_t i = 0; i < count; i++) dst[i] = wide_to_double(values + i * (size_t)limbs, limbs, is_signed) * scale;
        break;
    }
    }
#undef CONVERT
}

void ch_gather_numbers(const double *dictionary, const uint32_t *indexes, size_t start, size_t count, double *dst) {
    const uint32_t *at = indexes + start;
    for (size_t i = 0; i < count; i++) dst[i] = dictionary[at[i]];
}

void ch_apply_nulls(const uint8_t *nulls, size_t start, size_t count, double *dst) {
    const uint8_t *at = nulls + start;
    for (size_t i = 0; i < count; i++) {
        if (at[i]) dst[i] = NAN;
    }
}

// MARK: Text

/// Two digits at a time.
static const char digit_pairs[201] =
    "00010203040506070809101112131415161718192021222324252627282930313233343536373839"
    "40414243444546474849505152535455565758596061626364656667686970717273747576777879"
    "8081828384858687888990919293949596979899";

/// An unsigned 64-bit number's digits, without leading zeros (at least one).
static size_t format_u64(uint64_t value, char *out) {
    char buffer[20];
    size_t at = 20;
    while (value >= 100) {
        uint64_t pair = value % 100;
        value /= 100;
        at -= 2;
        memcpy(buffer + at, digit_pairs + pair * 2, 2);
    }
    if (value >= 10) {
        at -= 2;
        memcpy(buffer + at, digit_pairs + value * 2, 2);
    } else {
        buffer[--at] = (char)('0' + value);
    }
    size_t length = 20 - at;
    memcpy(out, buffer + at, length);
    return length;
}

/// A wide unsigned integer's digits (limbs little-endian, changed: divided to 0).
static size_t format_wide(uint64_t *limbs, int count, char *out) {
    // Groups of 19 digits, from the lowest, by dividing by 10^19.
    const uint64_t base = 10000000000000000000ull;
    uint64_t groups[5];
    int group_count = 0;
    for (;;) {
        int top = count - 1;
        while (top >= 0 && limbs[top] == 0) top--;
        if (top < 0) break;
        __uint128_t remainder = 0;
        for (int i = top; i >= 0; i--) {
            __uint128_t current = (remainder << 64) | limbs[i];
            limbs[i] = (uint64_t)(current / base);
            remainder = current % base;
        }
        groups[group_count++] = (uint64_t)remainder;
    }
    if (group_count == 0) {
        out[0] = '0';
        return 1;
    }
    size_t length = format_u64(groups[group_count - 1], out);
    for (int i = group_count - 2; i >= 0; i--) {
        char digits[20];
        size_t written = format_u64(groups[i], digits);
        memset(out + length, '0', 19 - written);
        memcpy(out + length + 19 - written, digits, written);
        length += 19;
    }
    return length;
}

/// The digits of value `index` and whether it's negative.
static size_t integer_digits(ch_number_kind kind, const void *src, size_t index, char *out, int *negative) {
    *negative = 0;
#define SIGNED(type) do { \
        int64_t value = ((const type *)src)[index]; \
        if (value < 0) { *negative = 1; return format_u64((uint64_t)0 - (uint64_t)value, out); } \
        return format_u64((uint64_t)value, out); \
    } while (0)
    switch (kind) {
    case CH_I8: SIGNED(int8_t);
    case CH_I16: SIGNED(int16_t);
    case CH_I32: SIGNED(int32_t);
    case CH_I64: SIGNED(int64_t);
    case CH_U8: return format_u64(((const uint8_t *)src)[index], out);
    case CH_U16: return format_u64(((const uint16_t *)src)[index], out);
    case CH_U32: return format_u64(((const uint32_t *)src)[index], out);
    case CH_U64: return format_u64(((const uint64_t *)src)[index], out);
    case CH_I128: case CH_U128: case CH_I256: case CH_U256: {
        int count = (kind == CH_I128 || kind == CH_U128) ? 2 : 4;
        uint64_t limbs[4];
        memcpy(limbs, (const uint64_t *)src + index * (size_t)count, (size_t)count * 8);
        if ((kind == CH_I128 || kind == CH_I256) && (limbs[count - 1] >> 63)) {
            *negative = 1;
            unsigned carry = 1;
            for (int i = 0; i < count; i++) {
                limbs[i] = ~limbs[i] + carry;
                carry = carry && limbs[i] == 0;
            }
        }
        return format_wide(limbs, count, out);
    }
    default:
        out[0] = '0';
        return 1;
    }
#undef SIGNED
}

size_t ch_format_integer(ch_number_kind kind, const void *src, size_t index, char *out) {
    int negative;
    size_t length = integer_digits(kind, src, index, out + 1, &negative);
    if (negative) {
        out[0] = '-';
        return length + 1;
    }
    memmove(out, out + 1, length);
    return length;
}

size_t ch_format_decimal(ch_number_kind kind, const void *src, size_t index, int scale, char *out) {
    char digits[CH_TEXT_CAPACITY];
    int negative;
    size_t count = integer_digits(kind, src, index, digits, &negative);
    size_t at = 0;
    if (negative) out[at++] = '-';
    size_t whole = count > (size_t)scale ? count - (size_t)scale : 0;
    if (whole == 0) {
        out[at++] = '0';
    } else {
        memcpy(out + at, digits, whole);
        at += whole;
    }
    // The fraction's digits, leading zeros added, trailing ones left out.
    char fraction[CH_TEXT_CAPACITY];
    size_t fraction_count = 0;
    for (int i = 0; i < scale; i++) {
        long position = (long)count - scale + i;
        fraction[fraction_count++] = position >= 0 ? digits[position] : '0';
    }
    while (fraction_count > 0 && fraction[fraction_count - 1] == '0') fraction_count--;
    if (fraction_count > 0) {
        out[at++] = '.';
        memcpy(out + at, fraction, fraction_count);
        at += fraction_count;
    }
    // "-0" only for a zero that isn't one: a negative of all zeros can't be.
    if (negative && at == 2 && out[1] == '0') {
        out[0] = '0';
        return 1;
    }
    return at;
}

/// The civil date of a day since 1970-01-01 (Howard Hinnant's algorithm).
static void civil_from_days(int64_t days, int64_t *year, unsigned *month, unsigned *day) {
    days += 719468;
    int64_t era = (days >= 0 ? days : days - 146096) / 146097;
    unsigned day_of_era = (unsigned)(days - era * 146097);
    unsigned year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    unsigned day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    unsigned shifted_month = (5 * day_of_year + 2) / 153;
    *day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    *month = shifted_month < 10 ? shifted_month + 3 : shifted_month - 9;
    *year = (int64_t)year_of_era + era * 400 + (*month <= 2);
}

static size_t format_year(int64_t year, char *out) {
    size_t at = 0;
    if (year < 0) {
        out[at++] = '-';
        year = -year;
    }
    if (year < 10000) {
        memcpy(out + at, digit_pairs + (year / 100) * 2, 2);
        memcpy(out + at + 2, digit_pairs + (year % 100) * 2, 2);
        return at + 4;
    }
    return at + format_u64((uint64_t)year, out + at);
}

size_t ch_format_date(int64_t days, char *out) {
    int64_t year;
    unsigned month, day;
    civil_from_days(days, &year, &month, &day);
    size_t at = format_year(year, out);
    out[at] = '-';
    memcpy(out + at + 1, digit_pairs + month * 2, 2);
    out[at + 3] = '-';
    memcpy(out + at + 4, digit_pairs + day * 2, 2);
    return at + 6;
}

/// `fraction`'s `precision` digits after a point (nothing for 0).
static size_t format_fraction(int64_t fraction, int precision, char *out) {
    if (precision <= 0) return 0;
    out[0] = '.';
    for (int i = precision; i >= 1; i--) {
        out[i] = (char)('0' + fraction % 10);
        fraction /= 10;
    }
    return (size_t)precision + 1;
}

size_t ch_format_datetime(int64_t seconds, int64_t fraction, int precision, char *out) {
    int64_t days = seconds >= 0 ? seconds / 86400 : -((-seconds + 86399) / 86400);
    int64_t of_day = seconds - days * 86400;
    size_t at = ch_format_date(days, out);
    out[at] = ' ';
    memcpy(out + at + 1, digit_pairs + (of_day / 3600) * 2, 2);
    out[at + 3] = ':';
    memcpy(out + at + 4, digit_pairs + (of_day / 60 % 60) * 2, 2);
    out[at + 6] = ':';
    memcpy(out + at + 7, digit_pairs + (of_day % 60) * 2, 2);
    at += 9;
    return at + format_fraction(fraction, precision, out + at);
}

size_t ch_format_time(int64_t seconds, int64_t fraction, int precision, char *out) {
    size_t at = 0;
    if (seconds < 0 || fraction < 0) {
        out[at++] = '-';
        seconds = seconds < 0 ? -seconds : seconds;
        fraction = fraction < 0 ? -fraction : fraction;
    }
    uint64_t hours = (uint64_t)seconds / 3600;
    if (hours < 10) out[at++] = '0';
    at += format_u64(hours, out + at);
    out[at] = ':';
    memcpy(out + at + 1, digit_pairs + (seconds / 60 % 60) * 2, 2);
    out[at + 3] = ':';
    memcpy(out + at + 4, digit_pairs + (seconds % 60) * 2, 2);
    at += 6;
    return at + format_fraction(fraction, precision, out + at);
}

size_t ch_format_uuid(const uint8_t *bytes, char *out) {
    static const char hex[] = "0123456789abcdef";
    // Native writes each 8-byte half little-endian: the text reads them back to front.
    uint8_t ordered[16];
    for (int i = 0; i < 8; i++) {
        ordered[i] = bytes[7 - i];
        ordered[8 + i] = bytes[15 - i];
    }
    size_t at = 0;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out[at++] = '-';
        out[at++] = hex[ordered[i] >> 4];
        out[at++] = hex[ordered[i] & 15];
    }
    return at;
}

size_t ch_format_ipv4(uint32_t address, char *out) {
    size_t at = 0;
    for (int shift = 24; shift >= 0; shift -= 8) {
        at += format_u64((address >> shift) & 0xFF, out + at);
        if (shift > 0) out[at++] = '.';
    }
    return at;
}

size_t ch_format_ipv6(const uint8_t *bytes, char *out) {
    char text[INET6_ADDRSTRLEN];
    if (!inet_ntop(AF_INET6, bytes, text, sizeof text)) return 0;
    size_t length = strlen(text);
    memcpy(out, text, length);
    return length;
}

// MARK: Floats

size_t ch_reformat_float(const char *in, size_t count, char *out) {
    size_t at = 0, i = 0;
    if (count >= 3 && (in[count - 1] == 'f' || in[count - 1] == 'n')) {
        // inf, -inf, nan, -nan (ClickHouse: nan without a sign).
        if (in[count - 1] == 'n') { memcpy(out, "nan", 3); return 3; }
        memcpy(out, in, count);
        return count;
    }
    if (in[0] == '-') { out[at++] = '-'; i = 1; }
    // The digits and the power of ten after them: value = 0.digits × 10^point.
    char digits[40];
    int digit_count = 0, point = 0, seen_point = 0, exponent = 0;
    for (; i < count; i++) {
        char c = in[i];
        if (c == 'e' || c == 'E') {
            int sign = 1;
            i++;
            if (i < count && (in[i] == '+' || in[i] == '-')) { sign = in[i] == '-' ? -1 : 1; i++; }
            for (; i < count; i++) exponent = exponent * 10 + (in[i] - '0');
            exponent *= sign;
            break;
        }
        if (c == '.') { seen_point = 1; continue; }
        if (digit_count < 40) digits[digit_count++] = c;
        if (!seen_point) point++;
    }
    int lead = 0;
    while (lead < digit_count - 1 && digits[lead] == '0') { lead++; point--; }
    int end = digit_count;
    while (end > lead + 1 && digits[end - 1] == '0') end--;
    const char *d = digits + lead;
    int n = end - lead;
    point += exponent;
    if (n == 1 && d[0] == '0') { out[at++] = '0'; return at; }
    if (n <= point && point <= 21) {
        memcpy(out + at, d, (size_t)n); at += (size_t)n;
        memset(out + at, '0', (size_t)(point - n)); at += (size_t)(point - n);
    } else if (0 < point && point <= 21) {
        memcpy(out + at, d, (size_t)point); at += (size_t)point;
        out[at++] = '.';
        memcpy(out + at, d + point, (size_t)(n - point)); at += (size_t)(n - point);
    } else if (-6 < point && point <= 0) {
        out[at++] = '0'; out[at++] = '.';
        memset(out + at, '0', (size_t)(-point)); at += (size_t)(-point);
        memcpy(out + at, d, (size_t)n); at += (size_t)n;
    } else {
        out[at++] = d[0];
        if (n > 1) { out[at++] = '.'; memcpy(out + at, d + 1, (size_t)(n - 1)); at += (size_t)(n - 1); }
        out[at++] = 'e';
        int e = point - 1;
        if (e < 0) { out[at++] = '-'; e = -e; }
        at += format_u64((uint64_t)e, out + at);
    }
    return at;
}

// MARK: Text of many values

#define FOR_VALUES(...) do { \
        size_t at = 0; \
        for (size_t i = 0; i < count; i++) { \
            size_t index = start + i; \
            if (!(nulls && nulls[index])) { __VA_ARGS__; } \
            ends[i] = base + (uint32_t)at; \
        } \
        return at; \
    } while (0)

size_t ch_format_integers(ch_number_kind kind, const void *src, const uint8_t *nulls, size_t start, size_t count,
                          char *out, uint32_t *ends, uint32_t base) {
    switch (kind) {
    case CH_U8: FOR_VALUES(at += format_u64(((const uint8_t *)src)[index], out + at));
    case CH_U16: FOR_VALUES(at += format_u64(((const uint16_t *)src)[index], out + at));
    case CH_U32: FOR_VALUES(at += format_u64(((const uint32_t *)src)[index], out + at));
    case CH_U64: FOR_VALUES(at += format_u64(((const uint64_t *)src)[index], out + at));
    default: FOR_VALUES(at += ch_format_integer(kind, src, index, out + at));
    }
}

size_t ch_format_decimals(ch_number_kind kind, const void *src, const uint8_t *nulls, size_t start, size_t count, int scale,
                          char *out, uint32_t *ends, uint32_t base) {
    FOR_VALUES(at += ch_format_decimal(kind, src, index, scale, out + at));
}

size_t ch_format_dates(int wide, const void *src, const uint8_t *nulls, size_t start, size_t count,
                       char *out, uint32_t *ends, uint32_t base) {
    if (wide) FOR_VALUES(at += ch_format_date(((const int32_t *)src)[index], out + at));
    FOR_VALUES(at += ch_format_date(((const uint16_t *)src)[index], out + at));
}

static const int64_t powers_of_ten[19] = {
    1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000, 10000000000ll, 100000000000ll,
    1000000000000ll, 10000000000000ll, 100000000000000ll, 1000000000000000ll, 10000000000000000ll,
    100000000000000000ll, 1000000000000000000ll,
};

/// The offset at an instant: the last zone entry at or before it (the first before all).
static int32_t zone_offset(int64_t seconds, const int64_t *instants, const int32_t *offsets, size_t zone_count, size_t *hint) {
    size_t i = *hint;
    if (i + 1 < zone_count && seconds >= instants[i + 1]) {
        while (i + 1 < zone_count && seconds >= instants[i + 1]) i++;
    } else {
        while (i > 0 && seconds < instants[i]) i--;
    }
    *hint = i;
    return offsets[i];
}

size_t ch_format_datetimes(const void *src, int precision, const uint8_t *nulls, size_t start, size_t count,
                           const int64_t *instants, const int32_t *offsets, size_t zone_count,
                           char *out, uint32_t *ends, uint32_t base) {
    size_t hint = 0;
    if (precision < 0) {
        const uint32_t *values = src;
        if (zone_count == 1) {
            int64_t offset = offsets[0];
            FOR_VALUES(at += ch_format_datetime((int64_t)values[index] + offset, 0, 0, out + at));
        }
        FOR_VALUES({
            int64_t seconds = values[index];
            at += ch_format_datetime(seconds + zone_offset(seconds, instants, offsets, zone_count, &hint), 0, 0, out + at);
        });
    }
    const int64_t *ticks = src;
    int64_t scale = powers_of_ten[precision > 18 ? 18 : precision];
    FOR_VALUES({
        int64_t value = ticks[index];
        int64_t seconds = value / scale, fraction = value % scale;
        if (fraction < 0) { seconds -= 1; fraction += scale; }
        at += ch_format_datetime(seconds + zone_offset(seconds, instants, offsets, zone_count, &hint), fraction, precision, out + at);
    });
}

void ch_seconds_range(const void *src, int precision, size_t start, size_t count, int64_t *least, int64_t *most) {
    int64_t low = INT64_MAX, high = INT64_MIN;
    if (precision < 0) {
        const uint32_t *values = (const uint32_t *)src + start;
        for (size_t i = 0; i < count; i++) {
            int64_t value = values[i];
            low = value < low ? value : low;
            high = value > high ? value : high;
        }
    } else {
        const int64_t *values = (const int64_t *)src + start;
        int64_t scale = powers_of_ten[precision > 18 ? 18 : precision];
        for (size_t i = 0; i < count; i++) {
            int64_t value = values[i];
            low = value < low ? value : low;
            high = value > high ? value : high;
        }
        low = low / scale - 1;
        high = high / scale + 1;
    }
    *least = low;
    *most = high;
}

size_t ch_format_uuids(const uint8_t *src, const uint8_t *nulls, size_t start, size_t count, char *out, uint32_t *ends, uint32_t base) {
    FOR_VALUES(at += ch_format_uuid(src + index * 16, out + at));
}

size_t ch_format_ipv4s(const uint32_t *src, const uint8_t *nulls, size_t start, size_t count, char *out, uint32_t *ends, uint32_t base) {
    FOR_VALUES(at += ch_format_ipv4(src[index], out + at));
}

// MARK: Charts

void ch_range(const double *values, size_t count, double *least, double *most) {
    double low = INFINITY, high = -INFINITY;
    for (size_t i = 0; i < count; i++) {
        double value = values[i];
        // NaN compares false both ways: left out.
        low = value < low ? value : low;
        high = value > high ? value : high;
    }
    *least = low <= high ? low : NAN;
    *most = low <= high ? high : NAN;
}

int ch_is_ascending(const double *values, size_t count) {
    double last = -INFINITY;
    for (size_t i = 0; i < count; i++) {
        double value = values[i];
        if (value != value) continue;
        if (value < last) return 0;
        last = value;
    }
    return 1;
}

void ch_bucket(const double *x, const double *y, size_t count, double x0, double x1, size_t buckets,
               double *least, double *most, double *sum, uint32_t *counts) {
    if (buckets == 0) return;
    double span = x1 - x0;
    double scale = span > 0 ? (double)(buckets - 1) / span : 0;
    for (size_t i = 0; i < count; i++) {
        double px = x[i], py = y[i];
        if (px != px || py != py || px < x0 || px > x1) continue;
        size_t bucket = (size_t)((px - x0) * scale + 0.5);
        if (bucket >= buckets) bucket = buckets - 1;
        if (py < least[bucket]) least[bucket] = py;
        if (py > most[bucket]) most[bucket] = py;
        sum[bucket] += py;
        counts[bucket] += 1;
    }
}
