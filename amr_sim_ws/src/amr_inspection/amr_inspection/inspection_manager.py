"""巡检点 / 巡检路线数据管理（内存版，后续可接持久化）"""
import math
from dataclasses import dataclass, field
from threading import Lock
from typing import Dict, List, Optional


@dataclass
class InspectionPoint:
    id: str
    name: str
    x: float
    y: float
    theta: float = 0.0
    dwell_time: float = 3.0       # 到达后停留秒数
    capture_photo: bool = False


@dataclass
class InspectionRoute:
    id: str
    name: str
    point_ids: List[str] = field(default_factory=list)
    loop: bool = False


class InspectionManager:
    """管理巡检点与路线的 CRUD"""

    def __init__(self):
        self._points: Dict[str, InspectionPoint] = {}
        self._routes: Dict[str, InspectionRoute] = {}
        self._lock = Lock()
        self._load_demo_data()

    def _load_demo_data(self):
        """内置演示路线（对应 indoor.world 场景）"""
        self._points = {
            'p1': InspectionPoint('p1', '大厅中央', 0.0, 1.5, 0.0),
            'p2': InspectionPoint('p2', '东房间', 3.0, 1.0, math.pi / 2),
            'p3': InspectionPoint('p3', '南侧走廊', 0.0, -2.0, math.pi),
            'p4': InspectionPoint('p4', '西北角', -4.0, 3.0, 0.0),
        }
        self._routes = {
            'route_1': InspectionRoute('route_1', '常规巡检', ['p1', 'p2', 'p3'], False),
        }

    # ── 巡检点 ──
    def add_point(self, point: InspectionPoint) -> None:
        with self._lock:
            self._points[point.id] = point

    def remove_point(self, point_id: str) -> bool:
        with self._lock:
            return self._points.pop(point_id, None) is not None

    def get_point(self, point_id: str) -> Optional[InspectionPoint]:
        with self._lock:
            return self._points.get(point_id)

    def list_points(self) -> List[InspectionPoint]:
        with self._lock:
            return list(self._points.values())

    # ── 路线 ──
    def add_route(self, route: InspectionRoute) -> None:
        with self._lock:
            self._routes[route.id] = route

    def remove_route(self, route_id: str) -> bool:
        with self._lock:
            return self._routes.pop(route_id, None) is not None

    def get_route(self, route_id: str) -> Optional[InspectionRoute]:
        with self._lock:
            return self._routes.get(route_id)

    def list_routes(self) -> List[InspectionRoute]:
        with self._lock:
            return list(self._routes.values())

    def route_points(self, route_id: str) -> List[InspectionPoint]:
        """展开路线为有序巡检点列表（跳过不存在的点）"""
        route = self.get_route(route_id)
        if route is None:
            return []
        with self._lock:
            pts = [self._points[pid] for pid in route.point_ids
                   if pid in self._points]
        if route.loop and pts:
            pts = pts + [pts[0]]
        return pts
