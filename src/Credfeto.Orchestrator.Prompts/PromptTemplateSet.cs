using System;
using System.Collections.Frozen;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Prompts;

// Each template is an embedded Templates/<name>.md: a markdownlint opt-out line, then the text a lib/prompts heredoc
// or printf prints, with its trailing newlines removed (what $(...) captures) and every value as a {{name}} placeholder
public sealed partial class PromptTemplateSet
{
    private const string LINT_MARKER = "<!-- markdownlint-disable-file -->\n";
    private const string RESOURCE_PREFIX = "Credfeto.Orchestrator.Prompts.Templates.";
    private const string RESOURCE_SUFFIX = ".md";

    private static readonly Encoding Utf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true
    );

    private readonly FrozenDictionary<string, string> _templates;

    private PromptTemplateSet(FrozenDictionary<string, string> templates)
    {
        this._templates = templates;
    }

    public IReadOnlyCollection<string> Names => this._templates.Keys;

    public static async ValueTask<PromptTemplateSet> LoadAsync(CancellationToken cancellationToken)
    {
        Assembly assembly = typeof(PromptTemplateSet).Assembly;
        Dictionary<string, string> templates = [with(StringComparer.Ordinal)];

        foreach (string resource in assembly.GetManifestResourceNames().Where(IsTemplate))
        {
            string name = resource[RESOURCE_PREFIX.Length..^RESOURCE_SUFFIX.Length];
            await using Stream stream = assembly.GetManifestResourceStream(resource)
                ?? throw new PromptException("Missing prompt template " + name);
            using StreamReader reader = new(stream: stream, encoding: Utf8, detectEncodingFromByteOrderMarks: false);
            string content = await reader.ReadToEndAsync(cancellationToken);
            templates.Add(key: name, value: Parse(name: name, content: content));
        }

        return new(templates.ToFrozenDictionary(StringComparer.Ordinal));
    }

    public string Text(string name)
    {
        return this._templates.TryGetValue(key: name, value: out string? text)
            ? text
            : throw new PromptException("Missing prompt template " + name);
    }

    public IReadOnlyList<string> Placeholders(string name)
    {
        return [.. Placeholder().Matches(this.Text(name)).Select(match => match.Groups["name"].Value)];
    }

    // One pass: a value is never itself searched for placeholders
    internal string Render(string name, IReadOnlyList<TemplateValue> values)
    {
        return Placeholder()
            .Replace(input: this.Text(name), evaluator: match =>
                Lookup(template: name, placeholder: match.Groups["name"].Value, values: values)
            );
    }

    private static string Lookup(string template, string placeholder, IReadOnlyList<TemplateValue> values)
    {
        for (int index = 0; index < values.Count; index++)
        {
            if (StringComparer.Ordinal.Equals(x: values[index].Name, y: placeholder))
            {
                return values[index].Value;
            }
        }

        throw new PromptException($"Template {template} has no value for {placeholder}");
    }

    private static bool IsTemplate(string resource)
    {
        return resource.StartsWith(value: RESOURCE_PREFIX, comparisonType: StringComparison.Ordinal)
            && resource.EndsWith(value: RESOURCE_SUFFIX, comparisonType: StringComparison.Ordinal);
    }

    private static string Parse(string name, string content)
    {
        string text = content.Replace(oldValue: "\r\n", newValue: "\n", comparisonType: StringComparison.Ordinal);

        if (!text.StartsWith(value: LINT_MARKER, comparisonType: StringComparison.Ordinal) || text[^1] != '\n')
        {
            throw new PromptException("Malformed prompt template " + name);
        }

        return text[LINT_MARKER.Length..^1];
    }

    [GeneratedRegex(
        pattern: @"\{\{(?<name>[a-z_]+)\}\}",
        options: RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture,
        matchTimeoutMilliseconds: 1000
    )]
    private static partial Regex Placeholder();
}
