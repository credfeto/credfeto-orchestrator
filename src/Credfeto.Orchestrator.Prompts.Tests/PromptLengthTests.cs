using System;
using System.Collections.Generic;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Prompts.Tests;

// Checked against bash's ${#s} on random byte strings; test/fixtures/prompts-parity.json pins the shell's counts
public sealed class PromptLengthTests : TestBase
{
    [Theory]
    [InlineData("41", 1)]
    [InlineData("c3a9", 1)]
    [InlineData("e28094", 1)]
    [InlineData("f09d849e", 1)]
    [InlineData("f4908080", 1)]
    [InlineData("f888808080", 1)]
    [InlineData("fc8480808080", 1)]
    [InlineData("eda080", 3)]
    [InlineData("c080", 2)]
    [InlineData("e08080", 3)]
    [InlineData("e282", 2)]
    [InlineData("e28241", 3)]
    [InlineData("ff", 1)]
    [InlineData("fe8080", 3)]
    [InlineData("", 0)]
    public static void AUtf8LocaleCountsCharactersAndEachInvalidByte(string hex, int expected)
    {
        Assert.Equal(expected: expected, actual: PromptLength.Count(text: Convert.FromHexString(hex), utf8: true));
    }

    [Theory]
    [InlineData("c3a9", 2)]
    [InlineData("fc8480808080", 6)]
    public static void AnyOtherLocaleCountsBytes(string hex, int expected)
    {
        Assert.Equal(expected: expected, actual: PromptLength.Count(text: Convert.FromHexString(hex), utf8: false));
    }

    [Theory]
    [InlineData("C.UTF-8", "", "", true)]
    [InlineData("", "en_GB.utf8", "C", true)]
    [InlineData("", "", "de_DE.UTF-8@euro", true)]
    [InlineData("C", "", "C.UTF-8", false)]
    [InlineData("", "", "en_GB", false)]
    [InlineData("", "", "POSIX", false)]
    [InlineData("", "", "", false)]
    public static void TheFirstLocaleVariableSetDecides(string all, string ctype, string lang, bool expected)
    {
        Dictionary<string, string> environment = new(StringComparer.Ordinal)
        {
            ["LC_ALL"] = all,
            ["LC_CTYPE"] = ctype,
            ["LANG"] = lang,
        };

        bool utf8 = PromptLength.IsUtf8Locale(name =>
            environment.TryGetValue(key: name, value: out string? value) ? value : null
        );

        Assert.Equal(expected: expected, actual: utf8);
    }
}
