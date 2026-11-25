using System.Diagnostics;

namespace Credfeto.Orchestrator.Podman;

// Argument is the image for image-sha and image-exists, and the container name for container-exists and
// container-running
[DebuggerDisplay("Query={Query}, Argument={Argument}")]
public sealed record PodmanCommand(PodmanQuery Query, string Argument);
