using System;
using System.Collections.Generic;

namespace Credfeto.Orchestrator.Install;

// --version | --self-test: what oneshot's self-install asks of a freshly unpacked binary before it uses it
public static class SelfCommandParser
{
    public const string VersionFlag = "--version";

    public const string SelfTestFlag = "--self-test";

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0
            && (
                StringComparer.Ordinal.Equals(x: args[0], y: VersionFlag)
                || StringComparer.Ordinal.Equals(x: args[0], y: SelfTestFlag)
            );
    }

    public static SelfQuery? Parse(IReadOnlyList<string> args, out string error)
    {
        if (!IsVerb(args))
        {
            error = $"expected: {VersionFlag} or {SelfTestFlag}";

            return null;
        }

        if (args.Count != 1)
        {
            error = $"{args[0]} takes no arguments";

            return null;
        }

        error = string.Empty;

        return StringComparer.Ordinal.Equals(x: args[0], y: VersionFlag) ? SelfQuery.VERSION : SelfQuery.SELF_TEST;
    }
}
