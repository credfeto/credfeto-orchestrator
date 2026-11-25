using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Podman;

// The read-only lib/podman queries: each result is what the shell function prints and the status it returns
public interface IPodmanQueries
{
    // current_agent_image_sha, for the image ORCHESTRATOR_IMAGE names
    ValueTask<PodmanResult> ImageShaAsync(string image, CancellationToken cancellationToken);

    // agent_container_exists
    ValueTask<PodmanResult> ContainerExistsAsync(string name, CancellationToken cancellationToken);

    // agent_container_running
    ValueTask<PodmanResult> ContainerRunningAsync(string name, CancellationToken cancellationToken);

    // agent_image_cached
    ValueTask<PodmanResult> ImageExistsAsync(string image, CancellationToken cancellationToken);
}
