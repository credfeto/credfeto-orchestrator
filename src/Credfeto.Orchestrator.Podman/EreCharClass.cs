using System;

namespace Credfeto.Orchestrator.Podman;

// The bytes one ERE atom (a literal, ".", or a bracket list) matches under REG_ICASE, as glibc's regexec matches
// them for the text the tool accepts: an ASCII letter matches in either case, and a byte of 0x80 or more (C locale
// only) is no letter, digit or space, so only "." and a negated list match it. NUL never reaches the matcher.
internal sealed class EreCharClass
{
    private readonly bool[] _matches;

    private EreCharClass(bool[] matches)
    {
        this._matches = matches;
    }

    public static EreCharClass Any()
    {
        bool[] matches = new bool[256];
        Array.Fill(array: matches, value: true);

        return new(matches);
    }

    public static EreCharClass Literal(byte literal)
    {
        bool[] members = new bool[128];
        members[ShellText.ToLowerAscii(literal)] = true;

        return FromMembers(members: members, negated: false);
    }

    // members holds lower-case letters, digits and other printable ASCII only (the parser refuses upper-case
    // members), indexed by byte
    public static EreCharClass FromMembers(bool[] members, bool negated)
    {
        bool[] matches = new bool[256];

        for (int value = 0; value < matches.Length; value++)
        {
            byte folded = ShellText.ToLowerAscii((byte)value);
            bool member = folded < members.Length && members[folded];
            matches[value] = member != negated;
        }

        return new(matches);
    }

    public bool Matches(byte value)
    {
        return this._matches[value];
    }
}
