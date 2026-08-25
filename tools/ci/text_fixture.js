/* Coins WORST-CASE RENDERER FIXTURE — the LLM text no CI replay can carry.
 *
 * Goes to:  tools/ci/text_fixture.js. Assembled into a runnable page by
 *           tools/ci/build_text_fixture.sh and driven by
 *           `viewer_smoke.mjs --bundle <that page> --strict-text-bounds`
 *           in ci.yml's `wasm-viewer` job.
 *
 * WHY THIS EXISTS
 * ---------------
 * docker_smoke.sh runs with no ANTHROPIC_API_KEY, so every seat falls back to
 * a scripted baseline, and a scripted `Decision` carries no `say` (see
 * src/coins/llm.nim's fallbackDecision/scriptedDecision). EVERY replay CI can
 * produce therefore carries zero LLM-authored text, and the viewer smoke that
 * loads that replay reports `feed_lines: 0` and `canvas text: 0 drawn` — it
 * covers the whole class of chrome that exists only to show what a model
 * said, which is to say it covers nothing (prompts/30-review-loop.md item 15,
 * "the CI replay cannot talk"; cogchemists 2026-08-24 shipped four clipped
 * speech bubbles behind a fully green board for exactly this reason).
 *
 * So this fixture hands the REAL page a frame built to hurt:
 *   - the real client/replay_broadcast.html, spliced with the real
 *     chrome_common.js / broadcast_core.js / wire_constants.js the server and
 *     the hosted bundle serve (build_text_fixture.sh does the same three
 *     splices Dockerfile.replay-viewer does);
 *   - the page's own socket stubbed, so the frames below arrive through the
 *     page's REAL ingest path: onText -> onFrame -> CoinsGame.onFrame ->
 *     cnApplyEvent -> cnPushRow -> the chrome's pushFeed;
 *   - a full-cap 48-rune remark (MaxSayLen, src/coins/sim_types.nim) on EVERY
 *     seat at once, four such rows at a time — the feed's MAX_FEED — in the
 *     three shapes that hurt most: the widest Latin run, full-width CJK, and
 *     a real sentence;
 *   - at six stage widths, from the 360 px featured-match iframe up past the
 *     --hudscale clamp.
 *
 * It then asserts, per line box:
 *   (a) the remark is still FULL LENGTH — one quietly shortened string would
 *       leave a fixture passing while testing nothing;
 *   (b) every line of it is inside the RESERVED BAND the layout gives it —
 *       the feed's own box — and that band is inside the stage and clear of
 *       the reserved scorebug band;
 *   (c) nothing is clipped (the ink box fits the element box).
 * Failure sets data-replay-error, which viewer_smoke.mjs fails on; success
 * sets data-replay-loaded="true".
 *
 * Every measured line is ALSO mirrored onto a 2D canvas the size of that
 * band, at the position and font the browser laid it out with, so
 * `--strict-text-bounds` reports a real `canvas_text` count over real model
 * text instead of the `total: 0` that "means the check covered nothing" — and
 * so a remark that outgrows its band is `never_inside` there as well as a
 * data-replay-error here.
 */
(function () {
  'use strict';

  var CAP = 48;                     // MaxSayLen — src/coins/sim_types.nim:61
  var TICKS = 320;                  // the certification fixture's length
  var ALIAS = ['COPPER', 'COBALT'];
  var TEAMS = ['red', 'blue'];
  var POLICIES = ['coins-truce@ply_a1', 'coins-ledger@ply_b2'];

  function repeat(unit, runes) {
    var out = '';
    for (var i = 0; i < runes; i++) out += unit;
    return out;
  }
  function pad(text, unit) {
    // Exactly CAP runes, and never ending in an ellipsis: cleanSay's own
    // truncation marker would be counted as `ellipsized` by the smoke and
    // read as "the box is too small" when it is the server's doing.
    var out = text;
    while (out.length < CAP) out += unit;
    return out.slice(0, CAP);
  }

  var SAMPLES = [
    { name: 'latin-wide', text: repeat('M', CAP) },
    { name: 'cjk', text: repeat('締', CAP) },
    { name: 'sentence',
      text: pad('I take my own coins and leave yours alone', ' .') }
  ];

  // Stage widths. 360 is the Observatory featured-match iframe; 1400 square
  // clears the --hudscale 1.6 clamp at the other end.
  var SIZES = [[360, 640], [414, 736], [620, 480], [760, 428], [1024, 768],
               [1400, 1400]];

  // ------------------------------------------------------------------
  // The stub transport. The page opens exactly one websocket in
  // broadcast_core's connect(); a string message goes straight to onText,
  // which is the page's whole frame-ingest path.
  // ------------------------------------------------------------------
  var live = null;
  function FakeSocket(url) {
    var self = this;
    this.url = url;
    this.readyState = FakeSocket.CONNECTING;
    this.binaryType = 'blob';
    this.onopen = null; this.onmessage = null;
    this.onclose = null; this.onerror = null;
    live = this;
    setTimeout(function () {
      self.readyState = FakeSocket.OPEN;
      if (self.onopen) self.onopen({});
    }, 0);
  }
  FakeSocket.prototype.send = function () {};
  FakeSocket.prototype.close = function () {
    this.readyState = FakeSocket.CLOSED;
  };
  FakeSocket.CONNECTING = 0;
  FakeSocket.OPEN = 1;
  FakeSocket.CLOSING = 2;
  FakeSocket.CLOSED = 3;
  window.WebSocket = FakeSocket;

  function push(state) {
    if (!live || !live.onmessage) {
      throw new Error('the page never opened its broadcast socket');
    }
    live.onmessage({ data: JSON.stringify(state) });
  }

  // The page resolves its art relative to COG_BASE, which is "." exactly when
  // window.CtfStaticReplay is present — i.e. in the hosted static bundle, the
  // delivery mode this fixture is about. Declaring the adapter (and handing
  // the page back the very core it would have built) puts the fixture on that
  // path, so the art it loads is the art the platform serves.
  window.CtfStaticReplay = {
    createCore: function (config) { return window.BroadcastCore.create(config); }
  };

  // ------------------------------------------------------------------
  // Frames. The key set is src/coins/broadcast.nim's buildStateJson —
  // the same object WS /global and the static bundle both send.
  // ------------------------------------------------------------------
  function teamJson(seat, score, thefts) {
    return { lives: score, score: score, thefts: thefts, pickups: 9,
             stolenFrom: 3, policies: [POLICIES[seat]] };
  }
  function rosterJson(scores, thefts) {
    var out = [];
    for (var seat = 0; seat < 2; seat++) {
      out.push({ s: seat, team: TEAMS[seat], name: ALIAS[seat],
                 pol: POLICIES[seat], alias: ALIAS[seat],
                 colour: seat === 0 ? 'copper' : 'cobalt',
                 score: scores[seat], thefts: thefts[seat],
                 alive: true, lives: 0 });
    }
    return out;
  }
  function orderEvent(seat, tick, say) {
    return { t: tick, k: 'order', seat: seat, team: TEAMS[seat],
             intent: seat === 0 ? 'take_theirs' : 'take_mine',
             say: say, notes: repeat('n', 300),
             source: seat === 0 ? 'llm' : 'fallback' };
  }
  function stateJson(tick, events, first) {
    var scores = [7, 4];
    var thefts = [3, 2];
    var state = {
      t: tick, mt: TICKS - 1, ph: 'playing', pl: true, sp: 1, mx: TICKS - 1,
      st: 0, lp: false, sk: false, ff: false, en: true, mm: -1, bs: 1,
      pov: -1,
      // Read by the page's syncBoardAspect: the real 9x9 room is 504x504
      // (CellPx * RoomW, src/coins/sim_types.nim), so the stage takes the
      // shape it has in production rather than the pre-stream default.
      boardW: 504, boardH: 504,
      teams: { red: teamJson(0, scores[0], thefts[0]),
               blue: teamJson(1, scores[1], thefts[1]) },
      roster: rosterJson(scores, thefts),
      events: events || [],
      cn: {
        beat: 9, beats: 16, endBeat: 16, variant: 'standard',
        recip: [[1, 0, 0], [2, 1, 0], [3, 0, 1], [4, 2, 0], [5, 0, 0],
                [6, 1, 1], [7, 0, 0], [8, 0, 2], [9, 1, 0]],
        truce: [[5, 1]], coinsOnBoard: 4,
        score: scores, thefts: thefts,
        policies: POLICIES, aliases: ALIAS, colours: ['copper', 'cobalt'],
        indices: { pickups: [9, 6], thefts: thefts, stolenFrom: [2, 3],
                   restraint: [0.667, 0.667], firstTheftBeat: [2, 3],
                   reciprocityLagBeats: [-1, 1] },
        live: true
      }
    };
    if (first) {
      state.lead = { teams: TEAMS, pts: [[0, 0, 0], [160, 4, 3],
                                        [tick, scores[0], scores[1]]] };
      state.lulls = [[40, 70]];
      state.beats = [{ t: 40, k: 'theft', seat: 0, team: 'red' },
                     { t: 100, k: 'truce', seat: 1, team: 'blue' },
                     { t: 160, k: 'leadchange', seat: 0, team: 'red' }];
    }
    return state;
  }

  // ------------------------------------------------------------------
  // Layout helpers.
  // ------------------------------------------------------------------
  function settle() {
    // Two animation frames for the ResizeObserver-driven relayout() to reach
    // its fixed point, then the feed's entrance animation PLAYED THROUGH TO
    // SETTLE: `.feed-row` slides in from translateX(30 --u), so a row measured
    // mid-flight is legitimately outside its band and would make this fixture
    // race itself.
    return new Promise(function (resolve) {
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          var running = [];
          if (document.getAnimations) {
            document.getAnimations().forEach(function (animation) {
              var name = animation.animationName;
              if (name === 'feedin' || name === 'chippop' ||
                  name === 'feedout') {
                running.push(animation.finished.catch(function () {}));
              }
            });
          }
          Promise.all(running).then(function () {
            requestAnimationFrame(function () { setTimeout(resolve, 40); });
          });
        });
      });
    });
  }

  function setSize(width, height) {
    var viewport = document.getElementById('viewport');
    viewport.style.position = 'absolute';
    viewport.style.inset = 'auto';
    viewport.style.left = '0';
    viewport.style.top = '0';
    viewport.style.width = width + 'px';
    viewport.style.height = height + 'px';
  }

  /* Every line box of an element's text, with the exact text on each line.
     A Range per character, grouped by the top of its client rect: that is the
     browser's own line breaking, so the mirror below draws what the browser
     actually laid out rather than the unwrapped string. */
  function lineBoxes(element) {
    var node = null;
    var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    var lines = [];
    while ((node = walker.nextNode())) {
      var text = node.nodeValue;
      var range = document.createRange();
      var current = null;
      for (var i = 0; i < text.length; i++) {
        range.setStart(node, i);
        range.setEnd(node, i + 1);
        var rect = range.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) continue;
        if (current && Math.abs(rect.top - current.top) < 0.6) {
          current.text += text[i];
          current.right = Math.max(current.right, rect.right);
          current.bottom = Math.max(current.bottom, rect.bottom);
        } else {
          current = { text: text[i], left: rect.left, top: rect.top,
                      right: rect.right, bottom: rect.bottom };
          lines.push(current);
        }
      }
    }
    return lines;
  }

  function fontOf(element) {
    var style = getComputedStyle(element);
    return style.fontStyle + ' ' + style.fontWeight + ' ' + style.fontSize +
      '/' + style.lineHeight + ' ' + style.fontFamily;
  }

  // The mirror canvas: exactly the RESERVED BAND the remark was given
  // (#killfeed's box, 228 --u wide), so a line the browser laid out past the
  // edge of that band is a fillText past the edge of the canvas and
  // `--strict-text-bounds` reports it as never_inside. Before the band
  // existed, a full-cap CJK remark laid out 313 px wide inside a 95 px band
  // at the 360 px featured-match width; that is what this canvas turns into a
  // red job.
  var mirror = document.createElement('canvas');
  mirror.id = 'text-fixture-mirror';
  mirror.style.position = 'fixed';
  mirror.style.left = '-10000px';
  mirror.style.top = '0';
  document.body.appendChild(mirror);

  function mirrorLines(band, lines, font) {
    mirror.width = Math.max(1, Math.round(band.width));
    mirror.height = Math.max(1, Math.round(band.height));
    var ctx = mirror.getContext('2d');
    ctx.font = font;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    for (var i = 0; i < lines.length; i++) {
      // A trailing space at a soft wrap is not rendered by the browser but IS
      // measured by measureText, so trim it: the mirror must draw the ink the
      // page drew, not a phantom pixel of it.
      ctx.fillText(lines[i].text.replace(/\s+$/, ''),
        lines[i].left - band.left, lines[i].top - band.top);
    }
  }

  // ------------------------------------------------------------------
  // The run.
  // ------------------------------------------------------------------
  var failures = [];
  function fail(what) {
    failures.push(what);
    console.error('text-fixture FAIL: ' + what);
  }

  function measure(size, sample) {
    var label = sample.name + ' @ ' + size[0] + 'x' + size[1];
    var stageEl = document.getElementById('stage');
    var stage = stageEl.getBoundingClientRect();
    var root = getComputedStyle(document.documentElement);
    var topBand = parseFloat(root.getPropertyValue('--topband')) || 0;
    var band = parseFloat(root.getPropertyValue('--band')) || 0;
    var feed = document.getElementById('killfeed').getBoundingClientRect();
    var rows = document.querySelectorAll('#killfeed .feed-row');
    if (rows.length < 4) {
      fail(label + ': the feed holds ' + rows.length + ' rows, expected the ' +
        'four full-cap remarks');
      return;
    }
    // The feed is the reserved band: bottom-anchored, 228 --u wide, with
    // #killfeed's own 4-row min-height reserve. It must itself sit inside the
    // stage and clear of the reserved scorebug band, however many lines the
    // four remarks wrapped to.
    if (feed.top < stage.top + topBand - 1 || feed.bottom > stage.bottom + 1 ||
        feed.left < stage.left - 1 || feed.right > stage.right + 1) {
      fail(label + ': the feed itself left the stage: [' +
        Math.round(feed.left - stage.left) + ',' +
        Math.round(feed.top - stage.top) + ' ' +
        Math.round(feed.right - stage.left) + ',' +
        Math.round(feed.bottom - stage.top) + '] in ' +
        Math.round(stage.width) + 'x' + Math.round(stage.height) +
        ' (top band ' + Math.round(topBand) + ')');
    }
    var widest = 0;
    for (var r = 0; r < rows.length; r++) {
      var row = rows[r];
      var say = row.querySelector('.cn-say');
      if (!say) {
        fail(label + ': an order row carries no .cn-say span');
        continue;
      }
      // (a) full length. A renderer that quietly shortened the remark would
      // otherwise leave every geometric check below passing.
      var want = '\u201c' + sample.text + '\u201d';
      if (say.textContent !== want) {
        fail(label + ': the remark was shortened by the renderer: ' +
          JSON.stringify(say.textContent) + ' != ' + JSON.stringify(want));
        continue;
      }
      var lines = lineBoxes(say);
      if (!lines.length) {
        fail(label + ': the remark laid out no line boxes at all');
        continue;
      }
      var rowBox = row.getBoundingClientRect();
      widest = Math.max(widest, rowBox.width);
      // (c) not clipped: the ink box fits the element box.
      if (say.scrollWidth > say.clientWidth + 1 && say.clientWidth > 0) {
        fail(label + ': the remark overflows its own box (' + say.scrollWidth +
          ' > ' + say.clientWidth + ')');
      }
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        // (b) every line inside the RESERVED BAND — the property the band
        // exists for. `max-width: none; white-space: nowrap` kept every line
        // inside the stage too, and grew the row three times past the band
        // and across the arena, so the stage alone is not the check.
        if (line.left < feed.left - 1 || line.right > feed.right + 1 ||
            line.top < feed.top - 1 || line.bottom > feed.bottom + 1) {
          fail(label + ': line ' + (i + 1) + '/' + lines.length +
            ' of the remark is outside the ' + Math.round(feed.width) +
            'px feed band: [' +
            Math.round(line.left - feed.left) + ',' +
            Math.round(line.top - feed.top) + ' ' +
            Math.round(line.right - feed.left) + ',' +
            Math.round(line.bottom - feed.top) + '] in a band of ' +
            Math.round(feed.width) + 'x' + Math.round(feed.height) +
            ' (stage ' + Math.round(stage.width) + 'x' +
            Math.round(stage.height) + ')');
        }
      }
      mirrorLines(feed, lines, fontOf(say));
    }
    console.log('text-fixture ' + label + ': stage ' +
      Math.round(stage.width) + 'x' + Math.round(stage.height) +
      ', hudscale ' + root.getPropertyValue('--hudscale').trim() +
      ', bands ' + Math.round(topBand) + '/' + Math.round(band) +
      ', ' + rows.length + ' rows, widest row ' + Math.round(widest) + 'px' +
      ', feed band ' + Math.round(feed.width) + 'px' +
      ', feed top/bottom ' + Math.round(feed.top - stage.top) + '/' +
      Math.round(stage.bottom - feed.bottom) + 'px');
  }

  function scenario(size, sample, tick) {
    setSize(size[0], size[1]);
    return settle().then(function () {
      push(stateJson(tick, [], true));
      return settle();
    }).then(function () {
      // Two frames, two seats each: four full-cap remarks in the feed at
      // once, which is MAX_FEED — the worst the row stack can hold.
      push(stateJson(tick + 1,
        [orderEvent(0, tick + 1, sample.text),
         orderEvent(1, tick + 1, sample.text)]));
      push(stateJson(tick + 2,
        [orderEvent(0, tick + 2, sample.text),
         orderEvent(1, tick + 2, sample.text)]));
      return settle();
    }).then(function () {
      measure(size, sample);
    });
  }

  function run() {
    var chain = Promise.resolve();
    var tick = 10;
    SIZES.forEach(function (size) {
      SAMPLES.forEach(function (sample) {
        var at = tick;
        tick += 4;
        chain = chain.then(function () { return scenario(size, sample, at); });
      });
    });
    return chain;
  }

  window.addEventListener('load', function () {
    run().then(function () {
      if (failures.length) {
        document.documentElement.setAttribute('data-replay-error',
          failures.length + ' worst-case remark failure(s): ' + failures[0]);
        return;
      }
      console.log('text-fixture OK: ' + SIZES.length + ' stage sizes x ' +
        SAMPLES.length + ' full-cap remark shapes x 4 rows, every line inside ' +
        'the stage and full length');
      document.documentElement.setAttribute('data-replay-loaded', 'true');
    }).catch(function (error) {
      document.documentElement.setAttribute('data-replay-error',
        'text fixture threw: ' + (error && error.message || error));
    });
  });
})();
