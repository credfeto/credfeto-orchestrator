using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman;

// credfeto-orchestrator podman ...: answers a read-only lib/podman query by running the same podman command, or for a
// read of a Claude JSON result the same jq program, printing what the shell function prints, byte for byte, and
// exiting with the status it returns
public sealed class PodmanCommandRunner
{
    public const int Usage = 2;

    // The query cannot be answered exactly as bash would answer it, so lib/podman answers it in bash
    public const int Refused = 3;

    // podman could not be run, or the answer could not be written
    public const int Failed = 125;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator podman image-sha|image-exists --image <image>
               credfeto-orchestrator podman container-exists|container-running --name <name>
               credfeto-orchestrator podman denials-summary|denied-command-names --result <file>
               credfeto-orchestrator podman background-stall|diagnostic-refusal --ctype <locale> --collate <locale>
                   --pattern <ere>
               credfeto-orchestrator podman tool-denied-quit --ctype <locale> --collate <locale> --mention <ere>
                   --give-up <ere> --workaround <ere> --negated <ere>
               credfeto-orchestrator podman review-result-marker --ctype <locale> --collate <locale>
                   --clean-marker <line> --findings-marker <line>
               credfeto-orchestrator podman clean-review --ctype <locale> --collate <locale> --clean-marker <line>
                   --findings-marker <line> --clean <ere> --findings <ere> --negated <ere>

        Each query runs the podman command its lib/podman function runs, prints what the function prints and exits
        with the status it returns: image-sha current_agent_image_sha (the image's IMAGE_SHA_DEVELOPMENT_AGENT),
        container-exists agent_container_exists, container-running agent_container_running and image-exists
        agent_image_cached. podman's stderr is passed through. denials-summary
        (claude_result_permission_denials_summary) and denied-command-names (claude_result_denied_command_names)
        run no podman: they print what the function's jq program prints for the Claude JSON result in <file>.
        The text queries read a session's final message on stdin, sent as a here-string, and answer as their
        lib/podman function does with the patterns, markers and effective LC_CTYPE and LC_COLLATE it passes:
        background-stall claude_result_indicates_background_stall, diagnostic-refusal
        claude_result_indicates_diagnostic_refusal (past its length cap), tool-denied-quit
        claude_result_indicates_tool_denied_quit, clean-review claude_result_indicates_clean_review (past its empty
        test) and review-result-marker review_result_marker, which prints CLEAN, FINDINGS or nothing.

        Exit codes: 0 or 1 the answer (the two result reads and review-result-marker answer only with 0); 2 a usage
        error; 3 the query cannot be answered exactly as bash would (an argument or podman output that is not UTF-8,
        or output holding a NUL byte; for a result read, a file jq could read differently or would fail on; for a
        text query, a locale other than C, POSIX, C.UTF-8 or en_*.UTF-8, a message that is not ASCII outside the C
        locale, or a pattern outside the subset of POSIX extended regular expressions the tool matches), so
        lib/podman answers it; 125 podman could not be run, stdin could not be read or the answer could not be
        written.
        """;

    private readonly IPodmanQueries _queries;
    private readonly IClaudeResultQueries _results;
    private readonly Func<Stream> _input;

    public PodmanCommandRunner(IPodmanQueries queries)
        : this(queries: queries, results: new ClaudeResultQueries()) { }

    public PodmanCommandRunner(IPodmanQueries queries, IClaudeResultQueries results)
        : this(queries: queries, results: results, input: Console.OpenStandardInput) { }

    // input opens the stream a text query reads its message from (stdin)
    public PodmanCommandRunner(IPodmanQueries queries, IClaudeResultQueries results, Func<Stream> input)
    {
        this._queries = queries;
        this._results = results;
        this._input = input;
    }

    public static PodmanCommandRunner CreateDefault()
    {
        return new(new PodmanQueries(new PodmanProcessRunner()));
    }

    public ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Stream output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        if (PodmanTextCommandParser.IsQuery(args))
        {
            return this.RunTextQueryAsync(
                args: args,
                output: output,
                error: error,
                cancellationToken: cancellationToken
            );
        }

        PodmanCommand? command = PodmanCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        return WriteAnswerAsync(
            answer: async () => await this.AnswerAsync(command: command, cancellationToken: cancellationToken),
            output: output,
            error: error,
            cancellationToken: cancellationToken
        );
    }

    private ValueTask<int> RunTextQueryAsync(
        IReadOnlyList<string> args,
        Stream output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        PodmanTextCommand? command = PodmanTextCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        return WriteAnswerAsync(
            answer: async () =>
            {
                byte[] input = await this.ReadInputAsync(cancellationToken: cancellationToken);

                return ClaudeTextQueries.Answer(command: command, input: input);
            },
            output: output,
            error: error,
            cancellationToken: cancellationToken
        );
    }

    private async ValueTask<byte[]> ReadInputAsync(CancellationToken cancellationToken)
    {
        await using Stream input = this._input();
        using MemoryStream buffer = new();
        await input.CopyToAsync(destination: buffer, cancellationToken: cancellationToken);

        return buffer.ToArray();
    }

    private static async ValueTask<int> UsageAsync(
        TextWriter error,
        string problem,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
        await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

        return Usage;
    }

    private static async ValueTask<int> WriteAnswerAsync(
        Func<ValueTask<PodmanResult>> answer,
        Stream output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        try
        {
            PodmanResult result = await answer();
            await output.WriteAsync(result.Output, cancellationToken);
            await output.FlushAsync(cancellationToken);

            return result.ExitCode;
        }
        catch (PodmanRefusedException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Refused, cancellationToken);
        }
        catch (PodmanException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Failed, cancellationToken);
        }
        catch (IOException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Failed, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return Cancelled;
        }
    }

    private ValueTask<PodmanResult> AnswerAsync(PodmanCommand command, CancellationToken cancellationToken)
    {
        return command.Query switch
        {
            PodmanQuery.IMAGE_SHA => this._queries.ImageShaAsync(
                image: command.Argument,
                cancellationToken: cancellationToken
            ),
            PodmanQuery.CONTAINER_EXISTS => this._queries.ContainerExistsAsync(
                name: command.Argument,
                cancellationToken: cancellationToken
            ),
            PodmanQuery.CONTAINER_RUNNING => this._queries.ContainerRunningAsync(
                name: command.Argument,
                cancellationToken: cancellationToken
            ),
            PodmanQuery.DENIALS_SUMMARY => this._results.DenialsSummaryAsync(
                resultFile: command.Argument,
                cancellationToken: cancellationToken
            ),
            PodmanQuery.DENIED_COMMAND_NAMES => this._results.DeniedCommandNamesAsync(
                resultFile: command.Argument,
                cancellationToken: cancellationToken
            ),
            _ => this._queries.ImageExistsAsync(image: command.Argument, cancellationToken: cancellationToken),
        };
    }

    private static async ValueTask<int> FailAsync(
        TextWriter error,
        string message,
        int status,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: podman: {message}".AsMemory(), cancellationToken);

        return status;
    }
}
