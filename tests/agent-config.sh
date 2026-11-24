#!/bin/bash
set -eu
python3 - "${1:-.build/release/backstage}" <<'PY'
import json, os, shlex, subprocess, sys, tempfile
from pathlib import Path

with tempfile.TemporaryDirectory(prefix="backstage agent's home ") as temp:
    home = Path(temp)
    cli = home / "backstage\twith\nspaces"
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
        skill = root / "skills/backstage/SKILL.md"
        os.utime(skill, (1000000000, 1000000000))
        run("install", "--" + agent, "--hooks")
        assert skill.stat().st_mtime == 1000000000
        doc = json.loads(config.read_text())
        groups = doc["hooks"]["PreToolUse"]
        assert len(groups) == 2
        command = groups.pop()["hooks"][0]
        assert shlex.split(command["command"], comments=True) == [str(cli), "hook", "pre-tool-use"]
        groups[0]["hooks"].append(command)
        config.write_text(json.dumps(doc))
        extra = skill.with_name("user.txt")
        extra.write_text("user file")
        run("uninstall", "--" + agent)
        assert not skill.exists() and extra.exists()
        assert json.loads(config.read_text()) == original
        skill.write_text("custom skill")
        run("install", "--" + agent, "--hooks", success=False)
        run("uninstall", "--" + agent)
        assert skill.read_text() == "custom skill"
        old_skill = b"---\r\nname: backstage\r\n---\r\nOld skill\r\n"
        skill.write_bytes(old_skill)
        run("install", "--" + agent)
        assert skill.with_suffix(".md.backstage-bak").read_bytes() == old_skill

    grok = home / ".grok/config.toml"
    grok.parent.mkdir()
    for original in [b'', b'name = "local"\n', b'name = "local"',
                     b'name = "local"\r\n', b'name = "local"\r\nother = true']:
        grok.write_bytes(original)
        run("install", "--grok", "--hooks")
        installed = grok.read_bytes()
        run("install", "--grok", "--hooks")
        assert grok.read_bytes() == installed
        assert grok.read_text().count("[[hooks.PreToolUse]]") == 1
        command = next(line.split(" = ", 1)[1] for line in grok.read_text().splitlines()
                       if line.lstrip().startswith("command = "))
        assert shlex.split(json.loads(command), comments=True) == [str(cli), "hook", "pre-tool-use"]
        run("uninstall", "--grok")
        assert grok.read_bytes() == original
print("Agent install and uninstall checks passed")
PY
