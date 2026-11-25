using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class UriComponentTests : TestBase
{
    [Theory]
    [InlineData("octocat", "octocat")]
    [InlineData("AZaz09-_.~", "AZaz09-_.~")]
    [InlineData("a b&c/d+e?f", "a%20b%26c%2Fd%2Be%3Ff")]
    [InlineData("!*'()#%=", "%21%2A%27%28%29%23%25%3D")]
    [InlineData("café", "caf%C3%A9")]
    [InlineData("中🚀", "%E4%B8%AD%F0%9F%9A%80")]
    [InlineData("", "")]
    public static void TheValueIsEncodedAsJqUriEncodesIt(string value, string expected)
    {
        Assert.Equal(expected: expected, actual: UriComponent.Encode(value));
    }
}
