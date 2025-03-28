import cv2
import threading
import queue
import time
from flask import Flask, Response
from ultralytics import YOLO

# Load YOLOv8 model
model = YOLO("yolov8n.pt")

# IP Camera URL (Replace with your IP Webcam stream)
ip_camera_url = "http://10.112.238.147:8080/video"

# Flask App for Streaming
app = Flask(__name__)

# Queue to store the latest frame
frame_queue = queue.Queue(maxsize=1)
processed_frame = None
lock = threading.Lock()

def capture_frames():
    """Capture frames from the IP camera."""
    global frame_queue
    retries = 0

    while True:
        cap = cv2.VideoCapture(ip_camera_url)

        if not cap.isOpened():
            retries += 1
            print(f"❌ Error: Unable to access the camera stream. Retrying... ({retries})")
            time.sleep(2)
            continue  # Retry connection

        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)  # Reduce buffer size for minimal delay

        while True:
            success, frame = cap.read()
            if not success:
                print("❌ Warning: Failed to read frame. Retrying capture...")
                cap.release()
                break  # Restart camera connection

            with lock:
                if not frame_queue.empty():
                    frame_queue.get()  # Remove old frame
                frame_queue.put(frame)

def process_frames():
    """Process frames using YOLO for real-time detection."""
    global processed_frame

    while True:
        with lock:
            if frame_queue.empty():
                continue
            frame = frame_queue.get()

        # Run YOLOv8 object detection
        results = model(frame)

        # Extract results and draw boxes
        for result in results:
            frame = result.plot()  # Uses built-in function to draw detections

        # Store processed frame for streaming
        with lock:
            processed_frame = frame.copy()

# Start the capture and processing threads
threading.Thread(target=capture_frames, daemon=True).start()
threading.Thread(target=process_frames, daemon=True).start()

def generate_frames():
    """Generate MJPEG video stream for Flask."""
    global processed_frame

    while True:
        with lock:
            if processed_frame is None:
                continue  # Ensure a frame is available

            _, buffer = cv2.imencode('.jpg', processed_frame)

        yield (b'--frame\r\n'
               b'Content-Type: image/jpeg\r\n\r\n' + buffer.tobytes() + b'\r\n')

@app.route('/video_feed')
def video_feed():
    """Flask route for real-time video streaming."""
    return Response(generate_frames(), mimetype='multipart/x-mixed-replace; boundary=frame')

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5050, debug=False, threaded=True)
