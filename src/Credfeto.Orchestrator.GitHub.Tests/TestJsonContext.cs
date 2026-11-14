using System.Text.Json.Serialization;

namespace Credfeto.Orchestrator.GitHub.Tests;

[JsonSerializable(typeof(string))]
internal sealed partial class TestJsonContext : JsonSerializerContext;
