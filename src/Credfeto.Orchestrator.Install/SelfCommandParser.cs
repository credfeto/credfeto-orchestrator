using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Install;

// --version | --self-test: what oneshot's self-install asks of a freshly unpacked binary before it uses it
// --capabilities: the commands the binary accepts, which oneshot reads once a run (#2095)
public static class SelfCommandParser
{
    public const string VersionFlag = "--version";

    public const string SelfTestFlag = "--self-test";

    public const string CapabilitiesFlag = "--capabilities";

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0
            && (
                StringComparer.Ordinal.Equals(x: args[0], y: VersionFlag)
                || StringComparer.Ordinal.Equals(x: args[0], y: SelfTestFlag)
                || StringComparer.Ordinal.Equals(x: args[0], y: CapabilitiesFlag)
            );
    }

    public static SelfQuery? Parse(IReadOnlyList<string> args, out string error)
    {
        if (!IsVerb(args))
        {
            error = $"expected: {VersionFlag}, {SelfTestFlag} or {CapabilitiesFlag}";

            return null;
        }

        if (args.Count != 1)
        {
            error = $"{args[0]} takes no arguments";

            return null;
        }

        error = string.Empty;

        if (StringComparer.Ordinal.Equals(x: args[0], y: VersionFlag))
        {
            return SelfQuery.VERSION;
        }

        return StringComparer.Ordinal.Equals(x: args[0], y: SelfTestFlag)
            ? SelfQuery.SELF_TEST
            : SelfQuery.CAPABILITIES;
    }
}
