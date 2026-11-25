using System.Collections.Generic;

namespace Credfeto.Orchestrator.Prompts;

// The lib/prompts helpers both CLAUDE.md variants use. Each returns what the helper prints; a caller that
// inserts it as $(...) passes it through BashText.Substitution
internal static class SharedSections
{
    public const string ISSUE = "issue";
    public const string PULL_REQUEST = "pr";

    // _board_set_cmd
    public static string BoardSetCommand(
        PromptTemplateSet templates,
        BoardSettings board,
        string itemKind,
        string itemId,
        string status
    )
    {
        if (!board.HasBoard)
        {
            return string.Empty;
        }

        return templates.Render(
            name: "BoardSetCommand",
            values:
            [
                new(Name: "repo_full", Value: board.Repository),
                new(Name: "item_kind", Value: itemKind),
                new(Name: "item_id", Value: itemId),
                new(Name: "status", Value: status),
            ]
        );
    }

    // _board_set_clause
    public static string BoardSetClause(
        PromptTemplateSet templates,
        BoardSettings board,
        string itemKind,
        string itemId,
        string status
    )
    {
        string command = BashText.Substitution(
            BoardSetCommand(templates: templates, board: board, itemKind: itemKind, itemId: itemId, status: status)
        );

        return command.Length == 0
            ? string.Empty
            : templates.Render(name: "BoardSetClause", values: [new(Name: "board_set_command", Value: command)]);
    }

    // $(_board_set_clause ...), as the heredocs insert it
    public static string Clause(
        PromptTemplateSet templates,
        BoardSettings board,
        string itemKind,
        string itemId,
        string status
    )
    {
        return BashText.Substitution(
            BoardSetClause(templates: templates, board: board, itemKind: itemKind, itemId: itemId, status: status)
        );
    }

    // _build_wf_section
    public static string WorkflowBoardSection(
        PromptTemplateSet templates,
        BoardSettings board,
        string itemKind,
        string itemId
    )
    {
        if (!board.HasBoard)
        {
            return string.Empty;
        }

        string noun = System.StringComparer.Ordinal.Equals(x: itemKind, y: ISSUE) ? "issue" : "pull request";
        string command = BashText.Substitution(
            BoardSetCommand(templates: templates, board: board, itemKind: itemKind, itemId: itemId, status: "<Status>")
        );

        return BashText.Line(
            templates.Render(
                name: "WorkflowBoardSection",
                values:
                [
                    new(Name: "statuses", Value: string.Join(separator: ", ", values: board.Statuses)),
                    new(Name: "noun", Value: noun),
                    new(Name: "board_set_command", Value: command),
                    new(Name: "repo_full", Value: board.Repository),
                    new(Name: "item_kind", Value: itemKind),
                    new(Name: "item_id", Value: itemId),
                ]
            )
        );
    }

    // _build_background_stall_warning
    public static string BackgroundStallWarning(PromptTemplateSet templates, string backgroundStall)
    {
        return BashText.IsTrue(backgroundStall)
            ? Constant(templates: templates, "BackgroundStallWarning")
            : string.Empty;
    }

    // _build_permission_denial_rule
    public static string PermissionDenialRule(
        PromptTemplateSet templates,
        BoardSettings board,
        string itemKind,
        string itemId
    )
    {
        string command = BashText.Substitution(
            BoardSetCommand(templates: templates, board: board, itemKind: itemKind, itemId: itemId, status: "<Status>")
        );
        string retry =
            command.Length == 0
                ? string.Empty
                : templates.Render(
                    name: "PermissionDenialBoardRetry",
                    values: [new(Name: "board_set_command", Value: command)]
                );

        return BashText.Line(
            templates.Render(name: "PermissionDenialRule", values: [new(Name: "board_retry", Value: retry)])
        );
    }

    // The helpers that print fixed text: _build_git_ssh_section, _build_scratch_dir_note,
    // _build_container_vs_github_note and _build_background_commands_rule
    public static string Constant(PromptTemplateSet templates, string name)
    {
        return BashText.Line(templates.Render(name: name, values: []));
    }

    // The values both CLAUDE.md variants share
    public static List<TemplateValue> Common(
        PromptTemplateSet templates,
        string itemId,
        string aiInstructions,
        string repository,
        string repositoryPath
    )
    {
        return
        [
            new(Name: "item_id", Value: itemId),
            new(Name: "ai_instructions", Value: aiInstructions),
            new(Name: "repo_full", Value: repository),
            new(Name: "repo_path", Value: repositoryPath),
            new(Name: "git_ssh", Value: BashText.Substitution(Constant(templates: templates, "GitSsh"))),
            new(
                Name: "scratch_dir_note",
                Value: BashText.Substitution(Constant(templates: templates, "ScratchDirNote"))
            ),
            new(
                Name: "container_vs_github_note",
                Value: BashText.Substitution(Constant(templates: templates, "ContainerVsGitHubNote"))
            ),
            new(
                Name: "background_commands_rule",
                Value: BashText.Substitution(Constant(templates: templates, "BackgroundCommandsRule"))
            ),
        ];
    }

    // ${precheck_block}: the pre-check section and a blank line after it, only when there is one
    public static string PrecheckBlock(string precheckSection)
    {
        return precheckSection.Length == 0 ? string.Empty : precheckSection + "\n\n";
    }
}
