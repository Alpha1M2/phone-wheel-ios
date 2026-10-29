(() => {
  const post = (message) => window.webkit.messageHandlers.phoneWheel.postMessage(message);
  const sockets = new Map();
  let sequence = 0;
  class NativeSocket extends EventTarget {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor(url) {
      super(); this.id = String(++sequence); this.url = url; this.readyState = 0;
      this.bufferedAmount = 0; sockets.set(this.id, this);
      post({kind:'open', id:this.id});
    }
    send(text) {
      if (this.readyState !== 1) throw new Error('Not connected');
      post({kind:'send', id:this.id, text:String(text)});
    }
    close() {
      if (this.readyState >= 2) return;
      this.readyState = 2; post({kind:'close', id:this.id});
    }
  }
  window.WebSocket = NativeSocket;
  window.__nativeSocketEvent = (id, kind, payload) => {
    const socket = sockets.get(id); if (!socket) return;
    let event;
    if (kind === 'open') { socket.readyState = 1; event = new Event('open'); }
    else if (kind === 'message') event = new MessageEvent('message', {data:payload});
    else if (kind === 'close') {
      socket.readyState = 3; event = new CloseEvent('close', {code:1000}); sockets.delete(id);
    } else event = new Event('error');
    socket.dispatchEvent(event);
    if (typeof socket['on'+kind] === 'function') socket['on'+kind](event);
  };
  window.__nativeSteeringLimit = active => post({kind:'steeringLimit',active:!!active});
  window.__nativeCurbImpact = frame => post({kind:'curbImpact', ...frame});
  window.__nativeRaceFeedback = frame => post({kind:'raceFeedback', ...frame});
  window.__nativePrepareFeedback = () => post({kind:'prepareHaptics'});
  window.__nativeShiftFeedback = () => {
    if(window.controlsEnabled?.()) post({kind:'shift'});
  };
  Object.defineProperty(navigator, 'vibrate', {configurable:true, value:(pattern) => {
    post({kind:'haptic', pattern}); return true;
  }});
  // Core Motion supplies fused gravity, gyro turn rate and monotonic sample time.
  const requestMotion = async () => { post({kind:'motion'}); return 'granted'; };
  window.__nativeRequestMotion = requestMotion;
  window.__nativeStopMotion = () => post({kind:'stopMotion'});
  try {
    if (window.DeviceMotionEvent) DeviceMotionEvent.requestPermission = requestMotion;
    else window.DeviceMotionEvent = {requestPermission:requestMotion};
  } catch (_) { post({kind:'motion'}); }
  window.__nativeMotion = (x,y,z,alpha,timestamp,gyroAngle) => {
    const event = new Event('devicemotion');
    Object.defineProperty(event, 'accelerationIncludingGravity', {value:{x,y,z}});
    Object.defineProperty(event, 'rotationRate', {value:{alpha,beta:0,gamma:0}});
    Object.defineProperty(event, '__nativeSampleTimestamp', {value:timestamp});
    if(Number.isFinite(gyroAngle)) Object.defineProperty(event, '__nativeGyroAngle', {value:gyroAngle});
    window.dispatchEvent(event);
  };
  document.addEventListener('pointerdown', event => {
    if (event.target.closest?.('#gearUpBtn,#gearDownBtn')) {
      window.__nativeShiftFeedback();
      return;
    }
    if (event.target.closest?.('#throttleZone,#brakeZone,#fullThrottleBtn,#fullBrakeBtn')) {
      if(window.controlsEnabled?.()) post({kind:'pedalTap'});
      return;
    }
    if (event.target.closest?.('[role="button"], button')) post({kind:'tap'});
  }, {passive:true});
})();
