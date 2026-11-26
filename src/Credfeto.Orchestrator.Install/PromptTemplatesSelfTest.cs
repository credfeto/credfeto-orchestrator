using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Prompts;

namespace Credfeto.Orchestrator.Install;

// The prompt templates are embedded resources: a build or trim that lost them would only show when a prompt is built
public sealed class PromptTemplatesSelfTest : ISelfTestCheck
{
    public string Name => "prompt templates";

    public async ValueTask RunAsync(CancellationToken cancellationToken)
    {
        PromptTemplateSet templates;

        try
        {
            templates = await PromptTemplateSet.LoadAsync(cancellationToken);
        }
        catch (PromptException exception)
        {
            throw new SelfTestFailedException(message: "loading: " + exception.Message, innerException: exception);
        }

        if (templates.Names.Count == 0)
        {
            throw new SelfTestFailedException("no prompt templates are embedded");
        }

        foreach (string name in templates.Names)
        {
            if (templates.Text(name).Length == 0)
            {
                throw new SelfTestFailedException($"prompt template {name} is empty");
            }
        }
    }
}
