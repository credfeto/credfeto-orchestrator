using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Jq.Tests;

public sealed class JqNumberTests : TestBase
{
    // Each expected value is what jq 1.8 prints for the literal
    [Theory]
    [InlineData("1E2", "1E+2")]
    [InlineData("1.0", "1.0")]
    [InlineData("-0", "-0")]
    [InlineData("-0.0", "-0.0")]
    [InlineData("1e400", "1E+400")]
    [InlineData("100000000000000000001", "100000000000000000001")]
    [InlineData("0.1e1", "1")]
    [InlineData("1.50", "1.50")]
    [InlineData("0.00", "0.00")]
    [InlineData("-3e-7", "-3E-7")]
    [InlineData("12.5e3", "1.25E+4")]
    [InlineData("0.000001", "0.000001")]
    [InlineData("0.0000001", "1E-7")]
    [InlineData("123", "123")]
    [InlineData("0", "0")]
    [InlineData("1e-2", "0.01")]
    [InlineData("0e5", "0E+5")]
    [InlineData("1.23e+2", "123")]
    [InlineData("5E-0", "5")]
    public static void LiteralsPrintInJqCanonicalForm(string literal, string expected)
    {
        Assert.Equal(expected: expected, actual: JqNumber.Canonicalise(literal));
    }
}
