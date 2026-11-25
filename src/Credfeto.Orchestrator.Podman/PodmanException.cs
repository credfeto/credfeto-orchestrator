using System;
using System.ComponentModel;

namespace Credfeto.Orchestrator.Podman;

[Description("podman could not be run")]
public sealed partial class PodmanException : Exception;
