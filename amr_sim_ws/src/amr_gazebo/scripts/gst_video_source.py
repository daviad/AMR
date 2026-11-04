#!/usr/bin/env python3
"""GStreamer 虚拟摄像头节点。

把 Gazebo `/camera/image_raw`（或 videotestsrc）编码成两路 H.264 RTSP 流，
推给 MediaMTX；MediaMTX 再以 WebRTC WHEP 提供给 Flutter App。
不再使用"逐帧 JPEG → rosbridge"的视频预览路径，JPEG 只用于拍照。

关键设计：
  - appsrc 由 ROS 图像回调喂入，PTS 使用单调时钟，避免仿真时间跳变；
  - main / low 两路码流（默认 320x240 / 160x120），供 App 弱网降级切换；
  - 在 encoder 输出 pad 上打 probe，统计"采集→编码"分段延迟 P50/P95/P99；
  - 视频健康状态与指标通过 /video/metrics 发布，供可观测性核对。
"""
import os
import threading
import time
from collections import deque

# 无 sudo 安装的 GStreamer 运行环境（见 docs/RUNBOOK.md）。
# LD_LIBRARY_PATH 在进程启动时已固化，这里只影响插件扫描与 GI typelib。
_LOCAL_GST = os.path.expanduser('~/.local/gstreamer')
_local_plugin = os.path.join(
    _LOCAL_GST, 'usr/lib/x86_64-linux-gnu/gstreamer-1.0')
_local_typelib = os.path.join(
    _LOCAL_GST, 'usr/lib/x86_64-linux-gnu/girepository-1.0')
_plugin_paths = [p for p in os.environ.get('GST_PLUGIN_PATH', '').split(':') if p]
if _local_plugin not in _plugin_paths:
    _plugin_paths.append(_local_plugin)
os.environ['GST_PLUGIN_PATH'] = ':'.join(_plugin_paths)
_typelib_paths = [p for p in os.environ.get('GI_TYPELIB_PATH', '').split(':') if p]
if _local_typelib not in _typelib_paths:
    _typelib_paths.append(_local_typelib)
os.environ['GI_TYPELIB_PATH'] = ':'.join(_typelib_paths)
os.environ.setdefault(
    'GST_PLUGIN_SYSTEM_PATH', '/usr/lib/x86_64-linux-gnu/gstreamer-1.0')
os.environ.setdefault('GST_REGISTRY', '/tmp/amr-gst-registry.bin')

import gi  # noqa: E402

gi.require_version('Gst', '1.0')
gi.require_version('GstApp', '1.0')
from gi.repository import Gst, GstApp  # noqa: E402

import cv2  # noqa: E402
import rclpy  # noqa: E402
from cv_bridge import CvBridge  # noqa: E402
from rclpy.node import Node  # noqa: E402
from sensor_msgs.msg import Image  # noqa: E402
from std_msgs.msg import String  # noqa: E402

import json  # noqa: E402


def _percentile(sorted_values, ratio):
    if not sorted_values:
        return None
    idx = min(len(sorted_values) - 1,
              max(0, int(round((len(sorted_values) - 1) * ratio))))
    return round(sorted_values[idx], 2)


class GstVideoSource(Node):
    def __init__(self):
        super().__init__('gst_video_source')

        self.declare_parameter('source', 'gazebo')  # gazebo | test
        self.declare_parameter('image_topic', '/camera/image_raw')
        self.declare_parameter('width', 320)
        self.declare_parameter('height', 240)
        self.declare_parameter('fps', 5.0)
        self.declare_parameter('main_width', 320)
        self.declare_parameter('main_height', 240)
        self.declare_parameter('low_width', 160)
        self.declare_parameter('low_height', 120)
        self.declare_parameter('main_bitrate_kbps', 700)
        self.declare_parameter('low_bitrate_kbps', 220)
        self.declare_parameter('keyframe_interval', 10)
        self.declare_parameter('rtsp_main_url', 'rtsp://127.0.0.1:18554/camera')
        self.declare_parameter('rtsp_low_url',
                               'rtsp://127.0.0.1:18554/camera_low')
        self.declare_parameter('overlay_clock', True)
        self.declare_parameter('restart_backoff_sec', 2.0)
        self.declare_parameter('metrics_period_sec', 1.0)

        self.source_type = self.get_parameter('source').value
        self.image_topic = self.get_parameter('image_topic').value
        self.width = int(self.get_parameter('width').value)
        self.height = int(self.get_parameter('height').value)
        self.fps = float(self.get_parameter('fps').value)
        self.main_w = int(self.get_parameter('main_width').value)
        self.main_h = int(self.get_parameter('main_height').value)
        self.low_w = int(self.get_parameter('low_width').value)
        self.low_h = int(self.get_parameter('low_height').value)
        self.main_kbps = int(self.get_parameter('main_bitrate_kbps').value)
        self.low_kbps = int(self.get_parameter('low_bitrate_kbps').value)
        self.key_int = int(self.get_parameter('keyframe_interval').value)
        self.rtsp_main = self.get_parameter('rtsp_main_url').value
        self.rtsp_low = self.get_parameter('rtsp_low_url').value
        self.overlay_clock = bool(self.get_parameter('overlay_clock').value)
        self.backoff = float(self.get_parameter('restart_backoff_sec').value)

        self.bridge = CvBridge()
        self.pipeline = None
        self.appsrc = None
        self._restart_at = 0.0
        self._last_error = ''
        self._lock = threading.Lock()

        self._frame_w = self.width
        self._frame_h = self.height
        self._t0 = time.monotonic()
        self._last_frame_wall = 0.0
        self._pushed = 0
        self._push_fail = 0
        self._main_encoded = 0
        self._low_encoded = 0
        self._last_main_encoded = 0.0
        self._last_low_encoded = 0.0
        self._push_times = {}  # pts -> (monotonic, consumed_count)
        self._main_lat = deque(maxlen=600)
        self._low_lat = deque(maxlen=600)
        self._main_fps = deque(maxlen=10)
        self._low_fps = deque(maxlen=10)

        self.pub_metrics = self.create_publisher(String, '/video/metrics', 10)
        self.pub_health = self.create_publisher(String, '/video/health', 10)

        Gst.init(None)
        self._build_pipeline()

        if self.source_type == 'gazebo':
            self.sub = self.create_subscription(
                Image, self.image_topic, self._on_image, 1)
        period = float(self.get_parameter('metrics_period_sec').value)
        self._timer = self.create_timer(period, self._on_timer)
        self.get_logger().info(
            f'gst_video_source 启动: source={self.source_type} '
            f'{self.main_w}x{self.main_h}@{self.fps} -> {self.rtsp_main}, '
            f'low {self.low_w}x{self.low_h} -> {self.rtsp_low}')

    # ───────────────────────── pipeline ─────────────────────────
    def _build_pipeline(self):
        self._destroy_pipeline()
        if self.source_type == 'test':
            src = (f'videotestsrc is-live=true pattern=ball '
                   f'! video/x-raw,width={self._frame_w},'
                   f'height={self._frame_h},framerate={int(self.fps)}/1')
        else:
            src = ('appsrc name=src is-live=true format=time '
                   'max-bytes=2000000 block=true do-timestamp=false')
        main_filter = (
            f'video/x-raw,format=I420,width={self.main_w},'
            f'height={self.main_h},framerate={int(self.fps)}/1')
        low_filter = (
            f'video/x-raw,format=I420,width={self.low_w},'
            f'height={self.low_h},framerate={int(self.fps)}/1')
        main_enc = (f'x264enc name=enc_main tune=zerolatency '
                    f'speed-preset=ultrafast '
                    f'bitrate={self.main_kbps} key-int-max={self.key_int} '
                    f'threads=2')
        low_enc = (f'x264enc name=enc_low tune=zerolatency '
                   f'speed-preset=ultrafast '
                   f'bitrate={self.low_kbps} key-int-max={self.key_int} '
                   f'threads=2')
        desc = (
            f'{src} ! videoconvert ! tee name=t '
            f't. ! queue max-size-buffers=3 leaky=downstream ! '
            f'videoscale ! {main_filter} ! {main_enc} ! '
            f'rtspclientsink name=sink_main protocols=tcp '
            f'location={self.rtsp_main} '
            f't. ! queue max-size-buffers=3 leaky=downstream ! '
            f'videoscale ! {low_filter} ! {low_enc} ! '
            f'rtspclientsink name=sink_low protocols=tcp '
            f'location={self.rtsp_low}'
        )
        try:
            pipeline = Gst.parse_launch(desc)
        except Exception as e:  # GLib.Error
            self._last_error = f'pipeline parse: {e}'
            self.get_logger().error(self._last_error)
            self._schedule_restart()
            return
        self.pipeline = pipeline
        if self.source_type == 'gazebo':
            self.appsrc = pipeline.get_by_name('src')
            caps = Gst.Caps.from_string(
                f'video/x-raw,format=BGR,width={self._frame_w},'
                f'height={self._frame_h},framerate={int(self.fps)}/1')
            self.appsrc.set_property('caps', caps)
            self.appsrc.set_property('format', Gst.Format.TIME)

        # 在 encoder 输出打 probe，统计"采集→编码"分段延迟与实际帧率。
        for name, lat, fps_deque in (
                ('enc_main', self._main_lat, self._main_fps),
                ('enc_low', self._low_lat, self._low_fps)):
            enc = pipeline.get_by_name(name)
            if enc is None:
                continue
            pad = enc.get_static_pad('src')
            if pad is None:
                self.get_logger().warn(f'{name} 没有 src pad，跳过指标探针')
                continue
            pad.add_probe(Gst.PadProbeType.BUFFER,
                          self._make_probe(name, lat, fps_deque))

        ret = pipeline.set_state(Gst.State.PLAYING)
        if ret == Gst.StateChangeReturn.FAILURE:
            self._last_error = 'pipeline PLAYING 失败（MediaMTX 未就绪？）'
            self.get_logger().warn(self._last_error)
            self._schedule_restart()
        else:
            self.get_logger().info('GStreamer 管线已启动')

    def _make_probe(self, name, lat_deque, fps_deque):
        def _probe(pad, info):
            buf = info.get_buffer()
            if buf is None:
                return Gst.PadProbeReturn.OK
            now = time.monotonic()
            pts = buf.pts
            with self._lock:
                item = self._push_times.get(pts)
                if item is not None:
                    push_ts, count = item
                    lat_deque.append((now - push_ts) * 1000.0)
                    if count + 1 >= 2:
                        self._push_times.pop(pts, None)
                    else:
                        self._push_times[pts] = (push_ts, count + 1)
                if name == 'enc_main':
                    self._main_encoded += 1
                    self._last_main_encoded = now
                else:
                    self._low_encoded += 1
                    self._last_low_encoded = now
                fps_deque.append(now)
            return Gst.PadProbeReturn.OK
        return _probe

    def _destroy_pipeline(self):
        if self.pipeline is not None:
            try:
                self.pipeline.set_state(Gst.State.NULL)
            except Exception:
                pass
        self.pipeline = None
        self.appsrc = None

    def _schedule_restart(self):
        self._restart_at = time.monotonic() + self.backoff

    # ───────────────────────── Gazebo 图像 ─────────────────────────
    def _on_image(self, msg: Image):
        if self.pipeline is None or self.appsrc is None:
            return
        try:
            frame = self.bridge.imgmsg_to_cv2(msg, desired_encoding='bgr8')
        except Exception as e:
            self.get_logger().warn(f'cv_bridge 转换失败: {e}')
            return
        h, w = frame.shape[:2]
        if (w, h) != (self._frame_w, self._frame_h):
            self.get_logger().info(
                f'图像尺寸变化 {w}x{h}，重建 GStreamer 管线')
            self._frame_w, self._frame_h = w, h
            self._schedule_restart()
            return

        if self.overlay_clock:
            now = time.time()
            stamp = time.strftime('%H:%M:%S', time.localtime(now))
            text = f'{stamp}.{int(now * 1000) % 1000:03d}'
            cv2.putText(frame, text, (4, h - 6),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.38, (0, 0, 0), 1,
                        cv2.LINE_AA)
            cv2.putText(frame, f'#{self._pushed}', (w - 46, 14),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.35, (0, 255, 0), 1,
                        cv2.LINE_AA)

        now = time.monotonic()
        pts = int((now - self._t0) * Gst.SECOND)
        buf = Gst.Buffer.new_wrapped(frame.tobytes())
        buf.pts = pts
        buf.duration = int(Gst.SECOND / max(self.fps, 1.0))
        with self._lock:
            self._push_times[pts] = (now, 0)
            if len(self._push_times) > 1500:
                # 丢弃最老的项，避免长时间运行内存增长
                for key in sorted(self._push_times)[:500]:
                    self._push_times.pop(key, None)
        ret = self.appsrc.emit('push-buffer', buf)
        if ret != Gst.FlowReturn.OK:
            self._push_fail += 1
            self.get_logger().warn(f'push-buffer 失败: {ret}')
            self._schedule_restart()
            return
        self._pushed += 1
        self._last_frame_wall = time.time()
        with self._lock:
            for key in list(self._push_times):
                # 超过 8 秒仍未消费的 PTS 视为丢帧
                if now - self._push_times[key][0] > 8.0:
                    self._push_times.pop(key, None)
                    self._push_fail += 1

    # ───────────────────────── 指标/健康 ─────────────────────────
    def _on_timer(self):
        now = time.monotonic()
        if self.pipeline is None and now >= self._restart_at:
            self.get_logger().info('尝试重建 GStreamer 管线')
            self._build_pipeline()
        elif self.pipeline is not None:
            self._drain_bus(now)
            if self.pipeline is None:
                return

        with self._lock:
            main_lat = sorted(self._main_lat)
            low_lat = sorted(self._low_lat)
            main_recent = list(self._main_fps)
            low_recent = list(self._low_fps)
            pushed = self._pushed
            failed = self._push_fail
            main_enc = self._main_encoded
            low_enc = self._low_encoded
            last_main_enc = self._last_main_encoded
        main_fps = self._rate(main_recent, now)
        low_fps = self._rate(low_recent, now)
        if self.pipeline is None:
            state = 'OFFLINE'
        elif now - max(last_main_enc, 0.0) > 5.0:
            state = 'OFFLINE'
        elif now - max(last_main_enc, 0.0) > 2.0:
            state = 'DEGRADED'
        else:
            state = 'ONLINE'

        metrics = {
            'component': 'gst_video_source',
            'event': 'video_metrics',
            'timestamp_ms': int(time.time() * 1000),
            'state': state,
            'source': self.source_type,
            'pushed': pushed,
            'push_fail': failed,
            'main': {
                'width': self.main_w,
                'height': self.main_h,
                'fps': main_fps,
                'encoded': main_enc,
                'encode_latency_ms': self._lat_stats(main_lat),
            },
            'low': {
                'width': self.low_w,
                'height': self.low_h,
                'fps': low_fps,
                'encoded': low_enc,
                'encode_latency_ms': self._lat_stats(low_lat),
            },
            'last_error': self._last_error,
        }
        msg = String()
        msg.data = json.dumps(metrics, ensure_ascii=False)
        self.pub_metrics.publish(msg)
        health = String()
        health.data = json.dumps(
            {'state': state, 'timestamp_ms': metrics['timestamp_ms'],
             'pushed': pushed, 'main_fps': main_fps,
             'last_error': self._last_error}, ensure_ascii=False)
        self.pub_health.publish(health)

    @staticmethod
    def _rate(timestamps, now):
        if not timestamps:
            return 0.0
        span = now - timestamps[0]
        if span <= 0:
            return 0.0
        return round((len(timestamps) - 1) / span, 2)

    @staticmethod
    def _lat_stats(sorted_values):
        if not sorted_values:
            return {'p50': None, 'p95': None, 'p99': None, 'count': 0}
        return {
            'p50': _percentile(sorted_values, 0.50),
            'p95': _percentile(sorted_values, 0.95),
            'p99': _percentile(sorted_values, 0.99),
            'count': len(sorted_values),
        }

    def _drain_bus(self, now):
        bus = self.pipeline.get_bus()
        while True:
            msg = bus.pop()
            if msg is None:
                break
            if msg.type == Gst.MessageType.ERROR:
                err, dbg = msg.parse_error()
                self._last_error = f'{err.message} ({dbg})'
                self.get_logger().error(f'GStreamer 错误: {self._last_error}')
                self._destroy_pipeline()
                self._schedule_restart()
                break
            if msg.type == Gst.MessageType.EOS:
                self._last_error = 'EOS'
                self._destroy_pipeline()
                self._schedule_restart()
                break

    def destroy_node(self):
        self._destroy_pipeline()
        super().destroy_node()


def main():
    rclpy.init()
    node = GstVideoSource()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
