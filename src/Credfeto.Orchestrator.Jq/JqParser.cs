using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;

namespace Credfeto.Orchestrator.Jq;

public static class JqParser
{
    private const int MAXIMUM_DEPTH = 10000;

    private static readonly JsonDocumentOptions Options = new()
    {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = MAXIMUM_DEPTH,
    };

    private static readonly JsonReaderOptions StreamOptions = new()
    {
        AllowMultipleValues = true,
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = MAXIMUM_DEPTH,
    };

    public static JqValue Parse(string json)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(json: json, options: Options);

            return Convert(document.RootElement);
        }
        catch (JsonException exception)
        {
            throw new JqException(message: "Invalid JSON: " + exception.Message, innerException: exception);
        }
        catch (InvalidOperationException exception)
        {
            throw new JqException(message: "Invalid JSON string: " + exception.Message, innerException: exception);
        }
    }

    // jq reads its input as a stream of JSON texts, one after another: Values holds every text read
    // before the first one that is not JSON, and Complete is false when there was such a text
    public static JqInput ParseStream(string json)
    {
        List<JqValue> values = [];
        Utf8JsonReader reader = new(jsonData: Encoding.UTF8.GetBytes(json), options: StreamOptions);

        try
        {
            while (reader.Read())
            {
                using JsonDocument document = JsonDocument.ParseValue(ref reader);
                values.Add(Convert(document.RootElement));
            }

            return new(Values: values, Complete: true);
        }
        catch (JsonException)
        {
            return new(Values: values, Complete: false);
        }
        catch (InvalidOperationException)
        {
            return new(Values: values, Complete: false);
        }
        catch (JqException)
        {
            return new(Values: values, Complete: false);
        }
    }

    private static JqValue Convert(in JsonElement element)
    {
        return element.ValueKind switch
        {
            JsonValueKind.Null => JqValue.Null,
            JsonValueKind.False => JqValue.False,
            JsonValueKind.True => JqValue.True,
            JsonValueKind.Number => JqValue.FromNumberLiteral(element.GetRawText()),
            JsonValueKind.String => JqValue.FromString(ReadString(element)),
            JsonValueKind.Array => ConvertArray(element),
            _ => ConvertObject(element),
        };
    }

    private static string ReadString(in JsonElement element)
    {
        try
        {
            return element.GetString() ?? string.Empty;
        }
        catch (InvalidOperationException)
        {
            return JqStringDecoder.Decode(element.GetRawText());
        }
    }

    private static JqValue ConvertArray(in JsonElement element)
    {
        List<JqValue> items = [with(capacity: element.GetArrayLength())];

        foreach (JsonElement item in element.EnumerateArray())
        {
            items.Add(Convert(item));
        }

        return JqValue.FromArray(items);
    }

    private static JqValue ConvertObject(in JsonElement element)
    {
        // A repeated key keeps its first position and takes its last value, as jq does
        List<JqProperty> properties = [];
        Dictionary<string, int> positions = [with(StringComparer.Ordinal)];

        foreach (JsonProperty property in element.EnumerateObject())
        {
            JqValue value = Convert(property.Value);

            if (positions.TryGetValue(key: property.Name, value: out int position))
            {
                properties[position] = new(Name: property.Name, Value: value);
            }
            else
            {
                positions.Add(key: property.Name, value: properties.Count);
                properties.Add(new(Name: property.Name, Value: value));
            }
        }

        return JqValue.FromObject(properties);
    }
}
