"""模式状态机：MANUAL / AUTO / INSPECTING / CHARGING 四态，单一入口，拒绝非法流转"""
from enum import Enum
from threading import Lock


class Mode(Enum):
    MANUAL = 'manual'
    AUTO = 'auto'
    INSPECTING = 'inspect'
    CHARGING = 'charge'


# 合法流转表（与 architecture.md 3.4 节一致）
_ALLOWED = {
    Mode.MANUAL: {Mode.AUTO, Mode.CHARGING},
    Mode.AUTO: {Mode.MANUAL, Mode.INSPECTING, Mode.CHARGING},
    Mode.INSPECTING: {Mode.AUTO, Mode.MANUAL, Mode.CHARGING},
    Mode.CHARGING: {Mode.AUTO, Mode.MANUAL},
}


class ModeStateMachine:
    """所有模式切换请求经此类单一入口处理，非法流转返回错误码"""

    # 错误码
    OK = 0
    ERR_ILLEGAL_TRANSITION = 1
    ERR_SAME_MODE = 2

    def __init__(self, initial: Mode = Mode.MANUAL):
        self._mode = initial
        self._lock = Lock()
        self._listeners = []

    @property
    def mode(self) -> Mode:
        with self._lock:
            return self._mode

    def add_listener(self, cb):
        """注册模式变化回调 cb(old_mode, new_mode)"""
        self._listeners.append(cb)

    def can_transition(self, target: Mode) -> bool:
        with self._lock:
            return target in _ALLOWED.get(self._mode, set())

    def request(self, target: Mode) -> tuple:
        """请求切换模式。返回 (error_code, message)"""
        with self._lock:
            old = self._mode
            if target == old:
                return self.ERR_SAME_MODE, f'已处于 {old.value} 模式'
            if target not in _ALLOWED.get(old, set()):
                return (self.ERR_ILLEGAL_TRANSITION,
                        f'非法流转: {old.value} -> {target.value}')
            self._mode = target
        for cb in self._listeners:
            try:
                cb(old, target)
            except Exception:
                pass
        return self.OK, 'ok'

    def estop(self):
        """紧急停止：任意状态强制回 MANUAL"""
        with self._lock:
            old = self._mode
            self._mode = Mode.MANUAL
        if old != Mode.MANUAL:
            for cb in self._listeners:
                try:
                    cb(old, Mode.MANUAL)
                except Exception:
                    pass
