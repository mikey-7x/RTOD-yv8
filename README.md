# RTOD-yv8
In this project I make a real time object detection using yolov8 (RTOD-yv8) on android with termux 

After installation of termux from fdroid we require install any one linux distribution through termux on your android phone 

Then open your linux os on android and run run first "yolo.sh" script which install the all necessary package in vertual environment which protects your other packages to be breaked 

Then run "mikey.sh" script to start Real time object detection in which it takes ip address of webcame (which you can bring from ip webcame app available on playstore)

After putting ip address it starts to upload detected output on http link 

To watch this output type "your ip address:5050/video_feed" on your browser make sure ip address is correct to implement on this link to be type in browser.

For example my ip address of camera webcame is   "http://10.115.163.241:8080" so, after running script on linux type "http://10.115.163.241:5050/video_feed" on your browser to see detected output 
That project's real time object detection is may be  slow it's depends on your android phone, internet speed,also the path of serving/taking detection is long so,it is one reason for slow output/detection 
