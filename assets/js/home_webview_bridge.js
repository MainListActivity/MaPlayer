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
    bodySiblingCleanupHooked: false,
    bodySiblingCleanupTimerStarted: false,
    antiDevToolsGuardInstalled: false,
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

  function isLikelyDevToolsProbeSource(source) {
    const text = String(source || '');
    if (!text) return false;
    return (
      /\.toString\s*=\s*function/.test(text) &&
      /console\.(log|debug|dir|info|warn)\s*\(/.test(text)
    );
  }

  function sanitizeConsoleArg(arg) {
    if (!arg || (typeof arg !== 'object' && typeof arg !== 'function')) {
      return arg;
    }
    try {
      const hasOwnToString =
        Object.prototype.hasOwnProperty.call(arg, 'toString') &&
        typeof arg.toString === 'function';
      if (!hasOwnToString) return arg;
      const tag = Object.prototype.toString.call(arg);
      return '[ma-player-console-guard ' + tag + ']';
    } catch (_) {
      return '[ma-player-console-guard]';
    }
  }

  function captureStack() {
    try {
      return String(new Error().stack || '');
    } catch (_) {
      return '';
    }
  }

  function isSuspiciousMutationStack(stack) {
    const text = String(stack || '');
    if (!text) return false;
    if (/\bdetectDevTools\b/i.test(text)) return true;
    if (/\btoString\b/i.test(text) && /\b(console|devtools|debugger|inspect)\b/i.test(text)) {
      return true;
    }
    return false;
  }

  function isCriticalMutationTarget(target) {
    if (!target) return false;
    return (
      target === document ||
      target === document.body ||
      target === document.documentElement
    );
  }

  function shouldBlockMutationForTarget(target) {
    if (!isCriticalMutationTarget(target)) return false;
    return isSuspiciousMutationStack(captureStack());
  }

  function wrapGuardedMethod(owner, methodName, blocker, fallback) {
    if (!owner) return;
    const raw = owner[methodName];
    if (typeof raw !== 'function') return;
    owner[methodName] = function () {
      let blocked = false;
      try {
        blocked = !!blocker.call(this, arguments);
      } catch (_) {
        blocked = false;
      }
      if (blocked) {
        if (typeof fallback === 'function') {
          return fallback.call(this, arguments);
        }
        return undefined;
      }
      return raw.apply(this, arguments);
    };
  }

  function guardSetter(proto, propName, shouldBlockSetter) {
    if (!proto || !propName) return;
    const descriptor = Object.getOwnPropertyDescriptor(proto, propName);
    if (!descriptor || typeof descriptor.set !== 'function') return;
    Object.defineProperty(proto, propName, {
      configurable: true,
      enumerable: descriptor.enumerable,
      get: descriptor.get,
      set: function (value) {
        let blocked = false;
        try {
          blocked = !!shouldBlockSetter.call(this, value);
        } catch (_) {
          blocked = false;
        }
        if (blocked) return;
        return descriptor.set.call(this, value);
      },
    });
  }

  function installAntiDevToolsGuard() {
    if (state.antiDevToolsGuardInstalled) return;
    state.antiDevToolsGuardInstalled = true;

    try {
      if (typeof window.setInterval === 'function') {
        const rawSetInterval = window.setInterval;
        window.setInterval = function (handler) {
          try {
            const source =
              typeof handler === 'function'
                ? Function.prototype.toString.call(handler)
                : String(handler || '');
            if (isLikelyDevToolsProbeSource(source)) {
              return 0;
            }
          } catch (_) {
            // no-op
          }
          return rawSetInterval.apply(this, arguments);
        };
      }
    } catch (_) {
      // no-op
    }

    try {
      if (typeof window.setTimeout === 'function') {
        const rawSetTimeout = window.setTimeout;
        window.setTimeout = function (handler) {
          try {
            const source =
              typeof handler === 'function'
                ? Function.prototype.toString.call(handler)
                : String(handler || '');
            if (isLikelyDevToolsProbeSource(source)) {
              return 0;
            }
          } catch (_) {
            // no-op
          }
          return rawSetTimeout.apply(this, arguments);
        };
      }
    } catch (_) {
      // no-op
    }

    try {
      if (window.console && typeof window.console === 'object') {
        ['log', 'debug', 'dir', 'info', 'warn'].forEach(function (methodName) {
          const method = window.console[methodName];
          if (typeof method !== 'function') return;
          window.console[methodName] = function () {
            const safeArgs = Array.prototype.map.call(arguments, sanitizeConsoleArg);
            return method.apply(this, safeArgs);
          };
        });
      }
    } catch (_) {
      // no-op
    }

    try {
      if (typeof window.alert === 'function') {
        window.alert = function () {
          return undefined;
        };
      }
    } catch (_) {
      // no-op
    }

    try {
      guardSetter(Element.prototype, 'innerHTML', function () {
        return shouldBlockMutationForTarget(this);
      });
    } catch (_) {
      // no-op
    }

    try {
      guardSetter(Element.prototype, 'outerHTML', function () {
        return shouldBlockMutationForTarget(this);
      });
    } catch (_) {
      // no-op
    }

    try {
      guardSetter(Node.prototype, 'textContent', function () {
        return shouldBlockMutationForTarget(this);
      });
    } catch (_) {
      // no-op
    }

    try {
      if (typeof HTMLElement !== 'undefined') {
        guardSetter(HTMLElement.prototype, 'innerText', function () {
          return shouldBlockMutationForTarget(this);
        });
      }
    } catch (_) {
      // no-op
    }

    try {
      wrapGuardedMethod(
        Element.prototype,
        'insertAdjacentHTML',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
    } catch (_) {
      // no-op
    }

    try {
      wrapGuardedMethod(
        Document.prototype,
        'write',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
      wrapGuardedMethod(
        Document.prototype,
        'writeln',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
      wrapGuardedMethod(
        Document.prototype,
        'open',
        function () {
          return shouldBlockMutationForTarget(this);
        },
        function () {
          return this;
        }
      );
      wrapGuardedMethod(
        Document.prototype,
        'close',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
    } catch (_) {
      // no-op
    }

    try {
      wrapGuardedMethod(
        Node.prototype,
        'replaceChild',
        function (args) {
          const oldChild = args && args.length > 1 ? args[1] : null;
          const newChild = args && args.length > 0 ? args[0] : null;
          const touchesCritical =
            isCriticalMutationTarget(this) ||
            oldChild === document.body ||
            oldChild === document.documentElement ||
            newChild === document.body ||
            newChild === document.documentElement;
          return touchesCritical && isSuspiciousMutationStack(captureStack());
        },
        function (args) {
          return args && args.length > 1 ? args[1] : null;
        }
      );
      wrapGuardedMethod(
        Node.prototype,
        'removeChild',
        function (args) {
          const child = args && args.length > 0 ? args[0] : null;
          const touchesCritical =
            isCriticalMutationTarget(this) ||
            child === document.body ||
            child === document.documentElement;
          return touchesCritical && isSuspiciousMutationStack(captureStack());
        },
        function (args) {
          return args && args.length > 0 ? args[0] : null;
        }
      );
      wrapGuardedMethod(
        Node.prototype,
        'appendChild',
        function () {
          return shouldBlockMutationForTarget(this);
        },
        function (args) {
          return args && args.length > 0 ? args[0] : null;
        }
      );
    } catch (_) {
      // no-op
    }

    try {
      wrapGuardedMethod(
        Element.prototype,
        'replaceWith',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
      wrapGuardedMethod(
        Element.prototype,
        'remove',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
      wrapGuardedMethod(
        Element.prototype,
        'replaceChildren',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
      wrapGuardedMethod(
        Element.prototype,
        'append',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
      wrapGuardedMethod(
        Element.prototype,
        'prepend',
        function () {
          return shouldBlockMutationForTarget(this);
        }
      );
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

  function cleanText(raw) {
    if (raw === null || raw === undefined) return '';
    return String(raw).replace(/\s+/g, ' ').trim();
  }

  function pushUniqueText(target, value) {
    const cleaned = cleanText(value);
    if (!cleaned) return;
    if (!target.includes(cleaned)) {
      target.push(cleaned);
    }
  }

  function normalizeYear(raw) {
    const text = cleanText(raw);
    if (!text) return '';
    const match = text.match(/(?:19|20)\d{2}/);
    return match ? match[0] : '';
  }

  function normalizeRating(raw) {
    const text = cleanText(raw);
    if (!text) return '';
    const scoreMatch = text.match(/(?:10(?:\.0)?|[0-9](?:\.[0-9])?)/);
    if (scoreMatch && scoreMatch[0]) {
      return scoreMatch[0];
    }
    return text;
  }

  function normalizeCategory(raw) {
    if (Array.isArray(raw)) {
      const values = [];
      raw.forEach(function (item) {
        if (item && typeof item === 'object') {
          pushUniqueText(values, item.name || item.title || item.value || '');
          return;
        }
        pushUniqueText(values, item);
      });
      return values.join(' / ');
    }
    return cleanText(raw);
  }

  function extractIntro(card, autoContext) {
    const introSelectors =
      '.video-info-content, .module-info-introduction-content, .module-info-desc, .desc, .module-item-note, .entry-content, .myui-content__detail .data, .stui-content__detail p, .detail-content p, .vod_content, p';
    const fromCard = card ? card.querySelector(introSelectors) : null;
    const fromPage = fromCard ? null : document.querySelector(introSelectors);
    const value = cleanText(textOf(fromCard || fromPage));
    if (value) return value;
    return cleanText(
      (autoContext && (autoContext.intro || autoContext.vod_content)) || ''
    );
  }

  function extractYear(card, autoContext) {
    const yearSelectors =
      '.video-info-items, .module-info-item-content, .module-info-tag, .myui-content__detail .data, .stui-content__detail p, [class*="year"], [data-year]';
    const nodes = [];
    if (card) {
      const fromCard = card.querySelectorAll(yearSelectors);
      for (let i = 0; i < fromCard.length; i += 1) {
        nodes.push(fromCard[i]);
      }
    }
    const fromPage = document.querySelectorAll(yearSelectors);
    for (let i = 0; i < fromPage.length; i += 1) {
      nodes.push(fromPage[i]);
    }
    for (let i = 0; i < nodes.length; i += 1) {
      const year = normalizeYear(textOf(nodes[i]));
      if (year) return year;
    }
    const contextYear = normalizeYear(
      autoContext &&
        (autoContext.year ||
          autoContext.vod_year ||
          autoContext.releaseYear ||
          autoContext.publishYear)
    );
    if (contextYear) return contextYear;
    return normalizeYear(document.title || '');
  }

  function extractRating(card, autoContext) {
    const scoreSelectors =
      '.module-info-item-score, .score, .rating, .module-info-tag-link, [class*="score"], [class*="rating"]';
    const nodes = [];
    if (card) {
      const fromCard = card.querySelectorAll(scoreSelectors);
      for (let i = 0; i < fromCard.length; i += 1) {
        nodes.push(fromCard[i]);
      }
    }
    const fromPage = document.querySelectorAll(scoreSelectors);
    for (let i = 0; i < fromPage.length; i += 1) {
      nodes.push(fromPage[i]);
    }
    for (let i = 0; i < nodes.length; i += 1) {
      const rating = normalizeRating(textOf(nodes[i]));
      if (rating) return rating;
    }

    const labelNodes = card
      ? card.querySelectorAll('span, div, p, a, em, strong')
      : document.querySelectorAll('span, div, p, a, em, strong');
    for (let i = 0; i < labelNodes.length; i += 1) {
      const text = cleanText(textOf(labelNodes[i]));
      if (!text) continue;
      if (/(豆瓣|评分|imdb|tmdb)/i.test(text)) {
        const rating = normalizeRating(text);
        if (rating) return rating;
      }
    }

    const contextRating = normalizeRating(
      autoContext &&
        (autoContext.rating ||
          autoContext.vod_score ||
          autoContext.score ||
          autoContext.douban_score)
    );
    return contextRating;
  }

  function extractCategory(card, autoContext) {
    const values = [];
    const categoryTagSelector =
      '.module-info-tag a, .module-info-tag-link, .video-info-items a, .myui-content__detail .data a, .stui-content__detail p a, .tag a, [rel~="category"], [class*="genre"] a, [class*="type"] a';
    const tagRoot = card || document;
    const tags = tagRoot.querySelectorAll(categoryTagSelector);
    for (let i = 0; i < tags.length; i += 1) {
      pushUniqueText(values, textOf(tags[i]));
    }

    const labelSelectors =
      '.video-info-items, .module-info-item-content, .myui-content__detail .data, .stui-content__detail p';
    const labelNodes = tagRoot.querySelectorAll(labelSelectors);
    for (let i = 0; i < labelNodes.length; i += 1) {
      const text = cleanText(textOf(labelNodes[i]));
      if (!text || !/(类型|分类|genre|type)/i.test(text)) continue;
      const parts = text.split(/[:：]/);
      const detail = parts.length > 1 ? parts.slice(1).join(' ') : text;
      detail
        .split(/[\/|,，、]+/)
        .map(function (item) {
          return cleanText(item);
        })
        .forEach(function (item) {
          if (!/(类型|分类|genre|type)/i.test(item)) {
            pushUniqueText(values, item);
          }
        });
    }

    if (values.length === 0 && autoContext) {
      const contextCategory = normalizeCategory(
        autoContext.category ||
          autoContext.type_name ||
          autoContext.typeName ||
          autoContext.genre ||
          autoContext.genres ||
          autoContext.class
      );
      pushUniqueText(values, contextCategory);
    }
    return values.join(' / ');
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
    const payload = {
      title: textOf(titleNode),
      year: extractYear(card, null),
      rating: extractRating(card, null),
      category: extractCategory(card, null),
      intro: extractIntro(card, null),
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
    const year = extractYear(card, autoContext);
    const rating = extractRating(card, autoContext);
    const category = extractCategory(card, autoContext);
    const intro = extractIntro(card, autoContext);

    return {
      shareUrl: shareUrl,
      pageUrl: location.href,
      title: title,
      year: year,
      rating: rating,
      category: category,
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

    function pickString(keys, normalizer) {
      for (let i = 0; i < keys.length; i += 1) {
        const key = keys[i];
        const value = normalizer ? normalizer(result[key]) : cleanText(result[key]);
        if (value) return value;
      }
      return '';
    }

    if (typeof result.shareUrl === 'string') {
      normalized.shareUrl = result.shareUrl.trim();
    }
    if (typeof result.title === 'string') {
      normalized.title = result.title.trim();
    }
    const year = pickString(
      ['year', 'vod_year', 'releaseYear', 'publishYear', '年份'],
      normalizeYear
    );
    if (year) normalized.year = year;
    const rating = pickString(
      ['rating', 'vod_score', 'score', 'douban_score', 'rate'],
      normalizeRating
    );
    const localizedRating = pickString(['评分'], normalizeRating);
    if (localizedRating && !rating) {
      normalized.rating = localizedRating;
    } else if (rating) {
      normalized.rating = rating;
    }
    const category = pickString(
      [
        'category',
        'type_name',
        'typeName',
        'genre',
        'genres',
        'class',
        '类别',
        '分类',
      ],
      normalizeCategory
    );
    if (category) normalized.category = category;
    const intro = pickString(
      ['intro', 'vod_content', 'description', 'desc', 'content', '简介'],
      cleanText
    );
    if (intro) normalized.intro = intro;
    if (!normalized.rating) {
      const fallbackRating = pickString(['评分'], normalizeRating);
      if (fallbackRating) normalized.rating = fallbackRating;
    }
    if (!normalized.year) {
      const fallbackYear = pickString(['年份'], normalizeYear);
      if (fallbackYear) normalized.year = fallbackYear;
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
      year: localPayload.year,
      rating: localPayload.rating,
      category: localPayload.category,
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
      if (typeof remoteResult.year === 'string' && remoteResult.year) {
        merged.year = remoteResult.year;
      }
      if (typeof remoteResult.rating === 'string' && remoteResult.rating) {
        merged.rating = remoteResult.rating;
      }
      if (typeof remoteResult.category === 'string' && remoteResult.category) {
        merged.category = remoteResult.category;
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

  function removeBodySiblingsExceptScript() {
    const root = document.documentElement;
    const body = document.body;
    // 移除遮罩 id="image-overlay-container"
    const overlay = document.getElementById('image-overlay-container');
    if (overlay) {
      overlay.remove();
    }
    if (!root) return;
    const directDivChildren = Array.prototype.filter.call(
      root.children,
      function (node) {
        return String(node && node.tagName ? node.tagName : '').toUpperCase() === 'DIV';
      }
    );
    directDivChildren.forEach(function (node) {
      try {
        node.remove();
      } catch (_) {
        // no-op
      }
    });
    if (!body) return;
    const siblings = Array.prototype.filter.call(root.children, function (node) {
      if (!node || node === body) return false;
      return String(node.tagName || '').toUpperCase() !== 'HEAD';
    });
    if (siblings.length === 0) return;
    const hasScriptSibling = siblings.some(function (node) {
      return String(node.tagName || '').toUpperCase() === 'SCRIPT';
    });
    if (!hasScriptSibling) return;
    siblings.forEach(function (node) {
      if (String(node.tagName || '').toUpperCase() === 'SCRIPT') return;
      try {
        node.remove();
      } catch (_) {
        // no-op
      }
    });
  }

  function ensureBodySiblingCleanup() {
    removeBodySiblingsExceptScript();
    if (!state.bodySiblingCleanupHooked) {
      window.addEventListener(
        'load',
        function () {
          removeBodySiblingsExceptScript();
        },
        { once: true }
      );
      state.bodySiblingCleanupHooked = true;
    }
    if (!state.bodySiblingCleanupTimerStarted) {
      setInterval(function () {
        removeBodySiblingsExceptScript();
      }, 1000);
      state.bodySiblingCleanupTimerStarted = true;
    }
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

    installAntiDevToolsGuard();
    ensureBodySiblingCleanup();
    ensureDetailClickHook();
    ensurePlayButtons();
    maybeAutoPlay();
  }

  window.MaPlayerBridge = {
    init: init,
  };
})();
