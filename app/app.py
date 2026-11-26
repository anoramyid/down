import hmac, json, logging, math, os, re, threading, time, uuid, urllib.error, urllib.parse, urllib.request
from logging.handlers import TimedRotatingFileHandler
from flask import Flask, Response, abort, jsonify, request, send_file, send_from_directory

ROOT = os.path.realpath(os.environ.get("ROOT", "/data"))
browser_setting = os.environ.get("ENABLE_BROWSER", "1").strip().lower()
if browser_setting not in ("0", "1", "false", "true"):
    raise ValueError("ENABLE_BROWSER harus bernilai 0 atau 1")
ENABLE_BROWSER = browser_setting in ("1", "true")
BROWSER_DIR = os.path.realpath(os.environ.get("BROWSER_DOWNLOAD_DIR", os.path.join(ROOT, "browser")))
if BROWSER_DIR == ROOT or not BROWSER_DIR.startswith(ROOT + os.sep):
    raise ValueError("BROWSER_DOWNLOAD_DIR harus berada di dalam ROOT")
CONF = os.environ.get("CONFIG_DIR", "/config")
os.makedirs(CONF, exist_ok=True)
DB = os.path.join(CONF, "tasks.json")
DOWNLOADS_DB = os.path.join(CONF, "downloads.json")
SETTINGS_DB = os.path.join(CONF, "settings.json")
APP_USER = os.environ.get("APP_USER", "")
APP_PASS = os.environ.get("APP_PASS", "")
AUTH_FILE = os.environ.get("AUTH_FILE", "")
if AUTH_FILE:
    with open(AUTH_FILE, encoding="utf-8") as f:
        auth_data = json.load(f)
    if (not isinstance(auth_data, dict) or not isinstance(auth_data.get("APP_USER"), str)
            or not isinstance(auth_data.get("APP_PASS"), str)):
        raise ValueError("AUTH_FILE harus berisi APP_USER dan APP_PASS")
    APP_USER, APP_PASS = auth_data["APP_USER"], auth_data["APP_PASS"]
PORT = int(os.environ.get("PORT", "9191"))
RETENTION_SECONDS = 30 * 24 * 60 * 60
try:
    DOWNLOAD_LIMIT_MIB = float(os.environ.get("DOWNLOAD_LIMIT_MIB", "5"))
except ValueError as e:
    raise ValueError("DOWNLOAD_LIMIT_MIB harus antara 0 dan 1024 MiB/s") from e
if not math.isfinite(DOWNLOAD_LIMIT_MIB) or not 0 <= DOWNLOAD_LIMIT_MIB <= 1024:
    raise ValueError("DOWNLOAD_LIMIT_MIB harus antara 0 dan 1024 MiB/s")
log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
if log_level not in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"):
    log_level = "INFO"
logger = logging.getLogger("drive_tasks")
logger.setLevel(log_level)
logger.propagate = False
handler = TimedRotatingFileHandler(
    os.path.join(CONF, "drive-tasks.log"), when="midnight", backupCount=30, encoding="utf-8", utc=True
)
handler.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(handler)
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/126.0.0.0 Safari/537.36")
MODES = ["std", "browser", "tls"]  # standar -> header browser -> tiru TLS Chrome

app = Flask(__name__, static_folder="static")
lock, sem = threading.Lock(), threading.Semaphore(int(os.environ.get("MAX_PARALLEL", "2")))
tasks, downloads, cancels = {}, {}, set()
if ENABLE_BROWSER:
    os.makedirs(BROWSER_DIR, exist_ok=True)


class RateLimiter:
    def __init__(self, limit_mib):
        self.condition = threading.Condition()
        self.rate = self.capacity = self.tokens = 0
        self.updated = time.monotonic()
        self.set_limit(limit_mib)

    def set_limit(self, limit_mib):
        with self.condition:
            self.rate = limit_mib * 1048576
            self.capacity = min(max(self.rate, 64 * 1024), 256 * 1024) if self.rate else 0
            self.tokens = 0
            self.updated = time.monotonic()
            self.condition.notify_all()

    def limit_mib(self):
        with self.condition:
            return self.rate / 1048576

    def acquire(self, amount, task_id):
        remaining = amount
        while remaining > 0:
            if task_id in cancels:
                raise InterruptedError
            with self.condition:
                if not self.rate:
                    return
                now = time.monotonic()
                self.tokens = min(self.capacity, self.tokens + (now - self.updated) * self.rate)
                self.updated = now
                taken = min(remaining, int(self.tokens))
                if taken:
                    self.tokens -= taken
                    remaining -= taken
                else:
                    self.condition.wait(timeout=min((remaining - self.tokens) / self.rate, 0.1))


rate_limiter = RateLimiter(DOWNLOAD_LIMIT_MIB)


def log_event(event, level=logging.INFO, **fields):
    entry = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event, **fields}
    logger.log(level, json.dumps(entry, ensure_ascii=False, separators=(",", ":")))


def write_json(path, value):
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(value, f)
    os.replace(temp, path)


def register_download(path, size):
    with lock:
        downloads[path] = {"path": path, "created": time.time(), "size": size}
        write_json(DOWNLOADS_DB, downloads)


class Blocked(Exception):
    def __init__(self, code):
        super().__init__(f"HTTP {code}")
        self.code = code


def save():
    with lock:
        write_json(DB, tasks)


def safe(p):
    rp = os.path.realpath(p)
    if rp != ROOT and not rp.startswith(ROOT + os.sep):
        raise ValueError("Lokasi di luar folder yang diizinkan")
    return rp


def mb(n):
    return f"{n / 1048576:.1f} MB"


def open_url(url, mode, referer, cookie):
    h = {}
    if mode != "std":
        h = {"User-Agent": UA, "Accept": "*/*", "Accept-Language": "id,en;q=0.8"}
        if referer: h["Referer"] = referer
        if cookie: h["Cookie"] = cookie
    if mode == "tls":
        from curl_cffi import requests as creq
        r = creq.get(url, headers=h, impersonate="chrome", stream=True, timeout=30, allow_redirects=True)
        if r.status_code >= 400:
            r.close(); raise Blocked(r.status_code)
        return r.headers, r.iter_content(1 << 20), r.close
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=h or {"User-Agent": "Python-urllib/3"}), timeout=30)
    except urllib.error.HTTPError as e:
        raise Blocked(e.code)
    return r.headers, iter(lambda: r.read(1 << 20), b""), r.close


def download(t):
    dest = safe(t["dest"]); os.makedirs(dest, exist_ok=True)
    order = MODES[MODES.index(t["mode"]):] if t["auto"] else [t["mode"]]
    for m in order:
        try:
            hdr, chunks, close = open_url(t["src"], m, t["referer"], t["cookie"]); break
        except Blocked as e:
            if e.code not in (403, 429): raise
            t["note"] = f"Ditolak {e.code} di mode {m}"; last = e
    else:
        raise RuntimeError(f"Ditolak {last.code} di semua mode. Situs mungkin butuh browser penuh.")
    t["used"] = m
    total = int(hdr.get("Content-Length") or 0)
    mm = re.search(r"filename\*?=(?:UTF-8'')?\"?([^\";]+)", hdr.get("Content-Disposition", "") or "")
    name = t["name"] or (urllib.parse.unquote(mm.group(1)) if mm else
                         urllib.parse.unquote(os.path.basename(urllib.parse.urlparse(t["src"]).path)))
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", os.path.basename(name or "")).strip() or "download.bin"
    if name in (".", ".."):
        name = "download.bin"
    out = safe(os.path.join(dest, name))
    part, done, tick, last_done = out + ".part", 0, time.monotonic(), 0
    t["speed"] = 0
    try:
        with open(part, "wb") as f:
            task_limit = float(t.get("limit_mib", 0))
            task_limiter = RateLimiter(task_limit) if task_limit else None
            for incoming in chunks:
                for offset in range(0, len(incoming), 64 * 1024):
                    b = incoming[offset:offset + 64 * 1024]
                    if t["id"] in cancels: raise InterruptedError
                    if task_limiter:
                        task_limiter.acquire(len(b), t["id"])
                    rate_limiter.acquire(len(b), t["id"])
                    f.write(b); done += len(b)
                now = time.monotonic()
                if now - tick > 1:
                    t["speed"] = (done - last_done) / (now - tick)
                    t["progress"] = min(99, int(done * 100 / total)) if total else 0
                    t["msg"] = f"{name}: {mb(done)}" + (f" / {mb(total)}" if total else "") + f" · {mb(t['speed'])}/s"
                    tick, last_done = now, done
        os.replace(part, out)
        t["bytes"] = done
        register_download(out, done)
    except BaseException:
        if os.path.exists(part): os.remove(part)
        raise
    finally:
        close()
    t["speed"] = 0
    t["msg"] = f"{name} ({mb(done)})"
    t["output"] = os.path.basename(out)


def worker(t):
    with sem:
        if t["id"] in cancels:
            t["status"] = "cancelled"; save()
            log_event("task_cancelled_before_start", task_id=t["id"], task_type=t["type"])
            return
        t["status"] = "running"; save()
        started = time.monotonic()
        log_event("task_started", task_id=t["id"], task_type=t["type"])
        error_type = None
        try:
            download(t)
            t["status"], t["progress"] = "done", 100
        except InterruptedError:
            t["status"], t["msg"] = "cancelled", "Dibatalkan"
        except Exception as e:
            t["status"], t["msg"] = "failed", str(e)[:200]
            error_type = type(e).__name__
        save()
        log_event("task_finished", task_id=t["id"], task_type=t["type"], status=t["status"],
                  duration_seconds=round(time.monotonic() - started, 3),
                  bytes_downloaded=t.get("bytes"), error_type=error_type,
                  level=logging.ERROR if error_type else logging.INFO)


@app.before_request
def auth():
    if APP_USER or APP_PASS:
        a = request.authorization
        if (not a or not hmac.compare_digest((a.username or "").encode("utf-8"), APP_USER.encode("utf-8"))
                or not hmac.compare_digest((a.password or "").encode("utf-8"), APP_PASS.encode("utf-8"))):
            return Response("Login diperlukan", 401, {"WWW-Authenticate": 'Basic realm="Drive Tasks"'})


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/tasks")
def list_tasks():
    return jsonify(sorted(tasks.values(), key=lambda t: -t["created"]))


@app.get("/api/settings")
def settings():
    return jsonify(download_limit_mib=rate_limiter.limit_mib(), browser_enabled=ENABLE_BROWSER)


@app.post("/api/settings")
def update_settings():
    d = request.get_json(silent=True) or {}
    if not isinstance(d, dict):
        return jsonify(error="Body harus berupa objek JSON"), 400
    try:
        value = float(d.get("download_limit_mib"))
        if isinstance(d.get("download_limit_mib"), bool) or not math.isfinite(value) or not 0 <= value <= 1024:
            raise ValueError("Limit harus antara 0 dan 1024 MiB/s")
    except (TypeError, ValueError, OverflowError):
        return jsonify(error="Limit harus berupa angka antara 0 dan 1024 MiB/s"), 400
    with lock:
        write_json(SETTINGS_DB, {"download_limit_mib": value})
    rate_limiter.set_limit(value)
    log_event("download_limit_changed", download_limit_mib=value)
    return jsonify(download_limit_mib=value)


@app.get("/api/tasks/<tid>/file")
def get_file(tid):
    task = tasks.get(tid)
    name = task.get("output") if task else None
    if not task or task.get("type") != "download" or task.get("status") != "done":
        abort(404)
    if not isinstance(name, str) or not name or os.path.basename(name) != name:
        abort(404)
    try:
        path = safe(os.path.join(ROOT, name))
    except ValueError:
        abort(404)
    if not os.path.isfile(path):
        abort(404)
    log_event("result_download_requested", task_id=tid, bytes=os.path.getsize(path))
    return send_file(path, as_attachment=True, download_name=name, max_age=0)


@app.get("/api/browser-files")
def list_browser_files():
    if not ENABLE_BROWSER:
        abort(404)
    items = []
    for name in os.listdir(BROWSER_DIR):
        path = os.path.join(BROWSER_DIR, name)
        if (name.endswith((".crdownload", ".part")) or os.path.islink(path)
                or not os.path.isfile(path)):
            continue
        stat = os.stat(path, follow_symlinks=False)
        items.append({"name": name, "size": stat.st_size, "modified": stat.st_mtime})
    return jsonify(sorted(items, key=lambda item: -item["modified"]))


@app.get("/api/browser-files/<name>")
def get_browser_file(name):
    if not ENABLE_BROWSER:
        abort(404)
    if not name or name in (".", "..") or os.path.basename(name) != name:
        abort(404)
    candidate = os.path.join(BROWSER_DIR, name)
    if os.path.islink(candidate):
        abort(404)
    try:
        path = safe(candidate)
    except ValueError:
        abort(404)
    if not path.startswith(BROWSER_DIR + os.sep) or not os.path.isfile(path):
        abort(404)
    log_event("browser_file_download_requested", bytes=os.path.getsize(path))
    return send_file(path, as_attachment=True, download_name=name, max_age=0)


@app.post("/api/tasks")
def add():
    d = request.get_json(silent=True) or {}
    try:
        typ, mode = d.get("type", "download"), d.get("mode", "std")
        if typ != "download" or mode not in MODES: raise ValueError("Pilihan tidak valid")
        src = str(d.get("src", "")).strip()
        if not re.match(r"^https?://", src): raise ValueError("URL harus diawali http:// atau https://")
        limit_mib = float(d.get("limit_mib", 0))
        if isinstance(d.get("limit_mib", 0), bool) or not math.isfinite(limit_mib) or not 0 <= limit_mib <= 1024:
            raise ValueError("Limit task harus antara 0 dan 1024 MiB/s")
    except Exception as e:
        return jsonify(error=str(e)), 400
    t = dict(id=uuid.uuid4().hex[:8], type=typ, src=src, dest=ROOT, mode=mode, auto=bool(d.get("auto", True)),
             referer=d.get("referer", ""), cookie=d.get("cookie", ""), name=d.get("name", ""),
             limit_mib=limit_mib,
             status="queued", progress=0, msg="", note="", used="", created=time.time())
    tasks[t["id"]] = t; save()
    log_event("task_queued", task_id=t["id"], task_type=t["type"])
    threading.Thread(target=worker, args=(t,), daemon=True).start()
    return jsonify(t)


@app.post("/api/tasks/<tid>/cancel")
def cancel(tid):
    if tid in tasks:
        cancels.add(tid)
        log_event("task_cancel_requested", task_id=tid)
    return jsonify(ok=True)


@app.delete("/api/tasks/<tid>")
def delete(tid):
    t = tasks.get(tid)
    if t and t["status"] not in ("running", "queued"):
        tasks.pop(tid); save()
        log_event("task_deleted", task_id=tid, task_type=t["type"])
    return jsonify(ok=True)


def load():
    if os.path.exists(SETTINGS_DB):
        saved = json.load(open(SETTINGS_DB, encoding="utf-8"))
        value = float(saved["download_limit_mib"])
        if not math.isfinite(value) or not 0 <= value <= 1024:
            raise ValueError("Limit global tersimpan tidak valid")
        rate_limiter.set_limit(value)
    if os.path.exists(DOWNLOADS_DB):
        downloads.update(json.load(open(DOWNLOADS_DB, encoding="utf-8")))
    recovered = 0
    if os.path.exists(DB):
        tasks.update(json.load(open(DB)))
        for t in tasks.values():
            if t["status"] in ("running", "queued"):
                t["status"], t["msg"] = "failed", "Terhenti karena restart"
                recovered += 1
        if recovered:
            save()
    log_event("application_started", recovered_tasks=recovered)


def cleanup_expired():
    cutoff = time.time() - RETENTION_SECONDS
    deleted_downloads = skipped_downloads = expired_tasks = 0
    downloads_changed = tasks_changed = False
    with lock:
        for key, entry in list(downloads.items()):
            if entry.get("created", 0) >= cutoff:
                continue
            path = entry.get("path", "")
            try:
                if (not path or os.path.abspath(path) != path or os.path.realpath(path) != path
                        or not path.startswith(ROOT + os.sep) or os.path.islink(path)):
                    skipped_downloads += 1
                elif os.path.isfile(path):
                    os.remove(path)
                    deleted_downloads += 1
                else:
                    skipped_downloads += 1
            except FileNotFoundError:
                pass
            except OSError as e:
                log_event("download_retention_failed", level=logging.ERROR, error_type=type(e).__name__)
                continue
            downloads.pop(key, None)
            downloads_changed = True

        for task_id, task in list(tasks.items()):
            if (task.get("created", 0) < cutoff
                    and task.get("status") not in ("queued", "running")):
                tasks.pop(task_id)
                expired_tasks += 1
                tasks_changed = True

        if downloads_changed:
            write_json(DOWNLOADS_DB, downloads)
        if tasks_changed:
            write_json(DB, tasks)

    expired_logs = 0
    for name in os.listdir(CONF):
        if not name.startswith("drive-tasks.log."):
            continue
        path = os.path.join(CONF, name)
        if os.path.isfile(path) and not os.path.islink(path) and os.path.getmtime(path) < cutoff:
            os.remove(path)
            expired_logs += 1

    expired_browser_downloads = 0
    if ENABLE_BROWSER:
        for name in os.listdir(BROWSER_DIR):
            path = os.path.join(BROWSER_DIR, name)
            try:
                if (not os.path.islink(path) and os.path.isfile(path)
                        and os.path.getmtime(path) < cutoff):
                    os.remove(path)
                    expired_browser_downloads += 1
            except OSError as e:
                log_event("browser_download_retention_failed", level=logging.ERROR,
                          error_type=type(e).__name__)

    log_event("retention_cleanup", deleted_downloads=deleted_downloads,
              skipped_downloads=skipped_downloads, expired_browser_downloads=expired_browser_downloads,
              expired_tasks=expired_tasks, expired_logs=expired_logs)


def retention_loop():
    while True:
        time.sleep(3600)
        try:
            cleanup_expired()
        except Exception as e:
            log_event("retention_cleanup_failed", level=logging.ERROR, error_type=type(e).__name__)


load()
if __name__ == "__main__":
    cleanup_expired()
    threading.Thread(target=retention_loop, daemon=True).start()
    from waitress import serve
    serve(app, host="0.0.0.0", port=PORT, threads=8)
