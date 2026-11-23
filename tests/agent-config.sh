#!/bin/bash
set -eu
python3 - "${1:-.build/release/backstage}" <<'PY'
import json, os, shlex, subprocess, sys, tempfile
from pathlib import Path

with tempfile.TemporaryDirectory(prefix="backstage agent's home ") as temp:
    home = Path(temp)
    cli = home / "backstage"
    cli.symlink_to(Path(sys.argv[1]).resolve())
    env = dict(os.environ, HOME=temp, BACKSTAGE_HOOK="on")

    def run(*args, success=True):
        p = subprocess.run([cli, *args], env=env, capture_output=True)
        assert (p.returncode == 0) == success, (args, p)

    for agent, filename in [("claude", "settings.json"), ("codex", "hooks.json")]:
        root = home / ("." + agent)
        root.mkdir()
        config = root / filename
        config.write_text('{"hooks":false}')
        run("install", "--" + agent, "--hooks", success=False)
        assert config.read_text() == '{"hooks":false}'
        unrelated = {"type": "command", "command": "echo backstage hook pre-tool-use"}
        original = {"other": 1, "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [unrelated]}]}}
        config.write_text(json.dumps(original))
        run("install", "--" + agent, "--hooks")
        run("install", "--" + agent, "--hooks")
        doc = json.loads(config.read_text())
        groups = doc["hooks"]["PreToolUse"]
        assert len(groups) == 2
        command = groups.pop()["hooks"][0]
        assert shlex.split(command["command"], comments=True) == [str(cli), "hook", "pre-tool-use"]
        groups[0]["hooks"].append(command)
        config.write_text(json.dumps(doc))
        skill = root / "skills/backstage/SKILL.md"
        extra = skill.with_name("user.txt")
        extra.write_text("user file")
        run("uninstall", "--" + agent)
        assert not skill.exists() and extra.exists()
        assert json.loads(config.read_text()) == original
        skill.write_text("custom skill")
        run("install", "--" + agent, "--hooks", success=False)
        run("uninstall", "--" + agent)
        assert skill.read_text() == "custom skill"

    grok = home / ".grok/config.toml"
    grok.parent.mkdir()
    grok.write_text('name = "local"\n')
    run("install", "--grok", "--hooks")
    run("install", "--grok", "--hooks")
    assert grok.read_text().count("[[hooks.PreToolUse]]") == 1
    run("uninstall", "--grok")
    assert grok.read_text() == 'name = "local"\n'
print("Agent install and uninstall checks passed")
PY
