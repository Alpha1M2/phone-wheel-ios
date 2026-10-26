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
  Object.defineProperty(navigator, 'vibrate', {configurable:true, value:(pattern) => {
    post({kind:'haptic', pattern}); return true;
  }});
  // Core Motion supplies the same raw gravity vector used by the webpage.
  const requestMotion = async () => { post({kind:'motion'}); return 'granted'; };
  window.__nativeRequestMotion = requestMotion;
  try {
    if (window.DeviceMotionEvent) DeviceMotionEvent.requestPermission = requestMotion;
    else window.DeviceMotionEvent = {requestPermission:requestMotion};
  } catch (_) { post({kind:'motion'}); }
  window.__nativeMotion = (x,y,z) => {
    const event = new Event('devicemotion');
    Object.defineProperty(event, 'accelerationIncludingGravity', {value:{x,y,z}});
    window.dispatchEvent(event);
  };
  document.addEventListener('pointerdown', event => {
    if (event.target.closest?.('[role="button"], button')) post({kind:'tap'});
  }, {passive:true});
})();
