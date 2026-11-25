using Credfeto.Orchestrator.Jq;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Discovery.Tests;

public sealed class PriorityFilterTests : TestBase
{
    [Fact]
    public static void OpenAndDraftItemsNotOnHoldAreKeptInFeedOrder()
    {
        string? items = PriorityFilter.Filter(
            """{"priorities":[{"id":3,"status":"Open","isOnHold":false},{"id":4,"status":"Closed","isOnHold":false},{"id":2,"status":"Draft","isOnHold":false},{"id":5,"status":"Open","isOnHold":true}]}"""
        );

        Assert.Equal(
            expected: """[{"id":3,"status":"Open","isOnHold":false},{"id":2,"status":"Draft","isOnHold":false}]""",
            actual: items
        );
    }

    [Theory]
    [InlineData("")]
    [InlineData(" \n\t\r")]
    public static void ABodyWithoutAJsonValuePrintsNothing(string body)
    {
        Assert.Null(PriorityFilter.Filter(body));
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{}")]
    [InlineData("[]")]
    [InlineData("""{"priorities":"x"}""")]
    [InlineData("""{"priorities":[1]}""")]
    [InlineData("""{"priorities":[]} {"priorities":[]}""")]
    public static void ABodyJqCannotFilterFails(string body)
    {
        Assert.Throws<JqException>(() => PriorityFilter.Filter(body));
    }
}
