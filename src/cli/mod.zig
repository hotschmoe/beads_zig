//! CLI command implementations for beads_zig.
//!
//! This module handles argument parsing and dispatches to the appropriate
//! command handlers (create, list, show, update, close, sync, etc.).
//!
//! All commands support --json output for machine-readable responses.

const std = @import("std");

pub const args = @import("args.zig");
pub const common = @import("common.zig");
pub const init = @import("init.zig");
pub const create = @import("create.zig");
pub const list = @import("list.zig");
pub const show = @import("show.zig");
pub const update = @import("update.zig");
pub const close = @import("close.zig");
pub const delete = @import("delete.zig");
pub const ready = @import("ready.zig");
pub const dep = @import("dep.zig");
pub const graph = @import("graph.zig");
pub const epic = @import("epic.zig");
pub const sync = @import("sync.zig");
pub const batch = @import("batch.zig");
pub const search = @import("search.zig");
pub const stale = @import("stale.zig");
pub const count = @import("count.zig");
pub const defer_cmd = @import("defer.zig");
pub const label = @import("label.zig");
pub const comments = @import("comments.zig");
pub const history = @import("history.zig");
pub const audit = @import("audit.zig");
pub const changelog = @import("changelog.zig");
pub const info = @import("info.zig");
pub const stats = @import("stats.zig");
pub const doctor = @import("doctor.zig");
pub const config = @import("config.zig");
pub const orphans = @import("orphans.zig");
pub const lint = @import("lint.zig");
pub const version = @import("version.zig");
pub const schema = @import("schema.zig");
pub const completions = @import("completions.zig");
pub const metrics_cmd = @import("metrics.zig");
pub const help = @import("help.zig");
pub const query = @import("query.zig");
pub const upgrade = @import("upgrade.zig");
pub const where = @import("where.zig");

pub const ArgParser = args.ArgParser;
pub const ParseResult = args.ParseResult;
pub const ParseError = args.ParseError;
pub const GlobalOptions = args.GlobalOptions;
pub const Command = args.Command;
pub const InitArgs = args.InitArgs;
pub const CreateArgs = args.CreateArgs;
pub const QuickArgs = args.QuickArgs;

pub const InitError = init.InitError;
pub const InitResult = init.InitResult;
pub const runInit = init.run;

pub const CreateError = create.CreateError;
pub const CreateResult = create.CreateResult;
pub const runCreate = create.run;
pub const runQuick = create.runQuick;

pub const ListError = list.ListError;
pub const ListResult = list.ListResult;
pub const runList = list.run;

pub const ShowError = show.ShowError;
pub const ShowResult = show.ShowResult;
pub const runShow = show.run;

pub const UpdateError = update.UpdateError;
pub const UpdateResult = update.UpdateResult;
pub const runUpdate = update.run;

pub const CloseError = close.CloseError;
pub const CloseResult = close.CloseResult;
pub const runClose = close.run;
pub const runReopen = close.runReopen;

pub const DeleteError = delete.DeleteError;
pub const DeleteResult = delete.DeleteResult;
pub const runDelete = delete.run;

pub const ReadyError = ready.ReadyError;
pub const ReadyResult = ready.ReadyResult;
pub const runReady = ready.run;
pub const runBlocked = ready.runBlocked;

pub const DepError = dep.DepError;
pub const DepResult = dep.DepResult;
pub const runDep = dep.run;

pub const GraphError = graph.GraphError;
pub const GraphResult = graph.GraphResult;
pub const runGraph = graph.run;

pub const EpicError = epic.EpicError;
pub const EpicResult = epic.EpicResult;
pub const runEpic = epic.run;

pub const SyncError = sync.SyncError;
pub const SyncResult = sync.SyncResult;
pub const runSync = sync.run;

pub const backup = @import("backup.zig");
pub const BackupError = backup.BackupError;
pub const BackupResult = backup.BackupResult;
pub const runBackup = backup.run;
pub const BackupArgs = args.BackupArgs;

pub const BatchError = batch.BatchError;
pub const BatchResult = batch.BatchResult;
pub const ImportResult = batch.ImportResult;
pub const runAddBatch = batch.runAddBatch;
pub const runImportCmd = batch.runImport;

pub const AddBatchArgs = args.AddBatchArgs;
pub const BatchFormat = args.BatchFormat;
pub const ImportArgs = args.ImportArgs;
pub const EpicArgs = args.EpicArgs;
pub const SortField = args.SortField;

pub const SearchError = search.SearchError;
pub const SearchResult = search.SearchResult;
pub const runSearch = search.run;

pub const runStale = stale.run;

pub const runCount = count.run;

pub const runDefer = defer_cmd.run;
pub const runUndefer = defer_cmd.runUndefer;

pub const LabelError = label.LabelError;
pub const LabelResult = label.LabelResult;
pub const runLabel = label.run;

pub const CommentsError = comments.CommentsError;
pub const CommentsResult = comments.CommentsResult;
pub const runComments = comments.run;

pub const HistoryError = history.HistoryError;
pub const HistoryResult = history.HistoryResult;
pub const runHistory = history.run;

pub const AuditError = audit.AuditError;
pub const AuditResult = audit.AuditResult;
pub const runAudit = audit.run;
pub const AuditArgs = args.AuditArgs;
pub const AuditSubcommand = args.AuditSubcommand;

pub const ChangelogError = changelog.ChangelogError;
pub const ChangelogResult = changelog.ChangelogResult;
pub const runChangelog = changelog.run;
pub const ChangelogArgs = args.ChangelogArgs;

pub const InfoError = info.InfoError;
pub const InfoResult = info.InfoResult;
pub const runInfo = info.run;

pub const StatsError = stats.StatsError;
pub const StatsResult = stats.StatsResult;
pub const runStats = stats.run;
pub const StatsArgs = args.StatsArgs;

pub const DoctorError = doctor.DoctorError;
pub const DoctorResult = doctor.DoctorResult;
pub const runDoctor = doctor.run;

pub const ConfigError = config.ConfigError;
pub const ConfigResult = config.ConfigResult;
pub const runConfig = config.run;

pub const OrphansError = orphans.OrphansError;
pub const OrphansResult = orphans.OrphansResult;
pub const runOrphans = orphans.run;

pub const LintError = lint.LintError;
pub const LintResult = lint.LintResult;
pub const runLint = lint.run;

pub const OrphansArgs = args.OrphansArgs;
pub const LintArgs = args.LintArgs;

pub const VersionError = version.VersionError;
pub const VersionResult = version.VersionResult;
pub const runVersion = version.run;
pub const VERSION = version.VERSION;

pub const SchemaError = schema.SchemaError;
pub const SchemaResult = schema.SchemaResult;
pub const runSchema = schema.run;

pub const CompletionsError = completions.CompletionsError;
pub const CompletionsResult = completions.CompletionsResult;
pub const runCompletions = completions.run;
pub const Shell = completions.Shell;

pub const MetricsError = metrics_cmd.MetricsError;
pub const MetricsResult = metrics_cmd.MetricsResult;
pub const runMetrics = metrics_cmd.run;
pub const MetricsArgs = args.MetricsArgs;

pub const HelpError = help.HelpError;
pub const HelpResult = help.HelpResult;
pub const runHelp = help.run;

pub const QueryError = query.QueryError;
pub const QueryResult = query.QueryResult;
pub const runQuery = query.run;
pub const QueryArgs = args.QueryArgs;

pub const UpgradeError = upgrade.UpgradeError;
pub const UpgradeResult = upgrade.UpgradeResult;
pub const runUpgrade = upgrade.run;
pub const UpgradeArgs = args.UpgradeArgs;

pub const WhereError = where.WhereError;
pub const WhereResult = where.WhereResult;
pub const runWhere = where.run;

test {
    std.testing.refAllDecls(@This());
}
