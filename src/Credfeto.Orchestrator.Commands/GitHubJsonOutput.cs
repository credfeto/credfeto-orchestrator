using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Commands;

// Writes the JSON reads as jq -c prints the shell version's normalised gh output: compact, keys in the shell's order,
// and text unescaped apart from what JSON requires, followed by a newline
public static class GitHubJsonOutput
{
    private static readonly JsonWriterOptions Options = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Indented = false,
    };

    // [{"number":N,"author":{"login":L},"closingIssuesReferences":[{"number":M}],"headRefName":H}]
    public static string OpenPullRequests(IReadOnlyList<OpenPullRequestReferences> pullRequests)
    {
        using MemoryStream buffer = new();

        using (Utf8JsonWriter writer = new(utf8Json: buffer, options: Options))
        {
            writer.WriteStartArray();

            foreach (OpenPullRequestReferences pullRequest in pullRequests)
            {
                WriteOpenPullRequest(writer: writer, pullRequest: pullRequest);
            }

            writer.WriteEndArray();
        }

        return Text(buffer);
    }

    private static void WriteOpenPullRequest(Utf8JsonWriter writer, OpenPullRequestReferences pullRequest)
    {
        writer.WriteStartObject();
        writer.WriteNumber(propertyName: "number", value: pullRequest.Number);
        writer.WriteStartObject("author");
        writer.WriteString(propertyName: "login", value: pullRequest.Author);
        writer.WriteEndObject();
        writer.WriteStartArray("closingIssuesReferences");

        foreach (int issue in pullRequest.ClosingIssues)
        {
            writer.WriteStartObject();
            writer.WriteNumber(propertyName: "number", value: issue);
            writer.WriteEndObject();
        }

        writer.WriteEndArray();
        writer.WriteString(propertyName: "headRefName", value: pullRequest.Head);
        writer.WriteEndObject();
    }

    // {"commits":[{"authors":[{"login":L,"email":E}]}]}
    public static string Commits(IReadOnlyList<PullRequestCommit> commits)
    {
        using MemoryStream buffer = new();

        using (Utf8JsonWriter writer = new(utf8Json: buffer, options: Options))
        {
            writer.WriteStartObject();
            writer.WriteStartArray("commits");

            foreach (PullRequestCommit commit in commits)
            {
                WriteCommit(writer: writer, commit: commit);
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return Text(buffer);
    }

    private static void WriteCommit(Utf8JsonWriter writer, PullRequestCommit commit)
    {
        writer.WriteStartObject();
        writer.WriteStartArray("authors");

        foreach (CommitAuthor author in commit.Authors)
        {
            writer.WriteStartObject();
            writer.WriteString(propertyName: "login", value: author.Login);
            writer.WriteString(propertyName: "email", value: author.Email);
            writer.WriteEndObject();
        }

        writer.WriteEndArray();
        writer.WriteEndObject();
    }

    private static string Text(MemoryStream buffer)
    {
        return Encoding.UTF8.GetString(buffer.ToArray()) + "\n";
    }
}
