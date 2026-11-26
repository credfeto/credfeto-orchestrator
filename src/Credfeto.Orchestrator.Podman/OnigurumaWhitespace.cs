namespace Credfeto.Orchestrator.Podman;

// What \s matches in jq's Oniguruma: U+0009 to U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000 to U+200A, U+2028,
// U+2029, U+202F, U+205F and U+3000 (probed with jq 1.8.2 over every code point; U+001C to U+001F, U+180E, U+200B
// and U+FEFF are not in it). None is a surrogate, so a UTF-16 unit can be tested on its own.
internal static class OnigurumaWhitespace
{
    public static bool IsSpace(char character)
    {
        return character switch
        {
            >= '\t' and <= '\r' => true,
            ' ' or '\u0085' or '\u00A0' or '\u1680' => true,
            >= '\u2000' and <= '\u200A' => true,
            '\u2028' or '\u2029' or '\u202F' or '\u205F' or '\u3000' => true,
            _ => false,
        };
    }
}
