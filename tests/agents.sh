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
    for shape in claude codex-cmd codex-argv grok; do
        case $shape in
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
mkdir -p "$H/.claude" "$H/.codex" "$H/.grok"
# Pre-existing user config that must survive untouched.
cat > "$H/.claude/settings.json" <<'JSON'
{"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/other-guard"}]}], "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
JSON
echo '{"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-me"}]}]}}' > "$H/.codex/hooks.json"
printf 'model = "grok-4"\n\n[ui]\ntheme = "dark"\n' > "$H/.grok/config.toml"

HOME=$H "$bin" install --hooks > "$H/out1.json" || bad "install failed: $(cat "$H/out1.json")"
HOME=$H "$bin" install --hooks > "$H/out2.json" || bad "second install failed"
for a in claude codex grok; do
    [ -s "$H/.$a/skills/backstage/SKILL.md" ] && ok "$a skill installed" || bad "$a skill missing"
    head -3 "$H/.$a/skills/backstage/SKILL.md" | grep -q '^name: backstage' || bad "$a skill frontmatter"
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

HOME=$H "$bin" uninstall > "$H/out3.json" || bad "uninstall failed"
for a in claude codex grok; do [ ! -e "$H/.$a/skills/backstage" ] || bad "$a skill not removed"; done
grep -rq 'backstage-managed-hook' "$H/.claude/settings.json" "$H/.codex/hooks.json" "$H/.grok/config.toml" && bad "hook left behind" || ok "uninstall removed skills + hooks"
jq -e '([.hooks.PreToolUse[].hooks[].command] == ["/usr/local/bin/other-guard"]) and .model == "opus"' "$H/.claude/settings.json" >/dev/null \
    && ok "claude settings intact after uninstall" || bad "claude settings after uninstall"
grep -q 'theme = "dark"' "$H/.grok/config.toml" && ok "grok config intact after uninstall" || bad "grok after uninstall"

echo "== dist skill in sync"
diff <("$bin" skill) dist/skills/backstage/SKILL.md >/dev/null && ok "dist/skills/backstage/SKILL.md matches binary" || bad "dist skill stale: run make dist"

[ $fails = 0 ] && echo "AGENT INTEGRATION TESTS PASSED" || { echo "AGENT INTEGRATION TESTS FAILED"; exit 1; }
