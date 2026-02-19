import 'dart:io';

class SpiderRuntimeScriptLocator {
  SpiderRuntimeScriptLocator._();

  static final Map<String, String> _files = <String, String>{
    'run_js.sh': r'''#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/runner.py" --mode js
''',
    'run_py.sh': r'''#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/runner.py" --mode py
''',
    'run_jar.sh': r'''#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/runner.py" --mode jar
''',
    'runner.py': '''#!/usr/bin/env python3
import argparse
import json
import sys
import traceback


def flush(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=True) + "\\n")
    sys.stdout.flush()


def handle(method, params, mode):
    if method == "init":
        return {"ok": True, "mode": mode}
    if method == "homeContent":
        return {"list": []}
    if method == "categoryContent":
        return {"list": [], "page": 1, "pagecount": 1}
    if method == "detailContent":
        ids = params.get("ids") or []
        return {"list": [{"vod_id": ids[0] if ids else "", "vod_name": "Mock Video"}]}
    if method == "searchContent":
        key = params.get("key", "")
        return {"list": [{"vod_id": f"search:{key}", "vod_name": key or "Mock Search"}]}
    if method == "playerContent":
        video_id = params.get("id", "")
        if str(video_id).startswith("quark://"):
            return {
                "parse": 0,
                "jx": 0,
                "url": "",
                "playUrl": "",
                "header": json.dumps({"User-Agent": "MaPlayer-Spider"}),
                "quark": {
                    "shareRef": str(video_id).replace("quark://", "", 1),
                    "name": "Mock Quark File"
                }
            }
        return {
            "parse": 0,
            "jx": 0,
            "url": video_id,
            "playUrl": "",
            "header": json.dumps({"User-Agent": "MaPlayer-Spider"})
        }
    if method == "proxyLocal":
        return [200, "application/json", "{}"]
    if method == "destroy":
        return {"ok": True}
    raise ValueError(f"Unsupported method: {method}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="js")
    args = parser.parse_args()

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
            req_id = req.get("id")
            method = req.get("method", "")
            params = req.get("params") or {}
            result = handle(method, params, args.mode)
            flush({"id": req_id, "result": result})
        except Exception as exc:
            req_id = None
            try:
                req_id = json.loads(raw).get("id")
            except Exception:
                pass
            flush({
                "id": req_id,
                "error": {
                    "code": "RUNTIME_ERROR",
                    "message": str(exc),
                    "detail": traceback.format_exc(limit=1).strip()
                }
            })


if __name__ == "__main__":
    main()
''',
  };

  static Directory? _cachedDir;

  static Future<String> ensureScript(String name) async {
    final content = _files[name];
    if (content == null) {
      throw ArgumentError('Unknown runtime script: $name');
    }
    final dir = await _ensureRuntimeDir();
    final file = File('${dir.path}/$name');
    if (!file.existsSync() || await file.readAsString() != content) {
      await file.writeAsString(content, flush: true);
      await _chmod(file.path);
    }
    return file.path;
  }

  static Future<Directory> _ensureRuntimeDir() async {
    final cached = _cachedDir;
    if (cached != null) return cached;
    final dir = Directory(
      '${Directory.systemTemp.path}/ma_player_spider_runtime',
    );
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _cachedDir = dir;
    return dir;
  }

  static Future<void> _chmod(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', <String>['755', path]);
    } catch (_) {}
  }
}
