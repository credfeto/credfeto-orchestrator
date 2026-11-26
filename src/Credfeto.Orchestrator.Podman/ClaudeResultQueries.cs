using System;
using System.IO;
using System.Security;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Podman;

// Reads the Claude JSON result file and runs the jq program of the lib/podman function over it. A file that cannot be
// read is refused rather than failed: jq would print nothing and exit 2, which only bash reproduces exactly.
public sealed class ClaudeResultQueries : IClaudeResultQueries
{
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public async ValueTask<PodmanResult> DenialsSummaryAsync(string resultFile, CancellationToken cancellationToken)
    {
        JqValue? result = await ReadAsync(resultFile: resultFile, cancellationToken: cancellationToken);

        return Answer(PermissionDenialsSummary.Render(result));
    }

    public async ValueTask<PodmanResult> DeniedCommandNamesAsync(string resultFile, CancellationToken cancellationToken)
    {
        JqValue? result = await ReadAsync(resultFile: resultFile, cancellationToken: cancellationToken);

        return Answer(DeniedCommandNames.Read(result));
    }

    private static async ValueTask<JqValue?> ReadAsync(string resultFile, CancellationToken cancellationToken)
    {
        if (
            resultFile.Contains('\uFFFD', StringComparison.Ordinal)
            || resultFile.Contains('\0', StringComparison.Ordinal)
        )
        {
            throw new PodmanRefusedException(
                "the result file name is not valid UTF-8, so the tool cannot open the file bash would"
            );
        }

        byte[] json;

        try
        {
            json = await File.ReadAllBytesAsync(path: resultFile, cancellationToken: cancellationToken);
        }
        catch (Exception exception)
            when (exception
                    is IOException
                        or UnauthorizedAccessException
                        or SecurityException
                        or ArgumentException
                        or NotSupportedException
            )
        {
            throw new PodmanRefusedException(
                message: "cannot read the result file: " + exception.Message,
                innerException: exception
            );
        }

        return ClaudeResultJson.Parse(json);
    }

    private static PodmanResult Answer(string output)
    {
        if (output.Contains('\0', StringComparison.Ordinal))
        {
            throw new PodmanRefusedException("jq would print a NUL byte, which bash drops from what it captures");
        }

        return new(ExitCode: 0, Output: Utf8.GetBytes(output));
    }
}
