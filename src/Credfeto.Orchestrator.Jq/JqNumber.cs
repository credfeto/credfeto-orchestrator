using System;
using System.Globalization;
using System.Text;

namespace Credfeto.Orchestrator.Jq;

// jq 1.7+ keeps a number's literal and prints it in decNumber's to-scientific-string form, so
// 1.50 stays "1.50" but 1E2 prints as "1E+2" and 0.1e1 as "1".
public static class JqNumber
{
    private const int PLAIN_NOTATION_MINIMUM_ADJUSTED_EXPONENT = -6;

    public static string Canonicalise(string literal)
    {
        ReadOnlySpan<char> text = literal.AsSpan();
        bool negative = !text.IsEmpty && text[0] == '-';

        if (negative)
        {
            text = text[1..];
        }

        int exponentMarker = text.IndexOfAny('e', 'E');
        ReadOnlySpan<char> mantissa = exponentMarker < 0 ? text : text[..exponentMarker];
        long exponent =
            exponentMarker < 0
                ? 0
                : long.Parse(
                    s: text[(exponentMarker + 1)..],
                    style: NumberStyles.AllowLeadingSign,
                    provider: CultureInfo.InvariantCulture
                );

        int point = mantissa.IndexOf('.');
        string digits;

        if (point < 0)
        {
            digits = mantissa.ToString();
        }
        else
        {
            digits = string.Concat(mantissa[..point], mantissa[(point + 1)..]);
            exponent -= mantissa.Length - point - 1;
        }

        digits = digits.TrimStart('0');

        if (digits.Length == 0)
        {
            digits = "0";
        }

        string magnitude = Format(digits: digits, exponent: exponent);

        return negative ? "-" + magnitude : magnitude;
    }

    private static string Format(string digits, long exponent)
    {
        long adjusted = exponent + digits.Length - 1;

        if (exponent <= 0 && adjusted >= PLAIN_NOTATION_MINIMUM_ADJUSTED_EXPONENT)
        {
            return FormatPlain(digits: digits, exponent: exponent);
        }

        StringBuilder builder = new();
        builder.Append(digits[0]);

        if (digits.Length > 1)
        {
            builder.Append('.').Append(digits.AsSpan(1));
        }

        builder
            .Append('E')
            .Append(adjusted >= 0 ? '+' : '-')
            .Append(Math.Abs(adjusted).ToString(CultureInfo.InvariantCulture));

        return builder.ToString();
    }

    private static string FormatPlain(string digits, long exponent)
    {
        if (exponent == 0)
        {
            return digits;
        }

        long integerDigits = digits.Length + exponent;

        if (integerDigits > 0)
        {
            int split = (int)integerDigits;

            return string.Concat(digits.AsSpan(0, split), ".", digits.AsSpan(split));
        }

        return string.Concat("0.", new string(c: '0', count: (int)-integerDigits), digits);
    }
}
