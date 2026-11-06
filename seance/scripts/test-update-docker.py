#!/usr/bin/env python3
"""Exercise update.sh against isolated, real Compose deployments.

The candidate must already be built. Only git/gh synchronization and Compose
build are intercepted; Docker volumes, server processes, curl and SQLite remain
real. Test-created tags replace the updater's shared seance-sync tag namespace.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


def run(args, *, env=None, check=True, timeout=90):
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args[0]}\n{result.stdout}")
    return result


def read_state():
    path = Path(os.environ["HAUNTWARE_UPDATE_TEST_STATE"])
    return path, json.loads(path.read_text())


def save_state(path, state):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(path)


def test_tag(value, state):
    if value.startswith("seance-sync:"):
        return state["repository"] + ":" + value.split(":", 1)[1]
    return value


def compose_parts(args):
    index = 1
    project = None
    while index < len(args):
        if args[index] in ("-f", "--file", "--env-file", "--project-directory"):
            index += 2
        elif args[index] in ("-p", "--project-name"):
            project = args[index + 1]
            index += 2
        else:
            break
    return index, project


def endpoint(docker, compose_args, env):
    result = run([docker, *compose_args, "port", "seance-sync", "8787"], env=env)
    value = result.stdout.strip().splitlines()[0]
    if not value.startswith("127.0.0.1:"):
        raise RuntimeError(f"Test deployment is not loopback-only: {value}")
    return "http://" + value


def wait_http(curl, url, seconds):
    deadline = time.monotonic() + seconds
    last = ""
    while time.monotonic() < deadline:
        result = run([curl, "--noproxy", "*", "-fsS", "--max-time", "2", "-o", os.devnull, url], check=False)
        if result.returncode == 0:
            return
        last = result.stdout
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
    raise RuntimeError(f"Readiness deadline expired: {url}\n{last}")


def sql(docker, helper, volume, program, *, readonly=True, user="10001:10001"):
    mount = f"{volume}:/data" + (":ro" if readonly else "")
    return run([docker, "run", "--rm", "--user", user,
                "--entrypoint", "python3", "-v", mount, helper, "-c", program])


def wrapper():
    state_path, state = read_state()
    mode = os.environ["HAUNTWARE_UPDATE_TEST_WRAPPER"]
    args = sys.argv[1:]
    if mode in ("git", "gh"):
        if mode == "git" and args[:2] == ["rev-parse", "--abbrev-ref"]:
            print("main")
        elif mode == "git" and args == ["rev-parse", "HEAD"]:
            print(state["candidate_ref"] if state["synced"] else state["old_ref"])
        elif (mode == "gh" and args[:2] == ["repo", "sync"]) or (
                mode == "git" and args and args[0] == "pull"):
            shutil.copyfile(state["next_compose"], state["compose"])
            state["synced"] = True
            save_state(state_path, state)
        elif mode == "git" and args == ["checkout", "main"]:
            pass
        else:
            raise RuntimeError(f"Unexpected test-only {mode} call: {args}")
        return 0

    docker = state["docker"]
    args = [test_tag(value, state) for value in args]
    if not args or args[0] not in ("compose", "inspect", "run", "image"):
        raise RuntimeError(f"Docker operation is outside this fixture's allowlist: {args}")
    if args[0] == "image":
        if len(args) < 3 or args[1] not in ("tag", "rm"):
            raise RuntimeError(f"Image operation is outside this fixture's allowlist: {args}")
        if args[1] == "rm" and any(not tag.startswith(state["repository"] + ":") for tag in args[2:]):
            raise RuntimeError("Refusing to remove an image outside this fixture")
    if args[0] == "run":
        for index, value in enumerate(args):
            if value in ("-v", "--volume"):
                source = args[index + 1].split(":", 1)[0]
                if source.startswith("/"):
                    owned = os.path.commonpath([str(Path(source).resolve()), str(state_path.parent)]) == str(state_path.parent)
                else:
                    owned = source.startswith(state["project"] + "_") or source.startswith(state["project"] + "-preflight_")
                if not owned:
                    raise RuntimeError(f"Refusing a mount outside this fixture: {source}")
    env = os.environ.copy()
    if "SEANCE_IMAGE" in env:
        env["SEANCE_IMAGE"] = test_tag(env["SEANCE_IMAGE"], state)
    with Path(state["commands"]).open("a") as log:
        log.write(json.dumps({"args": args, "image": env.get("SEANCE_IMAGE")}) + "\n")

    if args[:2] == ["image", "tag"]:
        target = args[-1]
        if not target.startswith(state["repository"] + ":"):
            raise RuntimeError(f"Refusing a tag outside this fixture: {target}")
        state["tags"] = sorted(set(state["tags"] + [target]))
        save_state(state_path, state)

    if args and args[0] == "compose":
        command_index, project = compose_parts(args)
        command = args[command_index]
        if command not in ("version", "config", "ps", "build", "stop", "start", "create", "down", "logs", "up", "port"):
            raise RuntimeError(f"Compose operation is outside this fixture's allowlist: {command}")
        if project and project.startswith("seance-preflight-"):
            replacement = state["project"] + "-preflight"
            args[args.index(project)] = replacement
            project = replacement
        # A fetched Compose file can rename its default project. Track that
        # actual fixture-owned name too, so a failed project-pin regression
        # cannot leave the accidentally-created test deployment behind.
        project = project or json.loads(Path(state["compose"]).read_text())["name"]
        if not project.startswith(state["project"]):
            raise RuntimeError(f"Refusing a Compose project outside this fixture: {project}")
        if command != "version":
            state["projects"] = sorted(set(state["projects"] + [project]))
            save_state(state_path, state)
        if command == "build":
            target = env.get("SEANCE_IMAGE", "")
            if not target.startswith(state["repository"] + ":candidate-"):
                raise RuntimeError("Candidate build did not select a fixture-owned image tag")
            run([docker, "image", "tag", state["candidate_image"], target])
            state["tags"] = sorted(set(state["tags"] + [target]))
            save_state(state_path, state)
            return 0
        result = subprocess.run([docker, *args], env=env)
        if result.returncode:
            return result.returncode
        if (command == "start" and project == state["project"] and
                env.get("SEANCE_IMAGE", "").startswith(state["repository"] + ":candidate-") and
                state["fail_after_start"]):
            # The candidate really starts and migrates the production volume.
            # Inject only after actual readiness and a concurrent durable write.
            url = endpoint(docker, args[:command_index], env)
            wait_http(state["curl"], url + "/readyz", state["probe_seconds"])
            sql(docker, state["helper_image"], state["volume"], """
import sqlite3
db = sqlite3.connect('/data/seance.sqlite')
db.execute('CREATE TABLE updater_test_sentinel (marker TEXT PRIMARY KEY)')
db.execute('INSERT INTO updater_test_sentinel VALUES (?)', ('after-candidate-start',))
db.commit()
db.close()
""", readonly=False)
            state["sentinel_written"] = True
            save_state(state_path, state)
            print("Injected exit 42 after real candidate readiness and SQLite sentinel commit", file=sys.stderr)
            return 42
        return 0
    return subprocess.run([docker, *args], env=env).returncode


def request(curl, url, method="GET", body=None, token=None):
    args = [curl, "--noproxy", "*", "-sS", "--max-time", "10", "-X", method,
            "-w", "\n%{http_code}", url]
    if body is not None:
        args += ["-H", "content-type: application/json", "--data-binary", json.dumps(body)]
    if token is not None:
        args += ["-H", "authorization: Bearer " + token]
    output = run(args).stdout
    text, status = output.rsplit("\n", 1)
    return int(status), json.loads(text) if text else None


def database_state(docker, helper, volume, username, *, user="10001:10001"):
    program = """
import json, sqlite3
db = sqlite3.connect('file:/data/seance.sqlite?mode=ro', uri=True)
db.row_factory = sqlite3.Row
username = USERNAME
account = dict(db.execute('SELECT username, auth_verifier_hash, verifier_salt, argon_salt, argon_params FROM accounts WHERE username = ?', (username,)).fetchone())
records = [dict(row) for row in db.execute('SELECT id, updated_at, device_id, deleted, seq, hex(blob) AS blob FROM records WHERE username = ? ORDER BY id', (username,))]
columns = {table: [row[1] for row in db.execute('PRAGMA table_info(' + table + ')')] for table in ['accounts', 'tokens', 'records']}
sentinel_table = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='updater_test_sentinel'").fetchone()
sentinel = [row[0] for row in db.execute('SELECT marker FROM updater_test_sentinel')] if sentinel_table else []
print(json.dumps({'account': account, 'records': records, 'columns': columns, 'sentinel': sentinel}, sort_keys=True))
db.close()
""".replace("USERNAME", repr(username))
    return json.loads(sql(docker, helper, volume, program, user=user).stdout)


def compose_document(project, old_image):
    return {
        "name": project,
        "services": {"seance-sync": {
            "build": {"context": ".", "dockerfile": "Dockerfile"},
            "image": "${SEANCE_IMAGE:-" + old_image + "}",
            "restart": "no",
            "ports": ["127.0.0.1:${SEANCE_PUBLISH_PORT:-0}:8787"],
            "environment": {"SEANCE_BIND": "0.0.0.0", "SEANCE_PORT": "8787",
                            "SEANCE_DB_PATH": "/data/seance.sqlite", "SEANCE_OPEN_REGISTRATION": "true"},
            "volumes": ["seance-data:/data"],
        }},
        "volumes": {"seance-data": {}},
    }


def verify_migration(before, after):
    assert before["account"] == after["account"], "Account material changed during migration"
    assert before["records"] == after["records"], "Record metadata or ciphertext changed during migration"
    assert "generation" in after["columns"]["accounts"]
    assert "envelope_version" in after["columns"]["records"]
    assert "token_digest" in after["columns"]["tokens"]
    assert "session_id" in after["columns"]["tokens"]
    assert "token" not in after["columns"]["tokens"], "Plaintext-token schema survived migration"


def exercise(args, output, failed_start):
    suffix = "post-start-failure" if failed_start else "success"
    case = output / suffix
    case.mkdir(mode=0o700)
    project = "hwupdate-" + uuid.uuid4().hex[:12] + "-" + ("fail" if failed_start else "ok")
    repository = project
    seance = case / "repo" / "seance"
    compose = seance / "packages" / "seance_sync_server" / "docker-compose.yml"
    compose.parent.mkdir(parents=True)
    shutil.copyfile(Path(__file__).resolve().parents[1] / "update.sh", seance / "update.sh")
    compose.write_text(json.dumps(compose_document(project, args.old_image), indent=2))
    next_compose = case / "next-compose.json"
    next_compose.write_text(json.dumps(compose_document(project + "-renamed", args.old_image), indent=2))
    temporary = case / "tmp"
    temporary.mkdir(mode=0o700)
    bindir = case / "bin"
    bindir.mkdir()
    docker = shutil.which("docker")
    curl = shutil.which("curl")
    state = {"docker": docker, "curl": curl, "project": project, "repository": repository,
             "candidate_image": args.candidate_image, "helper_image": args.helper_image,
             "old_ref": "d8c77d50d5741bcf3244e84f85a280437e09b73a", "candidate_ref": args.candidate_ref,
             "compose": str(compose), "next_compose": str(next_compose), "synced": False,
             "commands": str(case / "docker-commands.jsonl"), "projects": [project], "tags": [],
             "probe_seconds": args.probe_seconds, "fail_after_start": failed_start,
             "sentinel_written": False, "volume": None}
    state_path = case / "state.json"
    save_state(state_path, state)
    for mode in ("git", "gh", "docker"):
        path = bindir / mode
        path.write_text("#!/usr/bin/env python3\nimport os, runpy\n"
                        f"os.environ['HAUNTWARE_UPDATE_TEST_WRAPPER'] = {mode!r}\n"
                        f"runpy.run_path({str(Path(__file__).resolve())!r}, run_name='__main__')\n")
        path.chmod(0o700)
    env = os.environ.copy()
    for key in ("COMPOSE_PROJECT_NAME", "COMPOSE_FILE", "SEANCE_IMAGE", "SEANCE_PUBLISH_PORT"):
        env.pop(key, None)
    env.update({"PATH": str(bindir) + os.pathsep + env["PATH"],
                "HAUNTWARE_UPDATE_TEST_STATE": str(state_path), "TMPDIR": str(temporary),
                "SEANCE_UPDATE_LOCK_DIR": str(temporary / "updater.lock"),
                "SEANCE_UPDATE_PROBE_SECONDS": str(args.probe_seconds),
                "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"})
    real_env = env.copy()
    real_env["PATH"] = os.environ["PATH"]
    base = ["compose", "--project-name", project, "-f", str(compose)]
    passed = False
    try:
        run([docker, *base, "up", "-d", "--no-build"], env=real_env)
        old_container = run([docker, *base, "ps", "-q", "seance-sync"], env=real_env).stdout.strip()
        details = json.loads(run([docker, "inspect", old_container]).stdout)[0]
        volume = next(mount["Name"] for mount in details["Mounts"] if mount["Destination"] == "/data")
        assert volume.startswith(project + "_"), "Fixture did not get its own named volume"
        state["volume"] = volume
        save_state(state_path, state)
        old_url = endpoint(docker, base, real_env)
        wait_http(curl, old_url + "/healthz", args.probe_seconds)
        username = "updater-" + uuid.uuid4().hex[:12]
        status, login = request(curl, old_url + "/v1/register", "POST", {
            "protocolVersion": 1, "username": username,
            "authVerifier": base64.b64encode(bytes(range(32))).decode(),
            "argonSalt": base64.b64encode(bytes(range(16))).decode(),
            "argonParams": {"memory": 19456, "iterations": 2, "parallelism": 1, "hashLength": 32},
        })
        assert status == 200, f"Old registration failed: {status} {login}"
        token = login["token"]
        status, pushed = request(curl, old_url + "/v1/records", "PUT", {
            "protocolVersion": 1, "records": [{"id": "bookmark:updater-kept", "updatedAt": 1749000000000,
            "deviceId": "old-test-device", "deleted": False, "seq": None,
            "blob": base64.b64encode(bytes(range(64))).decode()}]}, token)
        assert status == 200, f"Old record write failed: {status} {pushed}"
        before = database_state(docker, args.helper_image, volume, username)
        assert len(before["records"]) == 1, "Legacy fixture did not store its opaque record"
        (case / "before.json").write_text(json.dumps(before, indent=2))
        update_log = case / "update.log"
        # Stream to disk so even a timeout or interruption leaves diagnostics.
        with update_log.open("w") as log:
            result = subprocess.run(["bash", str(seance / "update.sh"), "main"],
                env=env, text=True, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        assert result.returncode == (42 if failed_start else 0), update_log.read_text()
        state = json.loads(state_path.read_text())
        containers = run([docker, *base, "ps", "-aq", "seance-sync"], env=real_env).stdout.strip().splitlines()
        assert len(containers) == 1, f"Expected one isolated production container: {containers}"
        current = json.loads(run([docker, "inspect", containers[0]]).stdout)[0]
        candidate_id = json.loads(run([docker, "image", "inspect", args.candidate_image]).stdout)[0]["Id"]
        assert current["Image"] == candidate_id, "Production did not use the candidate image"
        assert current["Config"]["Labels"]["com.docker.compose.project"] == project
        after = database_state(docker, args.helper_image, volume, username)
        (case / "after.json").write_text(json.dumps(after, indent=2))
        verify_migration(before, after)
        bundles = list(temporary.glob("seance-update.*"))
        if failed_start:
            assert state["sentinel_written"], "Failure did not follow real readiness and sentinel commit"
            assert current["State"]["Running"] is False, "Failed candidate was not stopped"
            assert after["sentinel"] == ["after-candidate-start"], "Recovery erased a post-start write"
            assert len(bundles) == 1, "Recovery evidence was discarded"
            evidence = dict(line.split("=", 1) for line in (bundles[0] / "update-state.txt").read_text().splitlines())
            assert evidence["phase"] == "candidate-may-have-writes"
            assert evidence["data_volume"] == volume
            assert evidence["compose_project"] == project
            assert evidence["old_image"] == details["Image"]
            assert evidence["new_commit"] == args.candidate_ref
            assert (bundles[0] / "rollback-compose.yml").is_file()
            snapshots = list(bundles[0].glob("rollback.*/seance.sqlite"))
            assert len(snapshots) == 1, "Stopped-state snapshot was not retained"
            frozen = database_state(docker, args.helper_image, str(snapshots[0].parent), username, user="0")
            assert frozen["account"] == before["account"]
            assert frozen["records"] == before["records"]
            assert not frozen["sentinel"], "Recovery snapshot was overwritten with post-start data"
            assert "token" in frozen["columns"]["tokens"], "Recovery snapshot lost its original schema"
            (case / "retained-snapshot.json").write_text(json.dumps(frozen, indent=2))
            proof = case / "retained-live-data"
            proof.mkdir(mode=0o700)
            run([docker, "run", "--rm", "--user", "0", "--entrypoint", "/bin/sh",
                 "-v", volume + ":/data:ro", "-v", str(proof) + ":/proof", args.helper_image,
                 "-ec", "cp -p /data/seance.sqlite* /proof/"])
        else:
            assert current["State"]["Running"] is True
            assert not bundles, "Successful update retained a recovery bundle"
            url = endpoint(docker, base, real_env)
            wait_http(curl, url + "/readyz", args.probe_seconds)
            status, _ = request(curl, url + "/v1/sync", token=token)
            assert status == 401, "Legacy plaintext bearer was not invalidated"
        assert not (temporary / "updater.lock").exists(), "Updater left its owned lock behind"
        passed = True
        print(f"PASS {suffix}: exact account/record bytes preserved; isolated project {project}")
    finally:
        state = json.loads(state_path.read_text())
        for owned_project in reversed(state["projects"]):
            assert owned_project.startswith(project)
            logs = run([docker, "compose", "--project-name", owned_project, "-f", str(compose), "logs", "--no-color"],
                       env=real_env, check=False)
            (case / (owned_project + ".log")).write_text(logs.stdout)
            run([docker, "compose", "--project-name", owned_project, "-f", str(compose),
                 "down", "-v", "--remove-orphans"], env=real_env, check=False)
        for tag in state["tags"]:
            assert tag.startswith(repository + ":")
            run([docker, "image", "rm", tag], check=False)
        if not passed:
            print(f"FAIL {suffix}; fixture evidence retained at {case}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-image", required=True, help="Prebuilt local candidate runtime image")
    parser.add_argument("--candidate-ref", required=True, help="Commit used to build the candidate")
    parser.add_argument("--old-image", required=True, help="Prebuilt protocol-v1 runtime image")
    parser.add_argument("--helper-image", required=True, help="Old build-stage image with Python3 and SQLite")
    parser.add_argument("--probe-seconds", type=int, default=30)
    parser.add_argument("--case", choices=["both", "success", "post-start-failure"], default="both")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    if args.probe_seconds < 1:
        parser.error("--probe-seconds must be positive")
    for executable in ("docker", "curl", "bash"):
        if shutil.which(executable) is None:
            parser.error(f"{executable} is required")
    for image in (args.old_image, args.helper_image, args.candidate_image):
        run([shutil.which("docker"), "image", "inspect", image])
    output = args.output_dir
    if output is None:
        output = Path(tempfile.mkdtemp(prefix="hauntware-update-docker-")).resolve()
    else:
        output = output.resolve()
        output.mkdir(mode=0o700)
    print(f"Fixture evidence: {output}", flush=True)
    for failed_start in (False, True):
        name = "post-start-failure" if failed_start else "success"
        if args.case in ("both", name):
            exercise(args, output, failed_start)
    print("Real Docker updater integration passed")


if __name__ == "__main__":
    if os.environ.get("HAUNTWARE_UPDATE_TEST_WRAPPER"):
        sys.exit(wrapper())
    main()
