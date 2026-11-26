using System;

namespace Credfeto.Orchestrator.Podman;

// Picks the SessionTextLocale for the effective LC_CTYPE and LC_COLLATE names, or null for a locale the tool refuses
internal static class SessionTextLocales
{
    public static SessionTextLocale? From(string ctype, string collate)
    {
        if (IsC(ctype) && IsC(collate))
        {
            return SessionTextLocale.BYTES;
        }

        return IsAsciiSafe(ctype) && IsAsciiSafe(collate) ? SessionTextLocale.ASCII : null;
    }

    private static bool IsC(string name)
    {
        return name.Length == 0 || IsOneOf(name: name, first: "C", second: "POSIX");
    }

    private static bool IsAsciiSafe(string name)
    {
        return IsC(name) || IsOneOf(name: name, first: "C.UTF-8", second: "C.utf8") || IsEnglishUtf8(name);
    }

    // en_XX.UTF-8 or en_XX.utf8
    private static bool IsEnglishUtf8(string name)
    {
        return name.Length >= 10
            && name.StartsWith("en_", StringComparison.Ordinal)
            && char.IsAsciiLetterUpper(name[3])
            && char.IsAsciiLetterUpper(name[4])
            && IsOneOf(name: name[5..], first: ".UTF-8", second: ".utf8");
    }

    private static bool IsOneOf(string name, string first, string second)
    {
        return StringComparer.Ordinal.Equals(x: name, y: first) || StringComparer.Ordinal.Equals(x: name, y: second);
    }
}
