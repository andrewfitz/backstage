#!/bin/bash
# Tests for the agent integration: hook decisions (all payload shapes) and install/uninstall
# against a throwaway HOME. Touches nothing in the real home directory.
set -u
cd "$(dirname "$0")/.."
bin=${BACKSTAGE_BIN:-.build/release/backstage}
export BACKSTAGE_HOOK=on
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
fails=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fails=1; }

echo "== hook decisions"
# expect: 2 = blocked, 0 = allowed
check() {
    local expect=$1 cmd=$2 code payload
    for shape in claude codex-cmd codex-argv grok cursor-tool cursor-shell; do
        case $shape in
            cursor-tool) payload=$(jq -n --arg c "$cmd" '{hook_event_name:"preToolUse",tool_name:"Shell",tool_input:{command:$c,working_directory:"/tmp"}}') ;;
            cursor-shell)
                # Cursor's beforeShellExecution answers in JSON on stdout, exit 0, allow or deny.
                payload=$(jq -n --arg c "$cmd" '{hook_event_name:"beforeShellExecution",command:$c,cwd:"/tmp",sandbox:false}')
                code=0
                printf '%s' "$payload" | "$bin" hook pre-tool-use > "$scratch/hook.out" 2>/dev/null || code=$?
                want=$([ "$expect" = 2 ] && echo deny || echo allow)
                got=$(jq -r .permission "$scratch/hook.out" 2>/dev/null)
                if [ "$code" != 0 ] || [ "$got" != "$want" ]; then bad "[$shape] expected $want (exit 0), got '$got' (exit $code): $cmd"; return; fi
                if [ "$expect" = 2 ] && ! jq -r .agent_message "$scratch/hook.out" | grep -q "backstage launch"; then bad "[$shape] no guidance in agent_message"; return; fi
                continue ;;
            claude)     payload=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}') ;;
            codex-cmd)  payload=$(jq -n --arg c "$cmd" '{tool_name:"exec_command",tool_input:{cmd:$c}}') ;;
            codex-argv) payload=$(jq -n --arg c "$cmd" '{tool_name:"shell",tool_input:{command:["bash","-lc",$c]}}') ;;
            grok)       payload=$(jq -n --arg c "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$c}}') ;;
        esac
        code=0
        printf '%s' "$payload" | "$bin" hook pre-tool-use 2>"$scratch/hook.err" || code=$?
        if [ "$code" != "$expect" ]; then bad "[$shape] expected $expect got $code: $cmd"; return; fi
        if [ "$expect" = 2 ] && ! grep -q "backstage launch" "$scratch/hook.err"; then bad "[$shape] no guidance in deny message"; return; fi
    done
    ok "$([ "$expect" = 2 ] && echo block || echo allow): $cmd"
}
check 2 'open -a Calculator'
check 2 'open build/MyApp.app'
check 2 'open https://example.com'
check 2 'open report.pdf'
check 2 'swift build && open .build/MyApp.app'
check 2 'cd app; ./build.sh && open -n MyApp.app --args --debug'
check 2 '/Applications/Foo.app/Contents/MacOS/Foo --flag'
check 2 '"build/Debug/My App.app/Contents/MacOS/My App" --flag'
check 2 'osascript -e "tell application \"Finder\" to activate"'
check 2 'sudo open -a Safari'
check 2 'env FOO=1 open x.app'
check 2 'bash -c "open -a Notes"'
check 2 'echo hi | xargs echo; open -g Foo.app'
check 0 'backstage launch build/MyApp.app'
check 0 'backstage show --pid 123'
check 0 'BACKSTAGE_SHOW=1 open -R build/MyApp.app'
check 0 'git commit -m "open the app on launch"'
check 0 'grep -r "open -a" docs/'
check 0 'echo "osascript activate"'
check 0 'open --help'
check 0 'ls build/MyApp.app/Contents/MacOS/'
check 0 'swift build -c release'
check 0 'xcodebuild -scheme MyApp build'
check 0 'python3 -c "import os; print(os.open)"'

# Non-shell tools and junk input fail open.
printf '%s' '{"tool_name":"Write","tool_input":{"command":"open -a X"}}' | "$bin" hook pre-tool-use && ok "non-shell tool allowed" || bad "non-shell tool"
printf 'not json' | "$bin" hook pre-tool-use && ok "garbage input fails open" || bad "garbage input"
out=$(printf '%s' '{"hook_event_name":"beforeShellExecution","command":"open -a X"}' | BACKSTAGE_HOOK=off "$bin" hook pre-tool-use)
[ "$(printf '%s' "$out" | jq -r .permission)" = allow ] && ok "BACKSTAGE_HOOK=off still answers Cursor (allow)" || bad "Cursor with BACKSTAGE_HOOK=off: $out"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"open -a X"}}' | BACKSTAGE_HOOK=off "$bin" hook pre-tool-use && ok "BACKSTAGE_HOOK=off disables" || bad "BACKSTAGE_HOOK=off"

echo "== hook in computer-use hosts (Claude / Codex desktop apps)"
# Every deny message tells a computer-use agent to put the app on the user's screen; inside a
# desktop app that has computer-use tools that advice comes first. Nothing is allowed for it.
# The host variables are set or cleared explicitly, so this passes from any session.
deny() { # deny <expected first-advice regex> <env assignments...>
    local want=$1 msg code=0; shift
    msg=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"open -a Calculator"}}' \
        | env -u CLAUDE_CODE_ENTRYPOINT -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE "$@" "$bin" hook pre-tool-use 2>&1 >/dev/null) || code=$?
    local ctx="${*:-no host env}"
    [ "$code" = 2 ] || { bad "[$ctx] open not blocked (exit $code)"; return; }
    printf '%s\n' "$msg" | grep -q 'backstage launch' || { bad "[$ctx] no launch advice"; return; }
    printf '%s\n' "$msg" | grep -q 'computer-use tools that work on the user.s screen' || { bad "[$ctx] no computer-use advice"; return; }
    printf '%s\n' "$msg" | grep -q 'backstage show --pid P' || { bad "[$ctx] no show --pid advice"; return; }
    printf '%s\n' "$msg" | sed -n 2p | grep -qE "$want" && ok "[$ctx] blocked, first advice: $want" || bad "[$ctx] first advice isn't '$want': $(printf '%s\n' "$msg" | sed -n 2p)"
}
deny 'Checking your own work'
deny 'Checking your own work' CLAUDE_CODE_ENTRYPOINT=cli
deny 'computer-use' CLAUDE_CODE_ENTRYPOINT=claude-desktop
deny 'computer-use' CLAUDE_CODE_ENTRYPOINT=claude-desktop-3p
deny 'computer-use' CLAUDE_CODE_ENTRYPOINT=local-agent
deny 'computer-use' CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_work_desktop
for c in 'backstage show Calculator' 'backstage show --pid 123' 'backstage launch Calculator'; do
    printf '%s' "$(jq -n --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}')" \
        | env CLAUDE_CODE_ENTRYPOINT=claude-desktop "$bin" hook pre-tool-use 2>/dev/null && ok "[claude-desktop] allowed: $c" || bad "[claude-desktop] blocked: $c"
done

echo "== install / uninstall (throwaway HOME)"
H="$scratch/home"
mkdir -p "$H/.claude" "$H/.codex" "$H/.grok" "$H/.cursor" "$H/.config/opencode"
echo '{"version": 1, "hooks": {"afterFileEdit": [{"command": "./hooks/format.sh"}]}}' > "$H/.cursor/hooks.json"
# Pre-existing user config that must survive untouched.
cat > "$H/.claude/settings.json" <<'JSON'
{"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/other-guard"}]}], "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
JSON
echo '{"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-me"}]}]}}' > "$H/.codex/hooks.json"
printf 'model = "grok-4"\n\n[ui]\ntheme = "dark"\n' > "$H/.grok/config.toml"

HOME=$H "$bin" install --hooks > "$H/out1.json" || bad "install failed: $(cat "$H/out1.json")"
HOME=$H "$bin" install --hooks > "$H/out2.json" || bad "second install failed"
for d in .claude .codex .grok .cursor .config/opencode; do
    [ -s "$H/$d/skills/backstage/SKILL.md" ] && ok "$d skill installed" || bad "$d skill missing"
    head -3 "$H/$d/skills/backstage/SKILL.md" | grep -q '^name: backstage' || bad "$d skill frontmatter"
done
n=$(jq '[.hooks.PreToolUse[].hooks[] | select(.command|test("backstage-managed-hook"))] | length' "$H/.claude/settings.json")
[ "$n" = 1 ] && ok "claude hook present once after 2 installs" || bad "claude hook count $n"
jq -e '.model == "opus" and (.hooks.Stop|length)==1 and ([.hooks.PreToolUse[].hooks[].command] | index("/usr/local/bin/other-guard"))' "$H/.claude/settings.json" >/dev/null \
    && ok "claude settings preserved" || bad "claude settings damaged"
n=$(jq '[.hooks.PreToolUse[] | select(.matcher|test("exec_command")) | .hooks[] | select(.command|test("backstage-managed-hook"))] | length' "$H/.codex/hooks.json")
[ "$n" = 1 ] && ok "codex hook present once" || bad "codex hook count $n"
jq -e '.hooks.PostToolUse[0].hooks[0].command == "keep-me"' "$H/.codex/hooks.json" >/dev/null && ok "codex hooks preserved" || bad "codex hooks damaged"
n=$(grep -c 'backstage-managed-hook' "$H/.grok/config.toml")
[ "$n" = 1 ] && ok "grok hook present once" || bad "grok hook count $n"
grep -q 'theme = "dark"' "$H/.grok/config.toml" && ok "grok config preserved" || bad "grok config damaged"
[ -f "$H/.claude/settings.json.backstage-bak" ] && ok "backup written" || bad "no backup"
n=$(jq '[.hooks.beforeShellExecution[] | select(.command|test(" hook pre-tool-use"))] | length' "$H/.cursor/hooks.json")
[ "$n" = 1 ] && ok "cursor hook present once" || bad "cursor hook count $n"
jq -e '.version == 1 and .hooks.afterFileEdit[0].command == "./hooks/format.sh"' "$H/.cursor/hooks.json" >/dev/null && ok "cursor hooks preserved" || bad "cursor hooks damaged"
# The installed Cursor command must work when run as Cursor would: through a shell, from ~/.cursor.
cursor_cmd=$(jq -r '.hooks.beforeShellExecution[0].command' "$H/.cursor/hooks.json")
printf '%s' "$cursor_cmd" > "$scratch/cursor-hook.sh"
printf '%s' '{"hook_event_name":"beforeShellExecution","command":"open -a Safari"}' > "$scratch/cursor-in.json"
(cd "$H/.cursor" && /bin/sh "$scratch/cursor-hook.sh" < "$scratch/cursor-in.json") | jq -e '.permission == "deny"' > /dev/null \
    && ok "the installed Cursor command denies open" || bad "installed Cursor command: $cursor_cmd"
plugin="$H/.config/opencode/plugins/backstage.js"
head -1 "$plugin" | grep -q '^// backstage-managed-plugin' && ok "opencode plugin installed" || bad "opencode plugin missing"
if command -v node > /dev/null; then
    # Run the plugin's permission hook as OpenCode would, with a stand-in context.
    cp "$plugin" "$scratch/plugin.mjs"
    cp tests/opencode-plugin-check.mjs "$scratch/check.mjs"
    r=$(node "$scratch/check.mjs" "$scratch/plugin.mjs" 2>&1)
    [ "$r" = ok ] && ok "opencode plugin denies open, allows the rest" || bad "opencode plugin: $r"
else
    echo "  skip opencode plugin run (no node)"
fi

HOME=$H "$bin" uninstall > "$H/out3.json" || bad "uninstall failed"
for d in .claude .codex .grok .cursor .config/opencode; do [ ! -e "$H/$d/skills/backstage" ] || bad "$d skill not removed"; done
[ ! -e "$plugin" ] && ok "opencode plugin removed" || bad "opencode plugin left behind"
jq -e '(.hooks.beforeShellExecution == null) and .hooks.afterFileEdit[0].command == "./hooks/format.sh"' "$H/.cursor/hooks.json" >/dev/null \
    && ok "cursor hook removed, the rest kept" || bad "cursor hooks after uninstall: $(cat "$H/.cursor/hooks.json")"
# A plugin of the user's own at that path is never overwritten or removed.
echo '// my own plugin' > "$plugin"
HOME=$H "$bin" install --opencode --hooks > /dev/null 2>&1 && bad "install overwrote a different plugin" || ok "install refuses a different plugin"
HOME=$H "$bin" uninstall --opencode > /dev/null
grep -q 'my own plugin' "$plugin" && ok "uninstall keeps a different plugin" || bad "uninstall removed a different plugin"
grep -rq 'backstage-managed-hook' "$H/.claude/settings.json" "$H/.codex/hooks.json" "$H/.grok/config.toml" && bad "hook left behind" || ok "uninstall removed skills + hooks"
jq -e '([.hooks.PreToolUse[].hooks[].command] == ["/usr/local/bin/other-guard"]) and .model == "opus"' "$H/.claude/settings.json" >/dev/null \
    && ok "claude settings intact after uninstall" || bad "claude settings after uninstall"
grep -q 'theme = "dark"' "$H/.grok/config.toml" && ok "grok config intact after uninstall" || bad "grok after uninstall"

echo "== dist skill in sync"
diff <("$bin" skill) dist/skills/backstage/SKILL.md >/dev/null && ok "dist/skills/backstage/SKILL.md matches binary" || bad "dist skill stale: run make dist"

[ $fails = 0 ] && echo "AGENT INTEGRATION TESTS PASSED" || { echo "AGENT INTEGRATION TESTS FAILED"; exit 1; }
