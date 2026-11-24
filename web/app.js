(function () {
  var $ = function (id) { return document.getElementById(id); };
  var video = $('video'), outline = $('outline'), finder = $('finder'), statusEl = $('status');
  var frame = document.createElement('canvas');
  var fctx = frame.getContext('2d', { willReadFrequently: true });
  var detector = new AR.Detector({ dictionaryName: 'ARUCO_MIP_36h12', maxHammingDistance: 5 });

  // The token arrives in the URL fragment, which is never sent to the server.
  var token = '';
  try { token = localStorage.getItem('token') || ''; } catch (e) {}
  function readHash() {
    var match = /t=([0-9a-f]+)/.exec(location.hash);
    if (!match) return;
    token = match[1];
    try { localStorage.setItem('token', token); } catch (e) {}
    history.replaceState(null, '', location.pathname);
  }
  readHash();
  window.addEventListener('hashchange', readHash);

  var layout = null, aim = null, aimTime = 0, busy = false, stream = null, starting = false;
  var lastError = '', cameraError = '', flashUntil = 0, shotUrl = null, shotFile = null;

  function status(text) { if (statusEl.textContent !== text) statusEl.textContent = text; }
  function flash(text) { status(text); flashUntil = Date.now() + 2500; }
  function describe(e) { return e instanceof TypeError ? 'Cannot reach the PC.' : e.message; }

  function api(method, path, extra) {
    var options = Object.assign({ method: method, headers: { Authorization: 'Bearer ' + token } }, extra);
    return fetch(path, options).then(function (r) {
      if (r.ok) return r;
      return r.text().then(function (t) {
        if (r.status === 401) t = 'Not paired. Scan the QR code from the PC tray menu.';
        if (r.status >= 502) t = 'CameraShots is not running on the PC.';
        throw new Error(t);
      });
    });
  }

  function active() { return !document.hidden && $('result').hidden; }

  function heartbeat() {
    if (!active() || !token) return Promise.resolve();
    return api('POST', '/api/heartbeat').then(function (r) { return r.text(); }).then(function (v) {
      if (!active()) { stop(); return; } // closed while the request was in flight
      if (layout && layout.version === +v) return;
      return api('GET', '/api/layout').then(function (r) { return r.json(); }).then(function (l) {
        layout = l;
        aim = null;
      });
    }).then(function () { lastError = ''; }, function (e) { lastError = describe(e); });
  }
  function stop() { if (token) api('POST', '/api/stop', { keepalive: true }).catch(function () {}); }

  function startCamera() {
    if (starting || (stream && stream.getVideoTracks()[0].readyState === 'live')) return;
    if (!navigator.mediaDevices) { cameraError = 'The camera needs an HTTPS address.'; return; }
    starting = true;
    navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } }
    }).then(function (s) {
      starting = false;
      cameraError = '';
      stream = s;
      if (document.hidden) { stopCamera(); return; }
      video.srcObject = s;
      return video.play();
    }).catch(function (e) {
      starting = false;
      cameraError = 'Camera unavailable: ' + e.message;
    });
  }
  function stopCamera() {
    if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
    stream = null;
  }

  // The part of the frame visible in the viewfinder (object-fit: cover).
  function visibleView() {
    var s = Math.max(finder.clientWidth / frame.width, finder.clientHeight / frame.height);
    var w = finder.clientWidth / s, h = finder.clientHeight / s;
    var x = (frame.width - w) / 2, y = (frame.height - h) / 2;
    return [{ x: x, y: y }, { x: x + w, y: y }, { x: x + w, y: y + h }, { x: x, y: y + h }];
  }

  function drawOutlines(markers) {
    if (outline.width !== frame.width || outline.height !== frame.height) {
      outline.width = frame.width;
      outline.height = frame.height;
    }
    var c = outline.getContext('2d');
    c.clearRect(0, 0, outline.width, outline.height);
    c.strokeStyle = '#ffd21f';
    c.lineWidth = 3;
    markers.forEach(function (m) {
      c.beginPath();
      m.corners.forEach(function (p) { c.lineTo(p.x, p.y); });
      c.closePath();
      c.stroke();
    });
  }

  // Small picture of the monitor with the aimed region filled in.
  function drawMap() {
    var map = $('map'), c = map.getContext('2d');
    map.width = 192;
    map.height = 120;
    if (!layout || !aim || !layout.monitors[aim.m]) return;
    var mon = layout.monitors[aim.m], s = Math.min(188 / mon.w, 116 / mon.h);
    c.translate((192 - mon.w * s) / 2, (120 - mon.h * s) / 2);
    c.fillStyle = '#ffd21f';
    c.fillRect(aim.x * s, aim.y * s, aim.w * s, aim.h * s);
    c.strokeStyle = '#aaa';
    c.lineWidth = 2;
    c.strokeRect(0, 0, mon.w * s, mon.h * s);
  }

  function scan() {
    if (!active()) return;
    if (layout && video.videoWidth && video.readyState >= 2) {
      var s = Math.min(1, 1280 / Math.max(video.videoWidth, video.videoHeight));
      var w = Math.round(video.videoWidth * s), h = Math.round(video.videoHeight * s);
      if (frame.width !== w || frame.height !== h) { frame.width = w; frame.height = h; }
      fctx.drawImage(video, 0, 0, w, h);
      var markers = detector.detect(fctx.getImageData(0, 0, w, h));
      var found = Region.locate(markers, layout, visibleView());
      if (found) { aim = found; aimTime = Date.now(); }
      else if (Date.now() - aimTime > 500) aim = null;
      drawOutlines(markers);
      drawMap();
    }
    var ready = !!aim && !busy && !lastError && !cameraError;
    $('shutter').disabled = !ready;
    finder.classList.toggle('ready', ready);
    if (Date.now() < flashUntil) return;
    if (!token) status('Scan the QR code from the PC tray menu.');
    else if (cameraError || lastError) status(cameraError || lastError);
    else if (busy) status('Capturing…');
    else if (!aim) status('Point at your monitor');
    else status(aim.w + ' × ' + aim.h + (aim.markers === 1 ? ' (approximate, 1 marker)' : ''));
  }

  function tick() {
    try { scan(); } catch (e) { console.error(e); }
    setTimeout(tick, 60);
  }

  $('shutter').onclick = function () {
    if (!aim || busy) return;
    busy = true;
    var a = aim;
    api('POST', '/api/capture?v=' + a.version + '&m=' + a.m + '&x=' + a.x + '&y=' + a.y + '&w=' + a.w + '&h=' + a.h)
      .then(function (r) {
        $('copied').textContent = r.headers.get('X-Copied') ? 'Copied to PC clipboard' : '';
        return r.blob();
      })
      .then(function (blob) {
        if (shotUrl) URL.revokeObjectURL(shotUrl);
        shotUrl = URL.createObjectURL(blob);
        shotFile = new File([blob], 'screenshot.png', { type: 'image/png' });
        $('shot').src = shotUrl;
        $('share').hidden = !(navigator.canShare && navigator.canShare({ files: [shotFile] }));
        $('result').hidden = false;
        stop();
      })
      .catch(function (e) { flash(describe(e)); })
      .finally(function () { busy = false; });
  };
  $('share').onclick = function () { navigator.share({ files: [shotFile] }).catch(function () {}); };
  $('again').onclick = function () { $('result').hidden = true; aim = null; heartbeat(); };

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) {
      stop();
      stopCamera();
    } else {
      startCamera();
      heartbeat();
    }
  });
  window.addEventListener('pagehide', stop);

  (function beat() { heartbeat().finally(function () { setTimeout(beat, 1500); }); })();
  startCamera();
  tick();
})();
