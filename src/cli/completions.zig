//! Shell completions command for beads_zig.
//!
//! Generates shell completion scripts for bash, zsh, fish, and powershell.

const std = @import("std");
const output = @import("../output/mod.zig");
const args = @import("args.zig");

pub const Shell = args.Shell;
pub const CompletionsArgs = args.CompletionsArgs;

pub const CompletionsError = error{
    WriteError,
};

pub const CompletionsResult = struct {
    shell: Shell,
};

pub fn run(cmd_args: CompletionsArgs, global: anytype, allocator: std.mem.Allocator) CompletionsError!CompletionsResult {
    var out = output.Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    const script = switch (cmd_args.shell) {
        .bash => BASH_COMPLETIONS,
        .zsh => ZSH_COMPLETIONS,
        .fish => FISH_COMPLETIONS,
        .powershell => POWERSHELL_COMPLETIONS,
    };

    out.raw(script) catch return CompletionsError.WriteError;

    return .{
        .shell = cmd_args.shell,
    };
}

const BASH_COMPLETIONS =
    \\# bash completion for bz (beads_zig)
    \\# Add to ~/.bashrc: source <(bz completions bash)
    \\
    \\_bz_completions() {
    \\    local cur prev words cword
    \\    _init_completion || return
    \\
    \\    local commands="init create q show update close reopen delete list ready blocked search stale count dep label comments history audit sync config info stats doctor version schema completions"
    \\
    \\    if [[ $cword -eq 1 ]]; then
    \\        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    \\        return
    \\    fi
    \\
    \\    case ${words[1]} in
    \\        show|update|close|reopen|delete|comments|history)
    \\            # Complete with issue IDs
    \\            local ids=$(bz list --quiet 2>/dev/null)
    \\            COMPREPLY=($(compgen -W "$ids" -- "$cur"))
    \\            ;;
    \\        dep)
    \\            if [[ $cword -eq 2 ]]; then
    \\                COMPREPLY=($(compgen -W "add remove list tree cycles" -- "$cur"))
    \\            else
    \\                local ids=$(bz list --quiet 2>/dev/null)
    \\                COMPREPLY=($(compgen -W "$ids" -- "$cur"))
    \\            fi
    \\            ;;
    \\        label)
    \\            if [[ $cword -eq 2 ]]; then
    \\                COMPREPLY=($(compgen -W "add remove list list-all" -- "$cur"))
    \\            else
    \\                local ids=$(bz list --quiet 2>/dev/null)
    \\                COMPREPLY=($(compgen -W "$ids" -- "$cur"))
    \\            fi
    \\            ;;
    \\        comments)
    \\            if [[ $cword -eq 2 ]]; then
    \\                COMPREPLY=($(compgen -W "add list" -- "$cur"))
    \\            fi
    \\            ;;
    \\        config)
    \\            if [[ $cword -eq 2 ]]; then
    \\                COMPREPLY=($(compgen -W "get set list" -- "$cur"))
    \\            fi
    \\            ;;
    \\        sync)
    \\            COMPREPLY=($(compgen -W "--flush-only --import-only" -- "$cur"))
    \\            ;;
    \\        completions)
    \\            COMPREPLY=($(compgen -W "bash zsh fish powershell" -- "$cur"))
    \\            ;;
    \\        create)
    \\            COMPREPLY=($(compgen -W "--priority --type --assignee --label --dep" -- "$cur"))
    \\            ;;
    \\        list)
    \\            COMPREPLY=($(compgen -W "--status --priority --type --assignee --label --all --limit --offset" -- "$cur"))
    \\            ;;
    \\        stale)
    \\            COMPREPLY=($(compgen -W "--days" -- "$cur"))
    \\            ;;
    \\        count)
    \\            COMPREPLY=($(compgen -W "--by" -- "$cur"))
    \\            ;;
    \\    esac
    \\}
    \\
    \\complete -F _bz_completions bz
    \\
;

const ZSH_COMPLETIONS =
    \\#compdef bz
    \\# zsh completion for bz (beads_zig)
    \\# Add to ~/.zshrc: source <(bz completions zsh)
    \\
    \\_bz() {
    \\    local -a commands
    \\    commands=(
    \\        'init:Initialize beads workspace'
    \\        'create:Create new issue'
    \\        'q:Quick capture (create + print ID only)'
    \\        'show:Display issue details'
    \\        'update:Update issue fields'
    \\        'close:Close an issue'
    \\        'reopen:Reopen a closed issue'
    \\        'delete:Soft delete (tombstone)'
    \\        'list:List issues with filters'
    \\        'ready:Show actionable issues (unblocked)'
    \\        'blocked:Show blocked issues'
    \\        'search:Full-text search'
    \\        'stale:Find stale issues'
    \\        'count:Count issues'
    \\        'dep:Manage dependencies'
    \\        'label:Manage labels'
    \\        'comments:Manage comments'
    \\        'history:Show issue history'
    \\        'audit:View audit log'
    \\        'sync:Sync with JSONL file'
    \\        'config:Manage configuration'
    \\        'info:Workspace info'
    \\        'stats:Project statistics'
    \\        'doctor:Run diagnostics'
    \\        'version:Show version'
    \\        'schema:View storage schema'
    \\        'completions:Generate shell completions'
    \\    )
    \\
    \\    local -a global_opts
    \\    global_opts=(
    \\        '--json[Output in JSON format]'
    \\        '--toon[Output in TOON format]'
    \\        '-q[Quiet mode]'
    \\        '--quiet[Quiet mode]'
    \\        '-v[Verbose mode]'
    \\        '--verbose[Verbose mode]'
    \\        '--no-color[Disable colors]'
    \\        '--data[Override .beads/ directory]:directory:_files -/'
    \\    )
    \\
    \\    _arguments -C \
    \\        $global_opts \
    \\        '1:command:->command' \
    \\        '*::arg:->args'
    \\
    \\    case $state in
    \\        command)
    \\            _describe 'command' commands
    \\            ;;
    \\        args)
    \\            case ${words[1]} in
    \\                show|update|close|reopen|delete)
    \\                    _arguments '1:issue ID:($(bz list --quiet 2>/dev/null))'
    \\                    ;;
    \\                dep)
    \\                    local -a dep_cmds
    \\                    dep_cmds=('add:Add dependency' 'remove:Remove dependency' 'list:List dependencies' 'tree:Show dependency tree' 'cycles:Detect cycles')
    \\                    _describe 'subcommand' dep_cmds
    \\                    ;;
    \\                label)
    \\                    local -a label_cmds
    \\                    label_cmds=('add:Add labels' 'remove:Remove labels' 'list:List labels' 'list-all:List all labels')
    \\                    _describe 'subcommand' label_cmds
    \\                    ;;
    \\                completions)
    \\                    local -a shells
    \\                    shells=('bash' 'zsh' 'fish' 'powershell')
    \\                    _describe 'shell' shells
    \\                    ;;
    \\            esac
    \\            ;;
    \\    esac
    \\}
    \\
    \\_bz
    \\
;

const FISH_COMPLETIONS =
    \\# fish completion for bz (beads_zig)
    \\# Add to ~/.config/fish/completions/bz.fish
    \\
    \\set -l commands init create q show update close reopen delete list ready blocked search stale count dep label comments history audit sync config info stats doctor version schema completions
    \\
    \\complete -c bz -f
    \\
    \\# Main commands
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a init -d "Initialize workspace"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a create -d "Create issue"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a q -d "Quick capture"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a show -d "Show issue"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a update -d "Update issue"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a close -d "Close issue"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a reopen -d "Reopen issue"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a delete -d "Delete issue"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a list -d "List issues"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a ready -d "Show ready issues"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a blocked -d "Show blocked issues"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a search -d "Search issues"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a stale -d "Find stale issues"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a count -d "Count issues"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a dep -d "Manage dependencies"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a label -d "Manage labels"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a comments -d "Manage comments"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a history -d "Issue history"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a audit -d "Audit log"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a sync -d "Sync JSONL"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a config -d "Configuration"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a info -d "Workspace info"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a stats -d "Statistics"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a doctor -d "Diagnostics"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a version -d "Show version"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a schema -d "Storage schema"
    \\complete -c bz -n "not __fish_seen_subcommand_from $commands" -a completions -d "Shell completions"
    \\
    \\# Global options
    \\complete -c bz -l json -d "JSON output"
    \\complete -c bz -l toon -d "TOON output"
    \\complete -c bz -s q -l quiet -d "Quiet mode"
    \\complete -c bz -s v -l verbose -d "Verbose mode"
    \\complete -c bz -l no-color -d "Disable colors"
    \\complete -c bz -l data -x -d "Override .beads/ directory"
    \\
    \\# Subcommands
    \\complete -c bz -n "__fish_seen_subcommand_from dep" -a "add remove list tree cycles"
    \\complete -c bz -n "__fish_seen_subcommand_from label" -a "add remove list list-all"
    \\complete -c bz -n "__fish_seen_subcommand_from comments" -a "add list"
    \\complete -c bz -n "__fish_seen_subcommand_from config" -a "get set list"
    \\complete -c bz -n "__fish_seen_subcommand_from completions" -a "bash zsh fish powershell"
    \\
;

const POWERSHELL_COMPLETIONS =
    \\# PowerShell completion for bz (beads_zig)
    \\# Add to $PROFILE: . (bz completions powershell)
    \\
    \\Register-ArgumentCompleter -Native -CommandName bz -ScriptBlock {
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\
    \\    $commands = @(
    \\        @{Name='init'; Description='Initialize workspace'}
    \\        @{Name='create'; Description='Create issue'}
    \\        @{Name='q'; Description='Quick capture'}
    \\        @{Name='show'; Description='Show issue'}
    \\        @{Name='update'; Description='Update issue'}
    \\        @{Name='close'; Description='Close issue'}
    \\        @{Name='reopen'; Description='Reopen issue'}
    \\        @{Name='delete'; Description='Delete issue'}
    \\        @{Name='list'; Description='List issues'}
    \\        @{Name='ready'; Description='Show ready issues'}
    \\        @{Name='blocked'; Description='Show blocked issues'}
    \\        @{Name='search'; Description='Search issues'}
    \\        @{Name='stale'; Description='Find stale issues'}
    \\        @{Name='count'; Description='Count issues'}
    \\        @{Name='dep'; Description='Manage dependencies'}
    \\        @{Name='label'; Description='Manage labels'}
    \\        @{Name='comments'; Description='Manage comments'}
    \\        @{Name='history'; Description='Issue history'}
    \\        @{Name='audit'; Description='Audit log'}
    \\        @{Name='sync'; Description='Sync JSONL'}
    \\        @{Name='config'; Description='Configuration'}
    \\        @{Name='info'; Description='Workspace info'}
    \\        @{Name='stats'; Description='Statistics'}
    \\        @{Name='doctor'; Description='Diagnostics'}
    \\        @{Name='version'; Description='Show version'}
    \\        @{Name='schema'; Description='Storage schema'}
    \\        @{Name='completions'; Description='Shell completions'}
    \\    )
    \\
    \\    $commands | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object {
    \\        [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Description)
    \\    }
    \\}
    \\
;

// --- Tests ---

test "BASH_COMPLETIONS is valid script" {
    try std.testing.expect(BASH_COMPLETIONS.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, BASH_COMPLETIONS, "_bz_completions") != null);
}

test "ZSH_COMPLETIONS is valid script" {
    try std.testing.expect(ZSH_COMPLETIONS.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ZSH_COMPLETIONS, "#compdef bz") != null);
}

test "FISH_COMPLETIONS is valid script" {
    try std.testing.expect(FISH_COMPLETIONS.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, FISH_COMPLETIONS, "complete -c bz") != null);
}

test "POWERSHELL_COMPLETIONS is valid script" {
    try std.testing.expect(POWERSHELL_COMPLETIONS.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, POWERSHELL_COMPLETIONS, "Register-ArgumentCompleter") != null);
}

test "run generates bash completions" {
    const allocator = std.testing.allocator;

    const result = try run(.{ .shell = .bash }, .{
        .json = false,
        .toon = false,
        .quiet = true,
        .no_color = true,
    }, allocator);

    try std.testing.expectEqual(Shell.bash, result.shell);
}

test "run generates zsh completions" {
    const allocator = std.testing.allocator;

    const result = try run(.{ .shell = .zsh }, .{
        .json = false,
        .toon = false,
        .quiet = true,
        .no_color = true,
    }, allocator);

    try std.testing.expectEqual(Shell.zsh, result.shell);
}

test "run generates fish completions" {
    const allocator = std.testing.allocator;

    const result = try run(.{ .shell = .fish }, .{
        .json = false,
        .toon = false,
        .quiet = true,
        .no_color = true,
    }, allocator);

    try std.testing.expectEqual(Shell.fish, result.shell);
}

test "run generates powershell completions" {
    const allocator = std.testing.allocator;

    const result = try run(.{ .shell = .powershell }, .{
        .json = false,
        .toon = false,
        .quiet = true,
        .no_color = true,
    }, allocator);

    try std.testing.expectEqual(Shell.powershell, result.shell);
}
