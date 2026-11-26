using System;
using System.Buffers;
using System.Text;

namespace Credfeto.Orchestrator.Agents;

// stop_ssh_agent's pkill -f pattern, "ssh-agent -a <socket>", as the extended regular expression procps compiles and
// tests, unanchored, against each process's command line (PkillText). Only sockets whose pattern is a run of literal
// characters and '.' are taken: every other ERE special character, and anything outside printable ASCII, is refused.
// A '.' matches any one character. procps renders the bytes of a command line outside printable ASCII in ways that
// depend on its version and locale (a newline reads as a space, a tab as '?', a UTF-8 character as one character or
// as its bytes), so a '.' or a space that meets one makes that place UNCERTAIN; any other literal never equals one.
// A match that reaches past byte 4095 is UNCERTAIN too: older procps versions cut the command line there, so they
// would not see it.
public sealed class PkillPattern
{
    private const string PREFIX = "ssh-agent -a ";

    private const int CUT = 4095;

    private const byte ANY = (byte)'.';

    private const byte SPACE = (byte)' ';

    private static readonly SearchValues<char> Special = SearchValues.Create("\\^$*+?()[]{}|");

    private readonly byte[] _pattern;

    private PkillPattern(byte[] pattern)
    {
        this._pattern = pattern;
    }

    public static PkillPattern ForSocket(string socket)
    {
        if (
            socket.Length == 0
            || socket.AsSpan().ContainsAny(Special)
            || socket.AsSpan().ContainsAnyExceptInRange(lowInclusive: ' ', highInclusive: '~')
        )
        {
            throw new AgentRefusedException(
                "the socket path is empty, or holds a character the tool does not match as pkill's regular expression"
            );
        }

        return new(Encoding.ASCII.GetBytes(PREFIX + socket));
    }

    public PkillMatch Match(ReadOnlySpan<byte> text)
    {
        bool uncertain = false;

        for (int start = 0; start < text.Length; start++)
        {
            PkillMatch match = this.MatchAt(text: text, start: start);

            if (match == PkillMatch.MATCH)
            {
                return PkillMatch.MATCH;
            }

            uncertain |= match == PkillMatch.UNCERTAIN;
        }

        return uncertain ? PkillMatch.UNCERTAIN : PkillMatch.NO_MATCH;
    }

    private PkillMatch MatchAt(ReadOnlySpan<byte> text, int start)
    {
        for (int offset = 0; offset < this._pattern.Length; offset++)
        {
            int index = start + offset;

            if (index >= text.Length)
            {
                return PkillMatch.NO_MATCH;
            }

            byte wanted = this._pattern[offset];
            byte actual = text[index];

            if (!IsPrintableAscii(actual))
            {
                if (wanted is ANY or SPACE)
                {
                    return PkillMatch.UNCERTAIN;
                }

                return PkillMatch.NO_MATCH;
            }

            if (wanted != ANY && wanted != actual)
            {
                return PkillMatch.NO_MATCH;
            }
        }

        return start + this._pattern.Length > CUT ? PkillMatch.UNCERTAIN : PkillMatch.MATCH;
    }

    private static bool IsPrintableAscii(byte value)
    {
        return value is >= (byte)' ' and <= (byte)'~';
    }
}
