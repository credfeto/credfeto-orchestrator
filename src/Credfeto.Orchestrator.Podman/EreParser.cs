using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Podman;

// Parses the subset of POSIX extended regular expressions (glibc regcomp with REG_EXTENDED | REG_ICASE, as bash's
// [[ =~ ]] under nocasematch compiles them) whose meaning is the same in every locale the tool accepts: printable
// ASCII literals, ".", "^", "$", groups, "|", "*", "+", "?", "{m}", "{m,}" and "{m,n}" up to 255, a backslash before
// one of .[]()*+?{}|^$\, and bracket lists of printable ASCII with lower-case letter or digit ranges and a "-" only at
// either end. Anything else is refused, rather than guessed at: back-references, GNU escapes (\w, \b, \<), character
// classes, equivalence classes and collating symbols, upper-case letters in a list (range and case folding rules
// there differ by locale), an empty pattern, alternative or group, an unmatched parenthesis, a repeat with nothing
// before it or after an anchor, and stacked repeats.
internal sealed class EreParser
{
    public const int MaximumRepeat = 255;

    private const string ESCAPABLE = ".[]()*+?{}|^$\\";

    private readonly string _pattern;
    private int _position;

    private EreParser(string pattern)
    {
        this._pattern = pattern;
    }

    public static EreNode Parse(string pattern)
    {
        if (pattern.AsSpan().ContainsAnyExceptInRange(lowInclusive: ' ', highInclusive: '~'))
        {
            throw Refuse("a pattern holds a character that is not printable ASCII");
        }

        EreParser parser = new(pattern);
        EreNode node = parser.ParseAlternation();

        if (parser._position != pattern.Length)
        {
            throw Refuse("a pattern has an unmatched )");
        }

        return node;
    }

    private bool AtEnd => this._position >= this._pattern.Length;

    private char Peek => this._pattern[this._position];

    private EreNode ParseAlternation()
    {
        List<EreNode> branches = [this.ParseSequence()];

        while (!this.AtEnd && this.Peek == '|')
        {
            this._position++;
            branches.Add(this.ParseSequence());
        }

        return branches.Count == 1 ? branches[0] : EreNode.Alternation(branches);
    }

    private EreNode ParseSequence()
    {
        List<EreNode> items = [];

        while (!this.AtEnd && this.Peek is not '|' and not ')')
        {
            items.Add(this.ParseRepeat(this.ParseAtom()));
        }

        if (items.Count == 0)
        {
            throw Refuse("a pattern has an empty alternative or group");
        }

        return items.Count == 1 ? items[0] : EreNode.Sequence(items);
    }

    private EreNode ParseAtom()
    {
        char character = this._pattern[this._position++];

        return character switch
        {
            '(' => this.ParseGroup(),
            '.' => EreNode.Atom(EreCharClass.Any()),
            '^' => EreNode.Anchor(begin: true),
            '$' => EreNode.Anchor(begin: false),
            '[' => this.ParseBracket(),
            '\\' => this.ParseEscape(),
            '*' or '+' or '?' or '{' => throw Refuse("a pattern has a repeat with nothing before it"),
            '}' or ']' => throw Refuse("a pattern has an unescaped " + character),
            _ => EreNode.Atom(EreCharClass.Literal((byte)character)),
        };
    }

    private EreNode ParseGroup()
    {
        EreNode node = this.ParseAlternation();

        if (this.AtEnd || this.Peek != ')')
        {
            throw Refuse("a pattern has an unmatched (");
        }

        this._position++;

        return node;
    }

    private EreNode ParseEscape()
    {
        if (this.AtEnd || !ESCAPABLE.Contains(this.Peek, StringComparison.Ordinal))
        {
            throw Refuse("a pattern has a backslash escape glibc gives its own meaning to");
        }

        return EreNode.Atom(EreCharClass.Literal((byte)this._pattern[this._position++]));
    }

    private EreNode ParseRepeat(EreNode item)
    {
        if (this.AtEnd || this.Peek is not ('*' or '+' or '?' or '{'))
        {
            return item;
        }

        if (item.Kind == EreNodeKind.ANCHOR)
        {
            throw Refuse("a pattern repeats an anchor");
        }

        char repeat = this._pattern[this._position++];
        (int minimum, int maximum) = repeat switch
        {
            '*' => (0, EreNode.Unbounded),
            '+' => (1, EreNode.Unbounded),
            '?' => (0, 1),
            _ => this.ParseInterval(),
        };

        if (!this.AtEnd && this.Peek is '*' or '+' or '?' or '{')
        {
            throw Refuse("a pattern has stacked repeats");
        }

        return EreNode.Repeat(item: item, minimum: minimum, maximum: maximum);
    }

    // After the "{": m}, m,} or m,n}
    private (int Minimum, int Maximum) ParseInterval()
    {
        int minimum = this.ParseCount();

        if (this.TryConsume(','))
        {
            if (this.TryConsume('}'))
            {
                return (minimum, EreNode.Unbounded);
            }

            int maximum = this.ParseCount();
            this.ExpectIntervalEnd();

            return maximum < minimum
                ? throw Refuse("a pattern has an interval {m,n} with n below m")
                : (minimum, maximum);
        }

        this.ExpectIntervalEnd();

        return (minimum, minimum);
    }

    private int ParseCount()
    {
        int start = this._position;
        int count = 0;

        while (!this.AtEnd && char.IsAsciiDigit(this.Peek) && this._position - start < 3)
        {
            count = count * 10 + (this._pattern[this._position++] - '0');
        }

        if (this._position == start || count > MaximumRepeat || !this.AtEnd && char.IsAsciiDigit(this.Peek))
        {
            throw Refuse("a pattern has an interval that is not {m}, {m,} or {m,n} with counts up to 255");
        }

        return count;
    }

    private void ExpectIntervalEnd()
    {
        if (!this.TryConsume('}'))
        {
            throw Refuse("a pattern has an interval that is not {m}, {m,} or {m,n} with counts up to 255");
        }
    }

    private bool TryConsume(char expected)
    {
        if (this.AtEnd || this._pattern[this._position] != expected)
        {
            return false;
        }

        this._position++;

        return true;
    }

    private EreNode ParseBracket()
    {
        bool negated = !this.AtEnd && this.Peek == '^';

        if (negated)
        {
            this._position++;
        }

        bool[] members = new bool[128];
        bool first = true;

        while (true)
        {
            if (this.AtEnd)
            {
                throw Refuse("a pattern has an unterminated bracket list");
            }

            char member = this._pattern[this._position++];

            if (member == ']' && !first)
            {
                return EreNode.Atom(EreCharClass.FromMembers(members: members, negated: negated));
            }

            this.AddBracketMember(member: member, first: first, members: members);
            first = false;
        }
    }

    private void AddBracketMember(char member, bool first, bool[] members)
    {
        if (member is '[' or '\\' or >= 'A' and <= 'Z')
        {
            throw Refuse("a pattern has a bracket list holding [, a backslash or an upper-case letter");
        }

        bool rangeFollows =
            this._position + 1 < this._pattern.Length
            && this._pattern[this._position] == '-'
            && this._pattern[this._position + 1] != ']';

        if (!rangeFollows)
        {
            if (member == '-' && !first && (this.AtEnd || this.Peek != ']'))
            {
                throw Refuse("a pattern has a bracket list with a - that is not at either end");
            }

            members[member] = true;

            return;
        }

        char last = this._pattern[this._position + 1];
        this._position += 2;

        if (!IsRangeOf(first: member, last: last))
        {
            throw Refuse("a pattern has a bracket range that is not within a to z or 0 to 9");
        }

        for (char value = member; value <= last; value++)
        {
            members[value] = true;
        }
    }

    private static bool IsRangeOf(char first, char last)
    {
        bool letters = first is >= 'a' and <= 'z' && last is >= 'a' and <= 'z';
        bool digits = char.IsAsciiDigit(first) && char.IsAsciiDigit(last);

        return (letters || digits) && first <= last;
    }

    private static PodmanRefusedException Refuse(string message)
    {
        return new(message);
    }
}
