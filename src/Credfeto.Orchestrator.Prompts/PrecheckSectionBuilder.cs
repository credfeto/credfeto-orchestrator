using System;
using System.Text;

namespace Credfeto.Orchestrator.Prompts;

// build_precheck_section: kind "main" reports the default branch's baseline to an issue session, anything else the
// pull request head's results. Status pass, fail or timeout, anything else an error
internal static class PrecheckSectionBuilder
{
    public static string Build(PromptTemplateSet templates, PrecheckSectionRequest request)
    {
        StringBuilder text = new();
        bool main = StringComparer.Ordinal.Equals(x: request.Kind, y: "main");

        Print(
            templates: templates,
            text: text,
            name: main ? "PrecheckMainHeader" : "PrecheckPullRequestHeader",
            request: request
        );

        PrintStatus(templates: templates, text: text, request: request, main: main);

        if (!main)
        {
            Print(templates: templates, text: text, name: "PrecheckPullRequestFooter", request: request);
        }

        return text.ToString();
    }

    // pass, fail or timeout; anything else is a pre-check that could not run
    private static void PrintStatus(
        PromptTemplateSet templates,
        StringBuilder text,
        PrecheckSectionRequest request,
        bool main
    )
    {
        switch (request.Status)
        {
            case "pass":
                Print(
                    templates: templates,
                    text: text,
                    name: main ? "PrecheckMainPass" : "PrecheckPullRequestPass",
                    request: request
                );

                break;
            case "fail":
                Print(
                    templates: templates,
                    text: text,
                    name: main ? "PrecheckMainFail" : "PrecheckPullRequestFail",
                    request: request
                );
                PrintSummary(templates: templates, text: text, request: request);

                if (main)
                {
                    Print(templates: templates, text: text, name: "PrecheckMainFailAfter", request: request);
                }

                break;
            case "timeout":
                Print(
                    templates: templates,
                    text: text,
                    name: main ? "PrecheckMainTimeout" : "PrecheckPullRequestTimeout",
                    request: request
                );
                PrintSummary(templates: templates, text: text, request: request);

                break;
            default:
                Print(
                    templates: templates,
                    text: text,
                    name: main ? "PrecheckMainError" : "PrecheckPullRequestError",
                    request: request
                );

                break;
        }
    }

    // The summary block, then the log line when there is a log
    private static void PrintSummary(PromptTemplateSet templates, StringBuilder text, PrecheckSectionRequest request)
    {
        text.Append(BashText.Line(request.Summary));

        if (request.ContainerLog.Length != 0)
        {
            Print(templates: templates, text: text, name: "PrecheckLog", request: request);
        }
    }

    private static void Print(
        PromptTemplateSet templates,
        StringBuilder text,
        string name,
        PrecheckSectionRequest request
    )
    {
        text.Append(
            BashText.Line(
                templates.Render(
                    name: name,
                    values:
                    [
                        new(Name: "sha", Value: request.Sha),
                        new(Name: "error", Value: request.Error),
                        new(Name: "container_log", Value: request.ContainerLog),
                        new(Name: "precheck_summary_lines", Value: request.SummaryLines),
                        new(Name: "precheck_timeout_minutes", Value: request.TimeoutMinutes),
                    ]
                )
            )
        );
    }
}
