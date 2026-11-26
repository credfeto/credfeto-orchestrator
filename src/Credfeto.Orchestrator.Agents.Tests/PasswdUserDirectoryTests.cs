using System.IO;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Agents.Tests;

public sealed class PasswdUserDirectoryTests : TestBase
{
    private const string PASSWD = """
        root:x:0:0:root:/root:/bin/bash
        broken
        familiar:x:1002:1002::/home/familiar:/bin/bash
        familiar:x:1003:1003::/home/other:/bin/bash
        odd:x:not-a-number:1:::
        """;

    [Theory]
    [InlineData("root", 0u)]
    [InlineData("familiar", 1002u)]
    public async Task ANameInTheFileHasItsUidAsync(string name, uint expected)
    {
        Assert.Equal(expected: expected, actual: await this.LookUpAsync(name));
    }

    [Theory]
    [InlineData("nobody-here")]
    [InlineData("")]
    [InlineData("root,familiar")]
    [InlineData("odd")]
    [InlineData("broken")]
    [InlineData("x")]
    public async Task AnythingElseIsNotFoundAsync(string name)
    {
        Assert.Null(await this.LookUpAsync(name));
    }

    [Fact]
    public async Task AMissingFileFindsNoOneAsync()
    {
        using TestDirectory directory = new();
        PasswdUserDirectory users = new(Path.Combine(path1: directory.Path, path2: "passwd"));

        Assert.Null(await users.UidAsync(name: "root", cancellationToken: this.CancellationToken()));
    }

    private async Task<uint?> LookUpAsync(string name)
    {
        using TestDirectory directory = new();
        string path = Path.Combine(path1: directory.Path, path2: "passwd");
        await File.WriteAllTextAsync(path: path, contents: PASSWD + "\n", cancellationToken: this.CancellationToken());

        return await new PasswdUserDirectory(path).UidAsync(name: name, cancellationToken: this.CancellationToken());
    }
}
