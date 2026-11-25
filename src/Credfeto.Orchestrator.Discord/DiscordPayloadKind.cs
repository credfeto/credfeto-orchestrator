namespace Credfeto.Orchestrator.Discord;

// One payload builder of lib/discord each
public enum DiscordPayloadKind
{
    WORK_ITEM,
    NO_WORK,
    LOW_DISK_SPACE,
    HOST_HEALTH,
    SLOW_PULL,
    ITEM_ERROR,
    BOARD_CONVERSION_FAILED,
    SELF_UPDATE_STALE,
    PRIORITIES_UNREACHABLE,
    BLOCKED_ITEM,
    BLOCKED_ISSUE_REPLANNING,
    PR_NEEDS_APPROVAL,
    PERMISSION_DENIALS,
    RATE_LIMITED,
}
