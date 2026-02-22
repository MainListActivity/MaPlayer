(function () {
  'use strict';

  const PLAY_CLASS = 'ma-player-injected-btn';
  const AUTO_FLAG_KEY = 'ma_player_auto_detail_open_ts';
  const AUTO_CONTEXT_KEY = 'ma_player_auto_detail_context_v1';
  const AUTO_MAX_AGE_MS = 2 * 60 * 1000;
  const AUTO_PLAYED_KEY = '__maPlayerAutoPlayedForUrl';
  const BRIDGE_STATE_KEY = '__maPlayerBridgeState';

  const state = window[BRIDGE_STATE_KEY] || {
    handlerName: 'maPlayerPlay',
    errorHandlerName: 'maPlayerBridgeError',
    remoteJsUrl: null,
    remoteTimeoutMs: 2000,
    detailClickHooked: false,
  };
  window[BRIDGE_STATE_KEY] = state;

  function toAbsolute(url) {
    try {
      return new URL(url, location.href).toString();
    } catch (_) {
      return '';
    }
  }

  function callHandler(handlerName, payload) {
    try {
      if (
        !window.flutter_inappwebview ||
        typeof window.flutter_inappwebview.callHandler !== 'function'
      ) {
        return;
      }
      window.flutter_inappwebview.callHandler(handlerName, payload);
    } catch (_) {
      // no-op
    }
  }

  function reportError(message) {
    callHandler(state.errorHandlerName, {
      message: String(message || 'bridge error'),
      pageUrl: location.href,
      timestamp: Date.now(),
    });
  }

  function textOf(node) {
    if (!node || !node.textContent) return '';
    return String(node.textContent).trim();
  }

  function extractCoverUrl(imgNode) {
    if (!imgNode) return '';
    const isLazy = !!(
      imgNode.classList &&
      imgNode.classList.contains('lazyload')
    );
    const srcSet = isLazy
      ? imgNode.getAttribute('data-src') ||
        imgNode.getAttribute('data-original') ||
        imgNode.getAttribute('data-lazy-src') ||
        ''
      : imgNode.currentSrc ||
        imgNode.getAttribute('data-src') ||
        imgNode.getAttribute('data-original') ||
        imgNode.getAttribute('data-lazy-src') ||
        imgNode.getAttribute('src') ||
        '';
    if (!srcSet) return '';
    const first = srcSet.split(',')[0].trim().split(' ')[0].trim();
    return toAbsolute(first);
  }

  function extractDetailCoverFromDataSrc() {
    const detailImgNode = document.querySelector(
      '.module-item-pic img.lazyload, .myui-content__thumb img.lazyload, .stui-content__thumb img.lazyload, img.lazyload'
    );
    if (!detailImgNode) return '';
    const dataSrc =
      detailImgNode.getAttribute('data-src') ||
      detailImgNode.getAttribute('data-original') ||
      detailImgNode.getAttribute('data-lazy-src') ||
      '';
    if (!dataSrc) return '';
    const first = dataSrc.split(',')[0].trim().split(' ')[0].trim();
    return toAbsolute(first);
  }

  function extractAdjacentImageCover(anchor) {
    if (!anchor || !anchor.nextElementSibling) return '';
    const next = anchor.nextElementSibling;
    if (!next || String(next.tagName || '').toUpperCase() !== 'IMG') {
      return '';
    }
    const dataSrc = next.getAttribute('data-src') || '';
    const src = next.getAttribute('src') || next.currentSrc || '';
    return toAbsolute((dataSrc || src).trim());
  }

  function shouldMarkAutoForClick(anchor) {
    if (!anchor) return false;
    const href = anchor.getAttribute('href') || '';
    if (!href || href.startsWith('javascript:') || href.startsWith('#')) {
      return false;
    }
    if (/pan\.quark\.cn\/s\//i.test(href)) return false;
    let target;
    try {
      target = new URL(href, location.href);
    } catch (_) {
      return false;
    }
    if (target.origin !== location.origin) return false;
    const path = target.pathname.toLowerCase();
    if (path === location.pathname && target.search === location.search) {
      return false;
    }
    if (/(voddetail|detail|movie|tv|film|video|vod|show)/.test(path)) {
      return true;
    }
    return !!anchor.closest(
      '.module-item, .myui-vodlist__box, .stui-vodlist__box, .video-item, .post'
    );
  }

  function saveAutoContext(anchor) {
    if (!anchor) return;
    const card =
      anchor.closest(
        'article, .post, .item, .entry, li, .module-item, .module-info, .myui-content__detail, .stui-content__detail'
      ) || document.body;
    const titleNode =
      card.querySelector(
        'h1, h2, h3, .title, .module-item-title, .entry-title, .page-title, .video-info-header h1, .myui-content__detail .title'
      ) || anchor;
    const introNode = card.querySelector(
      '.video-info-content, .module-info-introduction-content, .desc, .module-item-note, .entry-content, .myui-content__detail .data, .stui-content__detail p, p'
    );
    const payload = {
      title: textOf(titleNode),
      intro: textOf(introNode),
      cover: extractAdjacentImageCover(anchor),
      href: toAbsolute(anchor.getAttribute('href') || anchor.href || ''),
      pageUrl: location.href,
    };
    try {
      sessionStorage.setItem(AUTO_CONTEXT_KEY, JSON.stringify(payload));
    } catch (_) {
      // no-op
    }
  }

  function loadAutoContext() {
    try {
      const raw = sessionStorage.getItem(AUTO_CONTEXT_KEY) || '';
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object') return null;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  function extractLocalPayload(anchor, autoContext) {
    const card =
      anchor.closest(
        'article, .post, .item, .entry, li, .module-item, .module-info, .myui-content__detail, .stui-content__detail'
      ) || document.body;
    const titleNode =
      card.querySelector(
        'h1, h2, h3, .title, .module-item-title, .entry-title, .page-title, .video-info-header h1, .myui-content__detail .title'
      ) || anchor;
    const introNode = card.querySelector(
      '.video-info-content, .module-info-introduction-content, .desc, .module-item-note, .entry-content, .myui-content__detail .data, .stui-content__detail p, p'
    );
    const imgNode = card.querySelector(
      'img[data-src], img[data-original], img[src], .module-item-pic img, .myui-content__thumb img, .stui-content__thumb img'
    );

    const adjacentCover = extractAdjacentImageCover(anchor);
    const detailCover = extractDetailCoverFromDataSrc();
    const fallbackCover = extractCoverUrl(imgNode);
    const cover =
      adjacentCover ||
      detailCover ||
      fallbackCover ||
      ((autoContext && autoContext.cover) || '');

    const shareUrl = toAbsolute(anchor.getAttribute('href') || anchor.href || '');
    const title =
      textOf(titleNode) ||
      String(document.title || '').trim() ||
      ((autoContext && autoContext.title) || '');
    const intro = textOf(introNode) || ((autoContext && autoContext.intro) || '');

    return {
      shareUrl: shareUrl,
      pageUrl: location.href,
      title: title,
      intro: intro,
      cover: cover,
      coverHeaders: cover
        ? { Referer: location.href, Origin: location.origin }
        : {},
    };
  }

  function buildSnapshot(anchor, localPayload, autoContext) {
    const next = anchor ? anchor.nextElementSibling : null;
    const nextImg =
      next && String(next.tagName || '').toUpperCase() === 'IMG' ? next : null;
    const card =
      anchor &&
      (anchor.closest(
        'article, .post, .item, .entry, li, .module-item, .module-info, .myui-content__detail, .stui-content__detail'
      ) ||
        null);

    return {
      html: document.documentElement ? document.documentElement.outerHTML : '',
      url: location.href,
      title: String(document.title || ''),
      referrer: String(document.referrer || ''),
      charset: String(document.characterSet || ''),
      readyState: String(document.readyState || ''),
      localPayload: localPayload,
      autoContext: autoContext || null,
      anchor: {
        href: toAbsolute(anchor ? anchor.getAttribute('href') || anchor.href || '' : ''),
        text: textOf(anchor),
        outerHTML: anchor && anchor.outerHTML ? String(anchor.outerHTML) : '',
        nextSiblingImage: nextImg
          ? {
              dataSrc: String(nextImg.getAttribute('data-src') || ''),
              src: String(nextImg.getAttribute('src') || ''),
              currentSrc: String(nextImg.currentSrc || ''),
              outerHTML: String(nextImg.outerHTML || ''),
            }
          : null,
      },
      card: {
        outerHTML: card && card.outerHTML ? String(card.outerHTML) : '',
      },
    };
  }

  function sanitizeRemoteResult(result) {
    if (!result || typeof result !== 'object') {
      throw new Error('Remote analyzer result must be an object.');
    }
    const normalized = {};
    if (typeof result.shareUrl === 'string') {
      normalized.shareUrl = result.shareUrl.trim();
    }
    if (typeof result.title === 'string') {
      normalized.title = result.title.trim();
    }
    if (typeof result.intro === 'string') {
      normalized.intro = result.intro.trim();
    }
    if (typeof result.cover === 'string') {
      normalized.cover = result.cover.trim();
    }
    return normalized;
  }

  function mergePayload(localPayload, remoteResult) {
    const merged = {
      shareUrl: localPayload.shareUrl,
      pageUrl: localPayload.pageUrl,
      title: localPayload.title,
      intro: localPayload.intro,
      cover: localPayload.cover,
      coverHeaders: localPayload.coverHeaders,
    };
    if (remoteResult && typeof remoteResult === 'object') {
      if (typeof remoteResult.shareUrl === 'string' && remoteResult.shareUrl) {
        merged.shareUrl = toAbsolute(remoteResult.shareUrl);
      }
      if (typeof remoteResult.title === 'string' && remoteResult.title) {
        merged.title = remoteResult.title;
      }
      if (typeof remoteResult.intro === 'string') {
        merged.intro = remoteResult.intro;
      }
      if (typeof remoteResult.cover === 'string' && remoteResult.cover) {
        merged.cover = toAbsolute(remoteResult.cover);
      }
    }
    merged.coverHeaders = merged.cover
      ? { Referer: location.href, Origin: location.origin }
      : {};
    return merged;
  }

  function escapeHtml(raw) {
    return String(raw)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function escapeJs(raw) {
    return String(raw)
      .replace(/\\/g, '\\\\')
      .replace(/'/g, "\\'")
      .replace(/\n/g, '\\n')
      .replace(/\r/g, '\\r')
      .replace(/</g, '\\x3c');
  }

  function createSandboxSrcdoc(remoteJsUrl, token, remoteOrigin) {
    const csp =
      "default-src 'none'; connect-src 'none'; img-src 'none'; media-src 'none'; frame-src 'none'; child-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; navigate-to 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline' " +
      remoteOrigin +
      ';';

    return (
      '<!doctype html><html><head><meta charset="utf-8">' +
      '<meta http-equiv="Content-Security-Policy" content="' +
      escapeHtml(csp) +
      '"></head><body><script>' +
      "(function(){'use strict';" +
      "const TOKEN='" +
      escapeJs(token) +
      "';" +
      "function block(name){try{Object.defineProperty(globalThis,name,{value:function(){throw new Error(name+' blocked');},configurable:false,writable:false});}catch(_){}}" +
      "block('fetch');block('XMLHttpRequest');block('WebSocket');block('EventSource');" +
      "if(navigator&&navigator.sendBeacon){try{navigator.sendBeacon=function(){throw new Error('sendBeacon blocked');};}catch(_){}}" +
      "if(window&&window.open){try{window.open=function(){throw new Error('window.open blocked');};}catch(_){}}" +
      "try{location.assign=function(){throw new Error('location.assign blocked');};location.replace=function(){throw new Error('location.replace blocked');};}catch(_){}" +
      "const blocked=new Set(['script','img','iframe','frame','link','audio','video','source','object','embed','form']);" +
      "const rawCreate=Document.prototype.createElement;" +
      "Document.prototype.createElement=function(tagName,options){const tag=String(tagName||'').toLowerCase();if(blocked.has(tag)){throw new Error('blocked element '+tag);}return rawCreate.call(this,tagName,options);};" +
      "window.addEventListener('message',async function(event){const data=event&&event.data?event.data:{};if(!data||data.type!=='ma-player-run-analyze'||data.token!==TOKEN){return;}try{const analyzer=globalThis.MaPlayerRemoteAnalyzer;if(!analyzer||typeof analyzer.analyze!=='function'){throw new Error('MaPlayerRemoteAnalyzer.analyze is missing.');}const result=await Promise.resolve(analyzer.analyze(data.snapshot));parent.postMessage({type:'ma-player-remote-result',token:TOKEN,ok:true,result:result},'*');}catch(err){const message=err&&err.message?err.message:String(err||'remote analyzer failed');parent.postMessage({type:'ma-player-remote-result',token:TOKEN,ok:false,error:message},'*');}});" +
      '})();' +
      '</script><script src="' +
      escapeHtml(remoteJsUrl) +
      '"></script></body></html>'
    );
  }

  function runRemoteAnalyzer(snapshot, remoteJsUrl, timeoutMs) {
    return new Promise(function (resolve, reject) {
      let remoteUrl;
      try {
        remoteUrl = new URL(remoteJsUrl, location.href).toString();
      } catch (_) {
        reject(new Error('Invalid remote JS URL.'));
        return;
      }
      if (!/^https?:\/\//i.test(remoteUrl)) {
        reject(new Error('Remote JS URL must be http/https.'));
        return;
      }

      const remoteOrigin = new URL(remoteUrl).origin;
      const token = 'ma-' + Date.now() + '-' + Math.random().toString(36).slice(2);
      const frame = document.createElement('iframe');
      frame.style.display = 'none';
      frame.setAttribute('sandbox', 'allow-scripts');

      let finished = false;
      let timer = null;

      function done(err, result) {
        if (finished) return;
        finished = true;
        if (timer !== null) {
          clearTimeout(timer);
        }
        window.removeEventListener('message', onMessage);
        try {
          frame.remove();
        } catch (_) {
          // no-op
        }
        if (err) {
          reject(err);
        } else {
          resolve(result);
        }
      }

      function onMessage(event) {
        if (!frame.contentWindow || event.source !== frame.contentWindow) {
          return;
        }
        const data = event && event.data ? event.data : null;
        if (!data || data.type !== 'ma-player-remote-result' || data.token !== token) {
          return;
        }
        if (data.ok) {
          try {
            done(null, sanitizeRemoteResult(data.result));
          } catch (error) {
            done(error instanceof Error ? error : new Error(String(error)));
          }
          return;
        }
        done(new Error(String(data.error || 'Remote analyzer failed.')));
      }

      window.addEventListener('message', onMessage);
      timer = setTimeout(function () {
        done(new Error('Remote analyzer timeout.'));
      }, timeoutMs);

      frame.addEventListener(
        'load',
        function () {
          try {
            if (frame.contentWindow) {
              frame.contentWindow.postMessage(
                {
                  type: 'ma-player-run-analyze',
                  token: token,
                  snapshot: snapshot,
                },
                '*'
              );
            }
          } catch (error) {
            done(error instanceof Error ? error : new Error(String(error)));
          }
        },
        { once: true }
      );

      frame.srcdoc = createSandboxSrcdoc(remoteUrl, token, remoteOrigin);
      (document.documentElement || document.body || document).appendChild(frame);
    });
  }

  function listShareAnchors() {
    return document.querySelectorAll(
      'a[href^="https://pan.quark.cn/s/"], a[href^="http://pan.quark.cn/s/"]'
    );
  }

  async function triggerPlay(anchor, autoContext) {
    const localPayload = extractLocalPayload(anchor, autoContext);
    let payload = localPayload;
    const remoteJsUrl = state.remoteJsUrl;
    if (remoteJsUrl) {
      try {
        const snapshot = buildSnapshot(anchor, localPayload, autoContext);
        const remote = await runRemoteAnalyzer(
          snapshot,
          remoteJsUrl,
          state.remoteTimeoutMs
        );
        payload = mergePayload(localPayload, remote);
      } catch (error) {
        const message =
          error && error.message
            ? error.message
            : String(error || 'remote analyze failed');
        reportError(message);
        payload = localPayload;
      }
    }
    callHandler(state.handlerName, payload);
  }

  function ensureDetailClickHook() {
    if (state.detailClickHooked) return;
    document.addEventListener(
      'click',
      function (evt) {
        const anchor =
          evt.target && evt.target.closest ? evt.target.closest('a[href]') : null;
        if (!anchor) return;
        if (!shouldMarkAutoForClick(anchor)) return;
        try {
          sessionStorage.setItem(AUTO_FLAG_KEY, String(Date.now()));
        } catch (_) {
          // no-op
        }
        saveAutoContext(anchor);
      },
      true
    );
    state.detailClickHooked = true;
  }

  function ensurePlayButtons() {
    const links = listShareAnchors();
    links.forEach(function (anchor) {
      const next = anchor.nextElementSibling;
      if (next && next.classList && next.classList.contains(PLAY_CLASS)) {
        return;
      }
      const btn = document.createElement('button');
      btn.textContent = '播放';
      btn.className = PLAY_CLASS;
      btn.style.marginLeft = '8px';
      btn.style.padding = '2px 8px';
      btn.style.fontSize = '12px';
      btn.style.background = '#f47b25';
      btn.style.border = 'none';
      btn.style.color = '#fff';
      btn.style.borderRadius = '8px';
      btn.style.cursor = 'pointer';
      btn.onclick = function (evt) {
        evt.preventDefault();
        evt.stopPropagation();
        triggerPlay(anchor, null);
        return false;
      };
      anchor.insertAdjacentElement('afterend', btn);
    });
  }

  function maybeAutoPlay() {
    const autoTs = Number(sessionStorage.getItem(AUTO_FLAG_KEY) || '0');
    const shouldAutoPlay =
      Number.isFinite(autoTs) &&
      autoTs > 0 &&
      Date.now() - autoTs <= AUTO_MAX_AGE_MS;
    if (!shouldAutoPlay) {
      return;
    }
    if (window[AUTO_PLAYED_KEY] === location.href) {
      return;
    }
    const links = listShareAnchors();
    const firstLink = links.length > 0 ? links[0] : null;
    if (!firstLink) {
      return;
    }
    window[AUTO_PLAYED_KEY] = location.href;
    sessionStorage.removeItem(AUTO_FLAG_KEY);
    const autoContext = loadAutoContext();
    sessionStorage.removeItem(AUTO_CONTEXT_KEY);
    setTimeout(function () {
      triggerPlay(firstLink, autoContext);
    }, 60);
  }

  function init(config) {
    const options = config && typeof config === 'object' ? config : {};
    const handlerName = String(options.handlerName || 'maPlayerPlay').trim();
    const errorHandlerName = String(
      options.errorHandlerName || 'maPlayerBridgeError'
    ).trim();
    const remoteJsUrl =
      typeof options.remoteJsUrl === 'string'
        ? options.remoteJsUrl.trim()
        : '';
    const timeout = Number(options.remoteTimeoutMs || 2000);

    state.handlerName = handlerName || 'maPlayerPlay';
    state.errorHandlerName = errorHandlerName || 'maPlayerBridgeError';
    state.remoteJsUrl = remoteJsUrl || null;
    state.remoteTimeoutMs =
      Number.isFinite(timeout) && timeout > 0 ? timeout : 2000;

    ensureDetailClickHook();
    ensurePlayButtons();
    maybeAutoPlay();
  }

  window.MaPlayerBridge = {
    init: init,
  };
})();
