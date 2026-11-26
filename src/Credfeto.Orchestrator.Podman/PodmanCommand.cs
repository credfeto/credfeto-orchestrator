using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman;

// Argument is the image for image-sha and image-exists, the container name for container-exists and
// container-running, and the Claude JSON result file for denials-summary and denied-command-names
[DebuggerDisplay("Query={Query}, Argument={Argument}")]
public sealed record PodmanCommand(PodmanQuery Query, string Argument);
