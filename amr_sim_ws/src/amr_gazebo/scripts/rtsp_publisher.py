#!/usr/bin/env python3
"""RTSP 推流节点：订阅 /camera/image_raw，用 ffmpeg 编码 H.264 推送到 mediamtx。

不依赖 gstreamer，仅需 ffmpeg + cv_bridge。
"""
import subprocess
import sys

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image
from cv_bridge import CvBridge


class RtspPublisher(Node):
    def __init__(self):
        super().__init__('rtsp_publisher')
        self.declare_parameter('rtsp_url', 'rtsp://localhost:18554/camera')
        self.declare_parameter('fps', 15.0)
        self.rtsp_url = self.get_parameter('rtsp_url').value
        self.fps = self.get_parameter('fps').value

        self.bridge = CvBridge()
        self.ffmpeg_proc = None
        self.width = None
        self.height = None

        self.sub = self.create_subscription(
            Image, '/camera/image_raw', self.image_cb, 1
        )
        self.get_logger().info(f'RTSP publisher ready -> {self.rtsp_url}')

    def _start_ffmpeg(self, w, h):
        cmd = [
            'ffmpeg', '-y',
            '-f', 'rawvideo',
            '-pixel_format', 'bgr24',
            '-video_size', f'{w}x{h}',
            '-framerate', str(self.fps),
            '-i', '-',
            '-c:v', 'libx264',
            '-preset', 'ultrafast',
            '-tune', 'zerolatency',
            '-pix_fmt', 'yuv420p',
            '-f', 'rtsp',
            '-rtsp_transport', 'tcp',
            self.rtsp_url,
        ]
        self.get_logger().info(f'starting ffmpeg: {" ".join(cmd)}')
        self.ffmpeg_proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.width, self.height = w, h

    def image_cb(self, msg):
        try:
            cv_img = self.bridge.imgmsg_to_cv2(msg, 'bgr8')
        except Exception as e:
            self.get_logger().warn(f'cv_bridge error: {e}')
            return

        h, w = cv_img.shape[:2]
        if self.ffmpeg_proc is None:
            self._start_ffmpeg(w, h)
        elif w != self.width or h != self.height:
            self.get_logger().info(f'resolution changed {w}x{h}, restarting ffmpeg')
            self._stop_ffmpeg()
            self._start_ffmpeg(w, h)

        try:
            self.ffmpeg_proc.stdin.write(cv_img.tobytes())
        except (BrokenPipeError, OSError) as e:
            self.get_logger().warn(f'ffmpeg pipe broken: {e}, restarting')
            self._stop_ffmpeg()
            self._start_ffmpeg(w, h)

    def _stop_ffmpeg(self):
        if self.ffmpeg_proc is not None:
            try:
                self.ffmpeg_proc.stdin.close()
            except Exception:
                pass
            self.ffmpeg_proc.terminate()
            try:
                self.ffmpeg_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.ffmpeg_proc.kill()
            self.ffmpeg_proc = None

    def destroy_node(self):
        self._stop_ffmpeg()
        super().destroy_node()


def main():
    rclpy.init()
    node = RtspPublisher()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
