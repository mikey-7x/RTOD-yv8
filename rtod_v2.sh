#!/bin/bash
# RTOD-yv8: Actual real-time object detection on Android via Termux
# © 2025 mikey-7x | CC BY-NC-ND 4.0

set -e

echo "🔧 Preparing environment for actual real-time YOLOv8 detection..."

# Detect package manager
if command -v apt >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v pkg >/dev/null 2>&1; then
  PKG_MGR="pkg"
else
  echo "❌ No supported package manager found (apt or pkg)."
  exit 1
fi

# Install OS deps
echo "📦 Installing system dependencies..."
if [ "$PKG_MGR" = "apt" ]; then
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y python3 python3-pip python3-venv ffmpeg libgl1 wget
else
  pkg update -y && pkg upgrade -y
  pkg install -y python python-pip ffmpeg wget
fi

# Create venv
VENV_DIR="$HOME/yolov8_env"
if [ ! -d "$VENV_DIR" ]; then
  echo "🐍 Creating Python virtual environment at $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
fi

# Activate venv
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

# Install Python deps (lean and compatible)
echo "📦 Installing Python dependencies (ultralytics, opencv-python, numpy, requests)..."
pip install --upgrade pip
pip install ultralytics opencv-python numpy requests

# Clean pip cache
echo "🧹 Cleaning pip cache..."
rm -rf ~/.cache/pip || true

# Download model
MODEL_PATH="$VENV_DIR/yolov8n.pt"
if [ ! -f "$MODEL_PATH" ]; then
  echo "⬇️ Downloading YOLOv8n model..."
  wget -O "$MODEL_PATH" "https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.pt"
fi

# Write runner (robust MJPEG marker parser + snapshot fallback + newest-frame only)
RUNNER="$VENV_DIR/yolov8.py"
echo "📝 Writing ultra-low-latency detection script to $RUNNER..."
cat > "$RUNNER" << 'EOF'
# RTOD-yv8: actual low-latency runner (MJPEG marker parser + snapshot fallback + newest-frame only)
# © 2025 mikey-7x | CC BY-NC-ND 4.0

import os
import cv2
import time
import threading
import subprocess
import numpy as np
import requests
from collections import deque
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, urlunparse
from ultralytics import YOLO

# Config via env
IP_CAMERA_URL = os.environ.get("RTOD_IP_URL", "http://127.0.0.1:8080/video")
MODEL_PATH = os.environ.get("RTOD_MODEL", "yolov8n.pt")
STREAM_PORT = int(os.environ.get("RTOD_PORT", "5050"))
IMG_SIZE = int(os.environ.get("RTOD_IMGSZ", "320"))   # 256/320/416 → faster
CONF_THRESH = float(os.environ.get("RTOD_CONF", "0.50"))
JPEG_QUALITY = int(os.environ.get("RTOD_JPEGQ", "70"))

# Buffers/flags
frame_buffer = deque(maxlen=1)  # newest-frame only
processed_frame = None
lock = threading.Lock()
stop_flag = False

# Model
model = YOLO(MODEL_PATH)

def is_snapshot(url: str) -> bool:
    return url.endswith("/shot.jpg") or "shot.jpg" in url

def derive_snapshot_url(url: str) -> str:
    """
    Derive snapshot endpoint from common IP Webcam MJPEG URLs.
    - /video or /stream.mjpeg → /shot.jpg
    """
    try:
        pr = urlparse(url)
        path = pr.path
        if path.endswith("/video") or path.endswith("/stream.mjpeg"):
            path = path.rsplit("/", 1)[0] + "/shot.jpg"
        return urlunparse((pr.scheme, pr.netloc, path, pr.params, pr.query, pr.fragment))
    except Exception:
        return url

def mjpeg_marker_reader(url: str):
    """
    Read MJPEG as raw bytes and extract JPEG frames by SOI/EOI markers.
    Robust across funky boundaries. Decodes immediately; newest-frame only.
    """
    sess = requests.Session()
    headers = {
        "User-Agent": "RTOD-yv8/1.0",
        "Accept": "multipart/x-mixed-replace, image/jpeg,*/*"
    }
    retries = 0
    while not stop_flag:
        try:
            resp = sess.get(url, headers=headers, stream=True, timeout=5)
            if resp.status_code != 200:
                retries += 1
                print(f"❌ MJPEG HTTP {resp.status_code}, retry {retries}...")
                time.sleep(0.5)
                continue

            buf = bytearray()
            SOI = b"\xff\xd8"
            EOI = b"\xff\xd9"

            for chunk in resp.iter_content(chunk_size=4096):
                if stop_flag:
                    break
                if not chunk:
                    continue
                buf.extend(chunk)
                # Extract JPEGs by markers
                while True:
                    start = buf.find(SOI)
                    if start == -1:
                        break
                    end = buf.find(EOI, start + 2)
                    if end == -1:
                        break
                    jpeg = bytes(buf[start:end+2])
                    del buf[:end+2]
                    arr = np.frombuffer(jpeg, dtype=np.uint8)
                    frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
                    if frame is not None:
                        frame_buffer.append(frame)
        except Exception as e:
            retries += 1
            print(f"⚠️ MJPEG reader error: {e}, retry {retries}...")
            time.sleep(0.5)
            continue

def ffmpeg_pipe_reader(url: str):
    """
    Last-resort: FFmpeg image2pipe for streams the marker reader can't handle.
    """
    cmd = [
        "ffmpeg",
        "-nostdin", "-hide_banner",
        "-loglevel", "error",
        "-fflags", "+nobuffer",
        "-flags", "low_delay",
        "-reconnect", "1",
        "-reconnect_streamed", "1",
        "-reconnect_delay_max", "2",
        "-i", url,
        "-f", "image2pipe",
        "-vcodec", "mjpeg",
        "-q:v", "3",
        "-"
    ]
    while not stop_flag:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=0)
        except Exception as e:
            print(f"❌ Failed to start ffmpeg: {e}")
            time.sleep(0.5)
            continue

        buf = bytearray()
        SOI = b"\xff\xd8"
        EOI = b"\xff\xd9"
        try:
            while not stop_flag:
                chunk = proc.stdout.read(4096)
                if not chunk:
                    break
                buf.extend(chunk)
                while True:
                    start = buf.find(SOI)
                    if start == -1:
                        break
                    end = buf.find(EOI, start + 2)
                    if end == -1:
                        break
                    jpeg = bytes(buf[start:end+2])
                    del buf[:end+2]
                    arr = np.frombuffer(jpeg, dtype=np.uint8)
                    frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
                    if frame is not None:
                        frame_buffer.append(frame)
        finally:
            try:
                proc.kill()
            except Exception:
                pass
        time.sleep(0.2)

def snapshot_poll_reader(url: str, fps: int = 30):
    sess = requests.Session()
    sess.headers.update({"User-Agent": "RTOD-yv8/1.0"})
    delay = 1.0 / float(max(fps, 1))
    retries = 0
    while not stop_flag:
        t0 = time.time()
        try:
            resp = sess.get(url, timeout=2, stream=False)
            if resp.status_code != 200:
                retries += 1
                print(f"❌ Snapshot HTTP {resp.status_code}, retry {retries}...")
                time.sleep(0.2)
                continue
            arr = np.frombuffer(resp.content, dtype=np.uint8)
            frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
            if frame is None:
                retries += 1
                print("❌ Snapshot decode failed, retry", retries)
                time.sleep(0.1)
                continue
            frame_buffer.append(frame)
        except Exception as e:
            retries += 1
            print(f"⚠️ Snapshot reader error: {e}, retry {retries}...")
            time.sleep(0.2)
            continue
        elapsed = time.time() - t0
        sleep = max(0.0, delay - elapsed)
        time.sleep(sleep)

def capture_thread():
    url = IP_CAMERA_URL.strip()
    print(f"🎥 Connecting to camera: {url}")
    # Strategy:
    # 1) If snapshot endpoint → snapshot polling
    # 2) Try MJPEG marker reader (fastest)
    # 3) If no frames for a while → auto-switch to derived snapshot URL
    # 4) If still nothing → FFmpeg pipe fallback
    if is_snapshot(url):
        snapshot_poll_reader(url)
        return
    # Start MJPEG marker reader in fg loop
    t_start = time.time()
    frames_seen = 0
    def count_frames():
        nonlocal frames_seen
        last = 0
        while not stop_flag:
            current = len(frame_buffer)
            if current != last and frame_buffer:
                frames_seen += 1
                last = current
            time.sleep(0.1)
    threading.Thread(target=count_frames, daemon=True).start()
    # Kick MJPEG reader
    threading.Thread(target=mjpeg_marker_reader, args=(url,), daemon=True).start()
    # Monitor and fallback if needed
    while not stop_flag:
        time.sleep(2)
        runtime = time.time() - t_start
        if frames_seen > 0:
            # We are getting frames
            continue
        # No frames: try derived snapshot
        snap = derive_snapshot_url(url)
        print(f"⚠️ No MJPEG frames yet; switching to snapshot: {snap}")
        snapshot_poll_reader(snap)
        if len(frame_buffer) == 0:
            print("⚠️ Snapshot also not yielding frames; trying FFmpeg pipe...")
            ffmpeg_pipe_reader(url)
        # If any yields, loop continues and process thread will consume

def process_thread():
    global processed_frame
    while not stop_flag:
        if not frame_buffer:
            time.sleep(0.001)
            continue
        frame = frame_buffer[-1]
        # YOLO inference: smallest model, small imgsz, higher conf → faster draw
        results = model.predict(
            source=frame,
            imgsz=IMG_SIZE,
            conf=CONF_THRESH,
            iou=0.45,
            device="cpu",
            half=False,
            verbose=False,
            stream=False
        )
        for r in results:
            out = r.plot()
            with lock:
                processed_frame = out

class MJPEGHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/video_feed":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")
            return
        self.send_response(200)
        self.send_header("Cache-Control", "no-cache, private")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.end_headers()
        boundary = b"--frame\r\n"
        while True:
            with lock:
                frame = processed_frame
            if frame is None:
                time.sleep(0.003)
                continue
            ok, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY])
            if not ok:
                continue
            try:
                self.wfile.write(boundary)
                self.wfile.write(b"Content-Type: image/jpeg\r\n\r\n")
                self.wfile.write(buf.tobytes())
                self.wfile.write(b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                break

    def log_message(self, format, *args):
        return

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

def main():
    print("🚀 Starting actual low-latency capture and detection...")
    t1 = threading.Thread(target=capture_thread, daemon=True)
    t2 = threading.Thread(target=process_thread, daemon=True)
    t1.start()
    t2.start()
    server = ThreadedHTTPServer(("0.0.0.0", STREAM_PORT), MJPEGHandler)
    print(f"✅ Live MJPEG stream: http://0.0.0.0:{STREAM_PORT}/video_feed")
    print("ℹ️ Use your device IP in the URL from another device on the same network.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        global stop_flag
        stop_flag = True
        print("🛑 Stopping...")
        time.sleep(0.3)

if __name__ == "__main__":
    main()
EOF

# Create one-command launcher (safe quoting + robust local IP)
LAUNCHER="$HOME/start-detect"
echo "📝 Creating one-command launcher at $LAUNCHER..."
cat > "$LAUNCHER" << 'EOF'
#!/bin/bash
# Start RTOD-yv8 with one command
VENV_DIR="$HOME/yolov8_env"
RUNNER="$VENV_DIR/yolov8.py"
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

read -p "Enter IP Camera URL (e.g., http://127.0.0.1:8080/video or http://PHONE_IP:8080/shot.jpg): " IP_URL
IP_URL_TRIM=$(echo "$IP_URL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$IP_URL_TRIM" ]; then
  echo "❌ Empty URL. Aborting."; exit 1
fi
export RTOD_IP_URL="$IP_URL_TRIM"
export RTOD_MODEL="$VENV_DIR/yolov8n.pt"
export RTOD_PORT="5050"
# Speed tuning
export RTOD_IMGSZ="320"
export RTOD_CONF="0.50"
export RTOD_JPEGQ="70"

# Robust local IP detection (no awk quoting issues)
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP="0.0.0.0"
fi

echo "🎥 Capturing from: $IP_URL_TRIM"
echo "🖥️ View detections at: http://$LOCAL_IP:5050/video_feed"
python "$RUNNER"
EOF
chmod +x "$LAUNCHER"

# Determine local IP safely
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP="0.0.0.0"
fi

echo ""
echo "✅ Setup complete."
echo "▶ Start detection anytime with: start-detect"
echo "   It will ask your camera URL, then print the viewing link."
echo ""
echo "⏱️ Launching now (demo):"
"$HOME/start-detect"
