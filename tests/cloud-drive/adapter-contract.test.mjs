// Contract test for UniPlayer's cloud-drive adapters.
//
// Loads the real CloudDriveActions.js in Node with a fake bridge, page state
// and DOM, then asserts the request shape each adapter sends and the source it
// presents. It never contacts a drive. The fixtures encode the documented
// contracts: Baidu/Quark from the page-session API and Aliyun from the
// documented POST /v2/file/get_download_url.
//
//   node tests/cloud-drive/adapter-contract.test.mjs

import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const requests = [];
const sources = [];
const failures = [];

globalThis.webkit = {
  messageHandlers: {
    cloudDrive: {
      postMessage(body) {
        if (body.action === "request") {
          requests.push(body.request);
          if (body.request.url.includes("acquire_dl_token")) {
            return Promise.resolve({
              status: 200,
              body: JSON.stringify({ code: 0, data: { token: "quark-token" } }),
            });
          }
          if (body.request.url.includes("clouddrive/file/download")) {
            return Promise.resolve({
              status: 200,
              body: JSON.stringify({
                code: 0,
                data: [{
                  download_url: "https://cdn.quark.cn/video.mp4",
                  file_name: "Quark.mp4",
                }],
              }),
            });
          }
          if (body.request.url.includes("get_download_url")) {
            // The documented PDS example returns a data.aliyunpds.com URL.
            return Promise.resolve({
              status: 200,
              body: JSON.stringify({
                url: "https://data.aliyunpds.com/video.mp4",
                expiration: "2026-10-28T00:00:00Z",
                size: 1024,
              }),
            });
          }
          return Promise.resolve({ status: 500, body: "{}" });
        }
        if (body.action === "present") {
          sources.push(body.source);
          return Promise.resolve({ presented: true });
        }
        if (body.action === "failure") {
          failures.push(body.message);
          return Promise.resolve(null);
        }
        return Promise.resolve(null);
      },
    },
  },
};

const quarkElement = {
  __reactFiber$test: {
    memoizedProps: {
      list: [{ fid: "f1", file_name: "Quark.mp4", file: true }],
      selectedRowKeys: ["f1"],
    },
    return: null,
  },
};
const aliyunElement = {
  __reactFiber$test: {
    pendingProps: {
      dataSource: [{ fileId: "a1", driveId: "d1", name: "Ali.mp4", type: "file" }],
      selectedKeys: "a1",
    },
    return: null,
  },
};

let listViewPresent = true;
globalThis.document = {
  getElementsByClassName(name) {
    return name === "file-list" ? [quarkElement] : [];
  },
  querySelector(selector) {
    if (selector.includes("node-list-table-view") && listViewPresent) return aliyunElement;
    return null;
  },
};

globalThis.location = {
  host: "pan.quark.cn",
  origin: "https://pan.quark.cn",
  href: "https://pan.quark.cn/list",
  pathname: "/list",
};

const storage = new Map([
  ["token", JSON.stringify({ token_type: "Bearer", access_token: "aliyun-token" })],
]);
globalThis.localStorage = {
  getItem(key) { return storage.has(key) ? storage.get(key) : null; },
};

const script = fs.readFileSync(
  new URL("../../uniplayer/CloudDriveActions.js", import.meta.url), "utf8");
vm.runInThisContext(script, { filename: "CloudDriveActions.js" });

const drive = globalThis.uniPlayerCloudDrive;
assert.ok(drive, "the adapter must install its global");

// Quark: social token, then the download address.
drive.configure("quark", true, "QuarkAgent/1");
assert.equal(await drive.play(), true);
assert.equal(requests.length, 2);
assert.ok(requests[0].url.includes("acquire_dl_token"));
assert.equal(requests[0].headers["User-Agent"], "QuarkAgent/1");
assert.equal(requests[0].headers.Origin, "https://pan.quark.cn");
assert.equal(requests[0].headers.Referer, "https://pan.quark.cn/");
const socialBody = JSON.parse(requests[0].body);
assert.equal(socialBody.conversation_type, 3);
assert.ok(String(socialBody.conversation_id).startsWith("300000"));
assert.ok(requests[1].url.includes("clouddrive/file/download"));
const downloadBody = JSON.parse(requests[1].body);
assert.deepEqual(downloadBody.fids, ["f1"]);
assert.equal(downloadBody.token, "quark-token");
assert.equal(sources[0].url, "https://cdn.quark.cn/video.mp4");
assert.equal(sources[0].title, "Quark.mp4");
assert.equal(sources[0].userAgent, "QuarkAgent/1");

// Aliyun: the documented get_download_url body, with a long expiry.
requests.length = 0;
sources.length = 0;
Object.assign(globalThis.location, {
  host: "www.alipan.com",
  origin: "https://www.alipan.com",
  href: "https://www.alipan.com/drive",
  pathname: "/drive",
});
drive.configure("aliyun", true, "");
assert.equal(await drive.play(), true);
assert.equal(requests.length, 1);
assert.equal(requests[0].method, "POST");
assert.equal(requests[0].url, "https://api.alipan.com/v2/file/get_download_url");
assert.equal(requests[0].headers.Authorization, "Bearer aliyun-token");
assert.equal(requests[0].headers["Content-Type"], "application/json");
assert.equal(requests[0].headers.Origin, "https://www.alipan.com");
assert.equal(requests[0].headers.Referer, "https://www.alipan.com/");
assert.equal(requests[0].headers["X-Canary"], "client=windows,app=adrive,version=v6.0.0");
const aliyunBody = JSON.parse(requests[0].body);
assert.equal(aliyunBody.drive_id, "d1");
assert.equal(aliyunBody.file_id, "a1");
assert.equal(aliyunBody.expire_sec, 14400);
assert.equal(sources[0].url, "https://data.aliyunpds.com/video.mp4");
assert.equal(sources[0].title, "Ali.mp4");
assert.equal(sources[0].referrer, "https://www.alipan.com/");
assert.equal(sources[0].expiresAt, Date.parse("2026-10-28T00:00:00Z"));

// Aliyun list view is required.
listViewPresent = false;
failures.length = 0;
assert.equal(await drive.play(), false);
assert.equal(failures.length, 1);
assert.match(failures[0], /Switch the drive to list view/);
listViewPresent = true;

// An empty selection names the cause instead of presenting nothing.
aliyunElement.__reactFiber$test.pendingProps.selectedKeys = "";
failures.length = 0;
assert.equal(await drive.play(), false);
assert.equal(failures.length, 1);
assert.match(failures[0], /Select a file/);

console.log("cloud-drive adapter contract test: passed");
