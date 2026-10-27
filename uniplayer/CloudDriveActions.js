/*
 * Cloud-drive adapters for UniPlayer.
 *
 * Derived from LinkSwift (https://github.com/hmjz100/LinkSwift) at commit
 * 8283da03e6c78576ebca8b1604161bcd54ade82e, copyright hmjz100 and 油小猴,
 * licensed AGPL-3.0-or-later. Only the per-drive resolution logic is used:
 * no LinkSwift UI, no jQuery, no SweetAlert2, no userscript storage.
 *
 * Runs in the page content world because it reads page globals. The native
 * side treats every message here as untrusted input.
 */
(function () {
  "use strict";

  if (globalThis.uniPlayerCloudDrive) return;

  const state = { adapter: "", enabled: false, userAgent: "" };
  const MAX_ERROR = 300;

  function handler() {
    return globalThis.webkit && globalThis.webkit.messageHandlers
      ? globalThis.webkit.messageHandlers.cloudDrive
      : null;
  }

  function post(message) {
    const bridge = handler();
    if (!bridge) return Promise.reject(new Error("The UniPlayer bridge is unavailable."));
    return bridge.postMessage(message);
  }

  function fail(message) {
    post({
      version: 1,
      action: "failure",
      message: String(message || "").slice(0, MAX_ERROR),
    }).catch(function () {});
    return false;
  }

  async function request(method, url, headers, body) {
    const reply = await post({
      version: 1,
      action: "request",
      request: {
        method: method,
        url: url,
        headers: headers || {},
        body: body == null ? null : body,
      },
    });
    if (!reply || typeof reply.status !== "number") {
      throw new Error("The drive request was refused.");
    }
    if (reply.status < 200 || reply.status >= 300) {
      throw new Error("The drive answered with HTTP " + reply.status + ".");
    }
    return reply;
  }

  async function json(method, url, headers, value) {
    const reply = await request(
      method, url, headers, value == null ? null : JSON.stringify(value));
    try {
      return JSON.parse(reply.body || "{}");
    } catch (_) {
      throw new Error("The drive returned an unreadable answer.");
    }
  }

  function codeError(payload) {
    if (!payload) return "The drive returned no answer.";
    if (payload.code === 31001) return "Sign in to the drive first.";
    if (payload.code === 23018) {
      return "The drive limits this file for guests. Sign in and try again.";
    }
    if (payload.message) return String(payload.message).slice(0, MAX_ERROR);
    if (payload.code != null) {
      return "The drive refused the request (code " + payload.code + ").";
    }
    return "The drive did not return a download address.";
  }

  // React stores its fiber on a DOM node under a versioned property name.
  function findFiberMatching(element, predicate) {
    if (!element) return null;
    const key = Object.keys(element).find(function (name) {
      return name.indexOf("__reactFiber$") === 0 ||
        name.indexOf("__reactInternalInstance$") === 0;
    });
    let fiber = key ? element[key] : null;
    while (fiber) {
      if (predicate(fiber.pendingProps || fiber.memoizedProps || {})) return fiber;
      fiber = fiber.return;
    }
    return null;
  }

  function findFiber(element) {
    return findFiberMatching(element, function (props) {
      return Array.isArray(props.list) || Array.isArray(props.selectedRowKeys);
    });
  }

  const quark = {
    downloadURL:
      "https://drive-pc.quark.cn/1/clouddrive/file/download" +
      "?pr=ucpro&fr=pc&sys=win32&ve=6.9.7.761",
    socialURL:
      "https://drive-social-api.quark.cn/1/clouddrive/chat/conv/file/acquire_dl_token" +
      "?pr=ucpro&fr=pc&sys=win32&ve=6.9.7.761&fr=win&la=zh-CN&ch=pckk%40product_guanwan",

    selection: function () {
      const element = document.getElementsByClassName("file-list")[0];
      const fiber = findFiber(element);
      if (!fiber) return [];
      const props = fiber.memoizedProps || {};
      const files = Array.isArray(props.list) ? props.list : [];
      const selected = Array.isArray(props.selectedRowKeys) ? props.selectedRowKeys : [];
      return files
        .filter(function (item) {
          return item && selected.indexOf(item.fid) >= 0 && item.file !== false;
        })
        .map(function (item) {
          return { fid: item.fid, name: item.file_name || item.name || "Video" };
        });
    },

    resolve: async function (item) {
      const userAgent = state.userAgent;
      if (!userAgent) {
        throw new Error("The drive client identity is unavailable.");
      }
      const now = Math.floor(Date.now() / 1000);
      const tokenReply = await json(
        "POST", quark.socialURL,
        {
          "Content-Type": "application/json",
          "User-Agent": userAgent,
          "Origin": location.origin,
          "Referer": location.origin + "/",
        },
        {
          conversation_id: "300000" + now,
          conversation_type: 3,
          msg_id: now + "000",
        });
      if (tokenReply.code !== 0 || !tokenReply.data || !tokenReply.data.token) {
        throw new Error(codeError(tokenReply));
      }

      const reply = await json(
        "POST", quark.downloadURL,
        {
          "Content-Type": "application/json",
          "User-Agent": userAgent,
          "Origin": location.origin,
          "Referer": location.origin + "/",
        },
        { fids: [item.fid], speedup_session: "", token: tokenReply.data.token });
      if (reply.code !== 0 || !Array.isArray(reply.data) || !reply.data.length) {
        throw new Error(codeError(reply));
      }
      const file = reply.data[0];
      if (!file || !file.download_url) {
        throw new Error("The drive returned an empty download address.");
      }
      return {
        url: file.download_url,
        title: file.file_name || item.name,
        userAgent: userAgent,
        headers: [],
      };
    },
  };

  // Aliyun Drive. The API contract follows the documented
  // POST /v2/file/get_download_url (drive_id, file_id, expire_sec) with the
  // page's own access token; the direct link needs the page origin as Referer.
  const aliyun = {
    listSelector: '[class^="node-list-table-view--"]',

    selection: function () {
      const element = document.querySelector(aliyun.listSelector);
      if (!element) {
        throw new Error("Switch the drive to list view, then select a video.");
      }
      const fiber = findFiberMatching(element, function (props) {
        return Array.isArray(props.dataSource) && props.selectedKeys != null;
      });
      if (!fiber) return [];
      const props = fiber.pendingProps || fiber.memoizedProps || {};
      const files = props.dataSource || [];
      const raw = props.selectedKeys;
      const keys = Array.isArray(raw) ? raw : String(raw || "").split(",");
      return files
        .filter(function (item) {
          return item && keys.indexOf(item.fileId) >= 0 && item.type === "file";
        })
        .map(function (item) {
          return {
            fileId: item.fileId,
            driveId: item.driveId,
            name: item.name || "Video",
          };
        });
    },

    resolve: async function (item) {
      let token = null;
      try {
        token = JSON.parse(localStorage.getItem("token") || "null");
      } catch (_) {
        token = null;
      }
      if (!token || !token.access_token) {
        throw new Error("Sign in to the drive first.");
      }
      if (!item.driveId) {
        throw new Error("The drive did not expose this file's space.");
      }
      const host = location.host.indexOf("www.") === 0
        ? location.host.replace("www.", "api.")
        : "api." + location.host;
      const authorization = (token.token_type || "Bearer") + " " + token.access_token;
      const reply = await json(
        "POST", "https://" + host + "/v2/file/get_download_url",
        {
          "Authorization": authorization,
          "Content-Type": "application/json",
          "Origin": location.origin,
          "Referer": location.origin + "/",
          "X-Canary": "client=windows,app=adrive,version=v6.0.0",
        },
        {
          drive_id: item.driveId,
          file_id: item.fileId,
          // Documented maximum is 115200 s; four hours is enough for a film
          // and keeps a stolen URL's useful life short.
          expire_sec: 14400,
        });
      if (!reply || reply.code || !reply.url) {
        throw new Error(codeError(reply));
      }
      const source = {
        url: reply.url,
        title: item.name,
        referrer: location.origin + "/",
        headers: [],
      };
      // The documented response carries `expiration`; forward it so the
      // player can warn before a long pause or a queued file outlives the URL.
      const rawExpiration = reply.expiration;
      let expiresAt = NaN;
      if (typeof rawExpiration === "number") {
        expiresAt = rawExpiration > 0 && rawExpiration < 1e12
          ? rawExpiration * 1000
          : rawExpiration;
      } else if (typeof rawExpiration === "string") {
        expiresAt = Date.parse(rawExpiration);
      }
      if (Number.isFinite(expiresAt) && expiresAt > 0) {
        source.expiresAt = expiresAt;
      }
      return source;
    },
  };

  // Every entry point throws for a programming error and returns false for a
  // condition the person can act on, so the native panel can name the cause.
  const adapters = { quark: quark, aliyun: aliyun };

  async function play() {
    if (!state.enabled) {
      return fail("Cloud-drive playback is turned off in Settings.");
    }
    const adapter = adapters[state.adapter];
    if (!adapter) {
      return fail("This drive has no adapter yet.");
    }

    let items = [];
    try {
      items = adapter.selection();
    } catch (error) {
      return fail(error && error.message
        ? error.message
        : "The drive page could not be read.");
    }
    if (!items.length) {
      return fail("Select a file in the drive page first.");
    }

    let presented = 0;
    let lastError = null;
    for (const item of items) {
      try {
        const source = await adapter.resolve(item);
        if (source && source.url) {
          await post({ version: 1, action: "present", source: source });
          presented += 1;
        }
      } catch (error) {
        lastError = error;
      }
      await new Promise(function (resolve) { setTimeout(resolve, 1000); });
    }

    if (!presented) {
      return fail(lastError && lastError.message
        ? lastError.message
        : "No download address was returned.");
    }
    return true;
  }

  globalThis.uniPlayerCloudDrive = {
    configure: function (adapter, enabled, userAgent) {
      state.adapter = typeof adapter === "string" ? adapter : "";
      state.enabled = !!enabled;
      state.userAgent = typeof userAgent === "string" ? userAgent : "";
    },
    play: play,
    count: function () {
      const adapter = adapters[state.adapter];
      try {
        return adapter ? adapter.selection().length : 0;
      } catch (_) {
        return 0;
      }
    },
  };
})();
