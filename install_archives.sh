#!/bin/bash
set -euo pipefail

# =========================
#  CONFIG BOLEH UBAH SINI
# =========================
TELEGRAM_BOT_TOKEN="8587269810:AAGh6ogy1Y3czTAhUU4ppMk3S9gVHknpw2g"
TELEGRAM_CHAT_ID="-1003634039424"

GITHUB_TOKEN="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"
GITHUB_REPO="https://github.com/okyimfine/ArchivesAmirCexi.git"

PY_SCRIPT="/root/ptero_menu.py"
WRAP_SCRIPT="/root/ptero_protect.sh"
MARKER_DIR="/root/.ptero_processed"
CSV_FILE="/root/ptero_backups.csv"
CRON_LOG="/root/ptero_auto2.log"
GIT_WORKDIR="/root/ptero_archives"

# =========================
#  CHECK ROOT
# =========================
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Jalankan script ini sebagai root (sudo / root user)." >&2
  exit 1
fi

echo "[INFO] Installer ARCHIVES Pterodactyl Backup by okyimfine"

# =========================
#  FUNGSI: TUNGGU APT LOCK
# =========================
wait_for_apt_lock() {
  local timeout=120
  local waited=0

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then
      echo "[WARN] apt/dpkg masih lock selepas ${timeout}s, skip auto install deps."
      return 1
    fi
    echo "[INFO] Menunggu apt lock dilepaskan... (${waited}s)"
    sleep 5
    waited=$((waited + 5))
  done
  return 0
}

# =========================
#  INSTALL DEPENDENCIES
# =========================
NEED_PKGS=(python3 git curl zip)

MISSING=()
for p in "${NEED_PKGS[@]}"; do
  if ! command -v "$p" >/dev/null 2>&1; then
    MISSING+=("$p")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "[INFO] Package belum ada: ${MISSING[*]}"
  if wait_for_apt_lock; then
    echo "[INFO] Running: apt update && apt install ${MISSING[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt update -y >/dev/null 2>&1 || true
    apt install -y "${MISSING[@]}" >/dev/null 2>&1 || true
  else
    echo "[WARN] Tak dapat install auto sebab apt lock. Pastikan python3/git/curl/zip ada."
  fi
else
  echo "[INFO] Semua dependency utama sudah ada."
fi

# =========================
#  TULIS PYTHON SCRIPT
# =========================
cat > "$PY_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import os
import sys
import shutil
import subprocess
from datetime import datetime, timedelta

# ==== CONFIG UTAMA ====
VOLUMES_DIR = "/var/lib/pterodactyl/volumes"
DEST_DIR = "/root"
MARKER_DIR = "/root/.ptero_processed"
CSV_FILE = "/root/ptero_backups.csv"

TELEGRAM_BOT_TOKEN = "8587269810:AAGh6ogy1Y3czTAhUU4ppMk3S9gVHknpw2g"
TELEGRAM_CHAT_ID = "-1003634039424"

GITHUB_TOKEN = "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"
GITHUB_REPO = "https://github.com/okyimfine/ArchivesAmirCexi.git"
GIT_WORKDIR = "/root/ptero_archives"

# 0 = tiada limit, contoh 10 = max 10 server per run
MAX_PER_RUN = 0
# Auto buang ZIP local lebih tua daripada X hari
CLEANUP_DAYS = 7

# ==== COLOR / UI (Colorama) ====
try:
    from colorama import init, Fore, Style
    init(autoreset=True)
except ImportError:
    class _Dummy:
        def __getattr__(self, name):
            return ""
    Fore = Style = _Dummy()

def cinfo(msg):
    print(getattr(Fore, "CYAN", "") + getattr(Style, "BRIGHT", "") + msg)

def csuccess(msg):
    print(getattr(Fore, "GREEN", "") + getattr(Style, "BRIGHT", "") + msg)

def cwarn(msg):
    print(getattr(Fore, "YELLOW", "") + getattr(Style, "BRIGHT", "") + msg)

def cerror(msg):
    print(getattr(Fore, "RED", "") + getattr(Style, "BRIGHT", "") + msg)

# ==== TELEGRAM ====
import urllib.parse
import urllib.request

def send_telegram_message(text: str):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return
    data = urllib.parse.urlencode({
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
    }).encode("utf-8")
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    try:
        urllib.request.urlopen(url, data=data, timeout=10)
    except Exception:
        pass

def send_telegram_file(file_path: str, caption: str):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return
    if not os.path.isfile(file_path):
        return
    try:
        size = os.path.getsize(file_path)
    except OSError:
        size = 0

    if size > 50_000_000:
        send_telegram_message(f"{caption} (Fail > 50MB, tidak dihantar sebagai dokumen)")
        return

    boundary = "----------ptero_boundary"
    data = []

    def add_field(name, value):
        data.append(f"--{boundary}".encode())
        data.append(f'Content-Disposition: form-data; name="{name}"'.encode())
        data.append(b"")
        data.append(value.encode())

    def add_file_field(name, filename, file_content):
        data.append(f"--{boundary}".encode())
        data.append(
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"'.encode()
        )
        data.append(b"Content-Type: application/octet-stream")
        data.append(b"")
        data.append(file_content)

    add_field("chat_id", TELEGRAM_CHAT_ID)
    add_field("caption", caption)

    with open(file_path, "rb") as f:
        file_content = f.read()

    filename = os.path.basename(file_path)
    add_file_field("document", filename, file_content)

    data.append(f"--{boundary}--".encode())
    data.append(b"")

    body = b"\r\n".join(data)
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendDocument"
    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Content-Length": str(len(body)),
    }
    req = urllib.request.Request(url, data=body, headers=headers)
    try:
        urllib.request.urlopen(req, timeout=30)
    except Exception:
        pass

# ==== UTIL & STATUS ====
def check_dependencies():
    missing = []
    for bin_name in ("zip", "git", "curl"):
        if shutil.which(bin_name) is None:
            missing.append(bin_name)
    if missing:
        cwarn("Tool berikut tiada dalam sistem: " + ", ".join(missing))
        cwarn("Install manual: apt install " + " ".join(missing))
    return not missing

def ensure_paths():
    os.makedirs(MARKER_DIR, exist_ok=True)
    if not os.path.isdir(VOLUMES_DIR):
        cerror(f"Directory volumes ({VOLUMES_DIR}) tidak wujud.")
        return False
    if not os.path.isfile(CSV_FILE):
        with open(CSV_FILE, "w", encoding="utf-8") as f:
            f.write("server_uuid,file_name,source_path,dest_path,timestamp\n")
    return True

def cleanup_old_backups():
    if not os.path.isdir(DEST_DIR):
        return
    cutoff = datetime.now() - timedelta(days=CLEANUP_DAYS)
    removed = 0
    for name in os.listdir(DEST_DIR):
        if not name.lower().endswith(".zip"):
            continue
        path = os.path.join(DEST_DIR, name)
        try:
            mtime = datetime.fromtimestamp(os.path.getmtime(path))
        except OSError:
            continue
        if mtime < cutoff:
            try:
                os.remove(path)
                removed += 1
            except OSError:
                continue
    if removed:
        cinfo(f"Cleanup: {removed} backup lama (> {CLEANUP_DAYS} hari) dipadam.")

def list_servers_status():
    if not os.path.isdir(VOLUMES_DIR):
        cerror(f"Directory volumes ({VOLUMES_DIR}) tidak wujud.")
        return
    processed = set()
    if os.path.isdir(MARKER_DIR):
        for name in os.listdir(MARKER_DIR):
            if name.endswith(".done"):
                processed.add(name[:-5])
    total = 0
    done = 0
    for entry in os.scandir(VOLUMES_DIR):
        if not entry.is_dir():
            continue
        total += 1
        if entry.name in processed:
            done += 1
    cinfo(f"Total server        : {total}")
    cinfo(f"Sudah di-backup     : {done}")
    cinfo(f"Belum di-backup     : {total - done}")

def reset_markers():
    if not os.path.isdir(MARKER_DIR):
        cinfo("Tiada marker untuk dipadam.")
        return
    count = 0
    for name in os.listdir(MARKER_DIR):
        if name.endswith(".done"):
            try:
                os.remove(os.path.join(MARKER_DIR, name))
                count += 1
            except OSError:
                continue
    cinfo(f"Marker dipadam: {count}")

# ==== BACKUP ====
def backup_all_servers(send_tg: bool = True):
    if not ensure_paths():
        return []
    check_dependencies()

    processed = []
    count = 0

    for entry in os.scandir(VOLUMES_DIR):
        if not entry.is_dir():
            continue

        server_id = entry.name
        marker = os.path.join(MARKER_DIR, f"{server_id}.done")
        if os.path.isfile(marker):
            continue

        if MAX_PER_RUN and count >= MAX_PER_RUN:
            break

        server_dir = entry.path
        ts = datetime.utcnow().strftime("%Y-%m-%d_%H-%M-%S")

        existing_zip = None
        for f in os.listdir(server_dir):
            if f.lower().endswith(".zip"):
                existing_zip = os.path.join(server_dir, f)
                break

        if existing_zip:
            filename = f"{server_id}_{os.path.basename(existing_zip)}"
            src = existing_zip
            dst = os.path.join(DEST_DIR, filename)
            try:
                shutil.copy2(src, dst)
            except Exception as e:
                cerror(f"Gagal copy {src} -> {dst}: {e}")
                continue
        else:
            filename = f"{server_id}_{ts}.zip"
            src = server_dir
            dst = os.path.join(DEST_DIR, filename)
            zip_cmd = ["zip", "-r", dst, server_dir]
            result = subprocess.run(zip_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode != 0:
                cerror(f"Gagal zip server {server_id}, skip.")
                continue

        with open(CSV_FILE, "a", encoding="utf-8") as f:
            f.write(f"{server_id},{filename},{src},{dst},{ts}\n")

        open(marker, "w").close()

        caption = f"[{server_id}][{filename}]Berjaya Di Ambil Secara Silent"
        if send_tg:
            send_telegram_file(dst, caption)

        processed.append({"server_id": server_id})
        count += 1
        csuccess(f"Backup {server_id} -> {dst}")

    if not processed:
        cinfo("Tiada server baru untuk di-backup (semua sudah ada marker / limit run capai).")

    cleanup_old_backups()
    return processed

# ==== GITHUB PUSH ====
def git_push(backups):
    if not backups:
        cwarn("Tiada backup baru untuk dihantar ke GitHub.")
        return

    token = GITHUB_TOKEN.strip()
    if not token:
        cerror("GITHUB_TOKEN kosong dalam script. Skip push GitHub.")
        return

    check_dependencies()

    os.makedirs(GIT_WORKDIR, exist_ok=True)

    if not os.path.isdir(os.path.join(GIT_WORKDIR, ".git")):
        cinfo("Init repo Git baru di " + GIT_WORKDIR)
        subprocess.run(["git", "init"], cwd=GIT_WORKDIR, check=False)
        subprocess.run(["git", "config", "user.name", "okyimfine"], cwd=GIT_WORKDIR, check=False)
        subprocess.run(["git", "config", "user.email", "nbcgggh0@gmail.com"], cwd=GIT_WORKDIR, check=False)
        subprocess.run(["git", "remote", "remove", "origin"], cwd=GIT_WORKDIR, check=False)
        remote_url = GITHUB_REPO.replace("https://", f"https://{token}@")
        subprocess.run(["git", "remote", "add", "origin", remote_url], cwd=GIT_WORKDIR, check=False)

    backups_dir = os.path.join(GIT_WORKDIR, "backups")
    os.makedirs(backups_dir, exist_ok=True)

    for name in os.listdir(DEST_DIR):
        if not name.lower().endswith(".zip"):
            continue
        src = os.path.join(DEST_DIR, name)
        if not os.path.isfile(src):
            continue
        dst = os.path.join(backups_dir, name)
        try:
            shutil.copy2(src, dst)
        except Exception as e:
            cerror(f"Gagal copy ke repo: {e}")

    subprocess.run(["git", "add", "."], cwd=GIT_WORKDIR, check=False)
    msg = f"Auto backup {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')} UTC"
    subprocess.run(["git", "commit", "-m", msg], cwd=GIT_WORKDIR, check=False)
    subprocess.run(["git", "branch", "-M", "main"], cwd=GIT_WORKDIR, check=False)
    result = subprocess.run(["git", "push", "-u", "origin", "main", "--force"], cwd=GIT_WORKDIR, check=False)

    if result.returncode == 0:
        csuccess("Push ke GitHub berjaya.")
        send_telegram_message("[GITHUB][main] Berjaya Di Push Secara Silent")
    else:
        cerror("Push ke GitHub gagal.")
        send_telegram_message("[GITHUB][main] Push ke GitHub gagal.")

# ==== MENU ====
def show_menu():
    os.system("clear")
    print(getattr(Style, "BRIGHT", "") + getattr(Fore, "MAGENTA", "") + "=" * 60)
    print(getattr(Style, "BRIGHT", "") + getattr(Fore, "MAGENTA", "") + "      WELCOME TO ARCHIVES • PTERO BACKUP MENU")
    print(getattr(Style, "BRIGHT", "") + getattr(Fore, "CYAN", "")    + "          by okyimfine  <nbcgggh0@gmail.com>")
    print(getattr(Style, "BRIGHT", "") + getattr(Fore, "MAGENTA", "") + "=" * 60)
    print(getattr(Fore, "GREEN", "") + "1." + getattr(Style, "BRIGHT", "") + " Local backup + Telegram")
    print(getattr(Fore, "GREEN", "") + "2." + getattr(Style, "BRIGHT", "") + " Local backup + Telegram + GitHub push")
    print(getattr(Fore, "GREEN", "") + "3." + getattr(Style, "BRIGHT", "") + " Status server (processed / pending)")
    print(getattr(Fore, "GREEN", "") + "4." + getattr(Style, "BRIGHT", "") + " Reset semua marker (paksa backup semula)")
    print(getattr(Fore, "GREEN", "") + "5." + getattr(Style, "BRIGHT", "") + " Keluar")
    print()

def main():
    # Mode auto untuk cron
    if len(sys.argv) > 1:
        if sys.argv[1] == "--auto":
            backup_all_servers(send_tg=True)
            return
        if sys.argv[1] == "--auto2":
            backups = backup_all_servers(send_tg=True)
            git_push(backups)
            return

    # Interactive menu
    while True:
        show_menu()
        try:
            choice = input(getattr(Fore, "CYAN", "") + "Pilih option [1-5]: ").strip()
        except EOFError:
            break

        if choice == "1":
            cinfo("Jalankan Local backup + Telegram...")
            backup_all_servers(send_tg=True)
            input("Siap. Tekan ENTER untuk kembali ke menu...")
        elif choice == "2":
            cinfo("Jalankan Local backup + Telegram + GitHub push...")
            backups = backup_all_servers(send_tg=True)
            git_push(backups)
            input("Siap. Tekan ENTER untuk kembali ke menu...")
        elif choice == "3":
            list_servers_status()
            input("Tekan ENTER untuk kembali ke menu...")
        elif choice == "4":
            cwarn("AMARAN: Ini akan buang SEMUA marker dan allow backup semula semua server.")
            confirm = input("Taip 'YA' untuk teruskan: ").strip()
            if confirm == "YA":
                reset_markers()
            else:
                cinfo("Batal reset marker.")
            input("Tekan ENTER untuk kembali ke menu...")
        elif choice == "5":
            cinfo("Keluar.")
            break
        else:
            cwarn("Input tak valid. Pilih 1–5.")

if __name__ == "__main__":
    main()
PYEOF

chmod 700 "$PY_SCRIPT"
chown root:root "$PY_SCRIPT"

# =========================
#  TULIS WRAPPER BASH PROTECT
# =========================
cat > "$WRAP_SCRIPT" << EOF2
#!/bin/bash
set -euo pipefail

SCRIPT="$PY_SCRIPT"
LOG="/root/ptero_runner.log"

if [ "\$EUID" -ne 0 ]; then
  echo "[ERROR] Script ini mesti dijalankan sebagai root." >&2
  exit 1
fi

if [ ! -f "\$SCRIPT" ]; then
  echo "[ERROR] \$SCRIPT tidak ditemui." >&2
  exit 1
fi

chown root:root "\$SCRIPT" 2>/dev/null || true
chmod 700 "\$SCRIPT" 2>/dev/null || true

chown root:root "\$0" 2>/dev/null || true
chmod 700 "\$0" 2>/dev/null || true

mkdir -p "$(dirname "$CSV_FILE")" 2>/dev/null || true
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
mkdir -p "$MARKER_DIR" 2>/dev/null || true
[ -f "$CSV_FILE" ] || echo "server_uuid,file_name,source_path,dest_path,timestamp" > "$CSV_FILE"

python3 "\$SCRIPT" "\$@" | tee -a "\$LOG"
EOF2

chmod 700 "$WRAP_SCRIPT"
chown root:root "$WRAP_SCRIPT"

# =========================
#  SETUP CRON UNTUK OPTION 2 (AUTO BACKUP + TG + GITHUB)
# =========================
echo "[INFO] Setup cron untuk /root/ptero_protect.sh --auto2 (setiap 5 minit)..."
( crontab -l 2>/dev/null | sed '/ptero_protect.sh --auto2/d' || true; \
  echo "*/5 * * * * $WRAP_SCRIPT --auto2 >> $CRON_LOG 2>&1" ) | crontab -

mkdir -p "$MARKER_DIR"
[ -f "$CSV_FILE" ] || echo "server_uuid,file_name,source_path,dest_path,timestamp" > "$CSV_FILE"

echo "[OK] Install siap."
echo "    - Script utama  : $PY_SCRIPT"
echo "    - Wrapper       : $WRAP_SCRIPT"
echo "    - Marker dir    : $MARKER_DIR"
echo "    - CSV log       : $CSV_FILE"
echo "    - Cron log      : $CRON_LOG"
echo "    - Git workdir   : $GIT_WORKDIR"
echo
echo "Manual run menu     : sudo $WRAP_SCRIPT"
echo "Auto mode (Option2) : via cron setiap 5 minit."
