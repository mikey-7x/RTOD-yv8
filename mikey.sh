#!/bin/bash

# Activate Virtual Environment
source ~/yolov8_env/bin/activate

# Prompt user for the IP camera address
read -p "Enter your IP Camera URL (e.g., http://10.112.238.147:8080/video): " ip_camera_url

# Update the Python script with the provided IP address
sed -i "s|ip_camera_url = .*|ip_camera_url = \"$ip_camera_url\"|" ~/yolov8_env/yolov8.py

# Display the streaming link
echo "✅ Object detection will be available at: http://$(hostname -I | awk '{print $1}'):5050/video_feed"

# Start real-time object detection
python ~/yolov8_env/yolov8.py
