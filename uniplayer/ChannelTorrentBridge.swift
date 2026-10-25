import AppKit
import WebKit

struct ChannelTorrentCandidate {
  let url: URL; let title: String; let kind: String
  let originURL: URL; let channelID: String?; let documentGeneration: Int
  init?(body: Any, originURL: URL, channelID: String?, generation: Int) {
    guard let value = body as? [String:Any], value["version"] as? Int == 1, value["action"] as? String == "inspect",
          let raw = value["url"] as? String, raw.utf8.count <= 65536, let url = URL(string:raw),
          let title = value["title"] as? String, title.count <= 300, let kind = value["kind"] as? String,
          ["magnet","torrent","resource"].contains(kind) else { return nil }
    if kind == "magnet" { guard url.scheme?.lowercased() == "magnet", (try? TorrentMagnet(raw)) != nil || raw.contains("urn:btmh:") else { return nil } }
    else {
      guard ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil, url.host != nil else { return nil }
      if kind == "torrent" { guard url.pathExtension.lowercased() == "torrent" else { return nil } }
      if kind == "resource" {
        guard Self.isMini4K(originURL), Self.isMini4K(url), url.path.range(of:#"^/torrents/[0-9]+/?$"#,options:.regularExpression) != nil else { return nil }
      }
    }
    self.url = url; self.title = title.isEmpty ? "Torrent source" : title; self.kind = kind
    self.originURL = originURL; self.channelID = channelID; documentGeneration = generation
  }
  static func isMini4K(_ url: URL) -> Bool { let host = url.host?.lowercased() ?? ""; return host == "mini4k.com" || host.hasSuffix(".mini4k.com") }
}

@MainActor
final class ChannelTorrentBridge: NSObject, WKScriptMessageHandlerWithReply {
  static let world = WKContentWorld.world(name:"UniPlayerTorrentActions")
  private weak var webView: WKWebView?
  private var channelID: () -> String? = { nil }
  private var observer: NSObjectProtocol?
  private var navigationObservation: NSKeyValueObservation?
  private final class Popup {
    weak var web: WKWebView?
    var generation = 0
    var observation: NSKeyValueObservation?
    var urlObservation: NSKeyValueObservation?
    var lastURL: URL?
    init(_ web:WKWebView) { self.web = web }
  }
  private var popups: [ObjectIdentifier:Popup] = [:]
  private(set) var generation = 0
  var present: ((ChannelTorrentCandidate, WKWebView, @escaping () -> Bool) -> Void)?
  static var script: String {
    let source = Bundle.main.url(forResource:"ChannelTorrentActions",withExtension:"js").flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? ""
    func json(_ value: String) -> String { String(data:try! JSONEncoder().encode(value),encoding:.utf8)! }
    return "globalThis.uniPlayerTorrentMini4KPosts=\(UserDefaults.standard.bool(forKey:TorrentPreferences.mini4KPosts));globalThis.uniPlayerTorrentEnabled=\(TorrentPreferences.enabled);globalThis.uniPlayerTorrentDisabledHosts=\(String(data:try! JSONEncoder().encode(UserDefaults.standard.stringArray(forKey:"torrent.playback.disabledHosts.v1") ?? []),encoding:.utf8)!);globalThis.uniPlayerTorrentCSS=\(json(Tokens.Torrent.css));globalThis.uniPlayerTorrentIcon=\(json(Tokens.Torrent.icon));\n" + source
  }
  func install(in configuration: WKWebViewConfiguration) {
    configuration.userContentController.addScriptMessageHandler(self,contentWorld:Self.world,name:"torrentActions")
    configuration.userContentController.addUserScript(WKUserScript(source:Self.script,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:Self.world))
  }
  func attach(to web: WKWebView, channelID: @escaping () -> String?) {
    webView = web; self.channelID = channelID
    var previous = web.url
    navigationObservation = web.observe(\.url,options:[.new]) { [weak self] web,_ in
      if previous != web.url { self?.generation += 1; previous = web.url }
    }
    observer = NotificationCenter.default.addObserver(forName:TorrentPreferences.changed,object:nil,queue:.main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  func registerPopup(_ web:WKWebView) {
    let popup = Popup(web); popups[ObjectIdentifier(web)] = popup
    popup.lastURL = web.url
    popup.urlObservation = web.observe(\.url,options:[.new]) { [weak popup] web,_ in
      if popup?.lastURL != web.url { popup?.generation += 1; popup?.lastURL = web.url }
    }
    popup.observation = web.observe(\.isLoading,options:[.new]) { [weak self,weak popup] web,_ in
      if web.isLoading { popup?.generation += 1 } else { self?.refresh() }
    }
  }
  func removePopup(_ web:WKWebView) { popups[ObjectIdentifier(web)] = nil }
  private func owns(_ web:WKWebView) -> Bool {
    if web === webView { return true }
    guard popups[ObjectIdentifier(web)]?.web === web, let source = webView?.url, let popup = web.url else { return false }
    return source.scheme == popup.scheme && source.host == popup.host && source.port == popup.port
  }
  private func epoch(_ web:WKWebView) -> Int { web === webView ? generation : popups[ObjectIdentifier(web)]?.generation ?? -1 }
  func refresh() {
    let views = [webView].compactMap { $0 } + popups.values.compactMap(\.web)
    for web in views {
      let enabled = TorrentPreferences.enabled && owns(web) && TorrentPreferences.allowed(host:web.url?.host ?? "")
      web.evaluateJavaScript("globalThis.uniPlayerTorrentMini4KPosts=\(UserDefaults.standard.bool(forKey:TorrentPreferences.mini4KPosts));globalThis.uniPlayerTorrentActions?.enable(\(enabled))",in:nil,in:Self.world,completionHandler:nil)
    }
  }
  func handleLink(_ url:URL,in web:WKWebView) -> Bool { false }
  private func dispatch(_ candidate:ChannelTorrentCandidate,web:WKWebView) {
    let epoch = epoch(web)
    present?(candidate,web,{ [weak self,weak web] in
      guard let self, let web else { return false }; return self.owns(web) && self.epoch(web) == epoch
    })
  }
  func navigationStarted() { generation += 1 }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?,String?) -> Void) {
    guard TorrentPreferences.enabled, let web = message.webView, owns(web), message.frameInfo.isMainFrame,
          let frameURL = message.frameInfo.request.url, let current = web.url,
          ["https","http"].contains(current.scheme?.lowercased() ?? ""), frameURL.host == current.host, frameURL.scheme == current.scheme, frameURL.port == current.port,
          let body = message.body as? [String:Any], body["version"] as? Int == 1,
          let page = body["page"] as? String, URL(string:page) == current, TorrentPreferences.allowed(host:current.host ?? "") else { replyHandler(nil,"Unavailable on this page"); return }
    if body["action"] as? String == "probe" { replyHandler(["enabled":true],nil); return }
    guard let candidate = ChannelTorrentCandidate(body:body,originURL:current,channelID:channelID(),generation:epoch(web)) else { replyHandler(nil,"Invalid source"); return }
    dispatch(candidate,web:web); replyHandler(["presented":true],nil)
  }

}

@MainActor
final class ChannelTorrentResolver {
  private weak var web: WKWebView?
  private var download: TorrentSourceDownload?
  private var cancelled = false
  init(webView: WKWebView?) { web = webView }
  func cancel() {
    cancelled = true; download?.cancel()
    web?.evaluateJavaScript("globalThis.uniPlayerTorrentFetch?.abort()",in:nil,in:ChannelTorrentBridge.world,completionHandler:nil)
  }
  func resolve(_ candidate: ChannelTorrentCandidate, isCurrent: @escaping () -> Bool) async throws -> TorrentRuntimeSource {
    guard !cancelled, isCurrent() else { throw TorrentFailure.cancelled }
    if candidate.kind == "magnet" { return try TorrentRuntimeSource(magnet:candidate.url.absoluteString) }
    guard let web else { throw TorrentFailure.needsVerification }
    defer { withExtendedLifetime(web) {} }
    var source = candidate.url
    if candidate.kind == "resource" {
      guard UserDefaults.standard.bool(forKey:TorrentPreferences.mini4KPosts) else { throw TorrentFailure.unavailable("Mini4K resource-post resolution is under site validation. Enable its experimental option in Torrent Playback settings, or open the resource page and use its direct magnet link.") }
      let script = """
      const target = new URL(url,location.href);
      if(target.origin!==location.origin) return {error:'origin'};
      const controller=new AbortController();globalThis.uniPlayerTorrentFetch=controller;
      const timeout=setTimeout(()=>controller.abort(),15000);
      try {
        const response=await fetch(target.href,{credentials:'same-origin',signal:controller.signal,cache:'no-store'});
        if(new URL(response.url).origin!==location.origin || !response.ok) return {error:'verification'};
        const reader=response.body.getReader();let chunks=[],length=0;
        while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>2097152){controller.abort();return {error:'large'}};chunks.push(value)}
        const bytes=new Uint8Array(length);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length}
        const html=new TextDecoder().decode(bytes),doc=new DOMParser().parseFromString(html,'text/html');
        const links=[...doc.querySelectorAll('a[href]')].map(a=>{try{return new URL(a.getAttribute('href'),target.href).href}catch{return ''}});
        const magnets=[...new Set(links.filter(u=>u.startsWith('magnet:')))];
        if(magnets.length===1)return {kind:'magnet',url:magnets[0]};
        if(magnets.length>1)return {error:'multiple'};
        const torrents=[...new Set(links.filter(u=>{try{return /\\.torrent$/i.test(new URL(u).pathname)}catch{return false}}))];
        if(torrents.length===1)return {kind:'torrent',url:torrents[0]};
        if(torrents.length>1)return {error:'multiple'};
        if(doc.querySelector('input[type=password],#challenge-form,.cf-turnstile') || /Just a moment|Performing security verification/i.test(doc.title))return {error:'verification'};
        return {error:'unsupported'};
      } finally {clearTimeout(timeout);globalThis.uniPlayerTorrentFetch=null}
      """
      let result = try await web.callAsyncJavaScript(script,arguments:["url":source.absoluteString],in:nil,contentWorld:ChannelTorrentBridge.world)
      guard !cancelled, isCurrent() else { throw TorrentFailure.cancelled }
      guard let value = result as? [String:Any] else { throw TorrentFailure.invalidSource }
      if let error = value["error"] as? String {
        if error == "verification" { throw TorrentFailure.needsVerification }
        if error == "multiple" { throw TorrentFailure.unavailable("This post has multiple sources. Open its page and select the specific magnet or torrent link.") }
        if error == "unsupported" { throw TorrentFailure.unsupportedMedia }; throw TorrentFailure.invalidSource
      }
      guard let raw = value["url"] as? String, raw.utf8.count <= 65536, let resolved = URL(string:raw) else { throw TorrentFailure.invalidSource }
      if value["kind"] as? String == "magnet" { return try TorrentRuntimeSource(magnet:raw) }
      source = resolved
    }
    guard ["https","http"].contains(source.scheme?.lowercased() ?? ""), source.user == nil, source.password == nil else { throw TorrentFailure.invalidSource }
    if let origin = web.url, source.scheme == origin.scheme, source.host == origin.host, source.port == origin.port {
      let data = try await fetchMetainfo(source,in:web)
      guard !cancelled, isCurrent() else { throw TorrentFailure.cancelled }
      return try TorrentRuntimeSource(metainfo:data)
    }
    guard UserDefaults.standard.bool(forKey:TorrentPreferences.crossOriginDownloads) else {
      throw TorrentFailure.unavailable("This torrent download is on another origin. Open the original link and download its .torrent file; cross-origin WebKit downloads have not been qualified on this Mac.")
    }
    // Site cookies stay in WebKit. The daemon receives validated metainfo bytes.
    let transfer = TorrentSourceDownload(webView:web,url:source,origin:candidate.originURL)
    download = transfer
    defer { download = nil }
    let data = try await transfer.run()
    guard !cancelled, isCurrent() else { throw TorrentFailure.cancelled }
    return try TorrentRuntimeSource(metainfo:data)
  }
  private func fetchMetainfo(_ url:URL,in web:WKWebView) async throws -> Data {
    let script = """
    const target=new URL(url,location.href);if(target.origin!==location.origin)return {error:'origin'};
    const controller=new AbortController();globalThis.uniPlayerTorrentFetch=controller;
    const timeout=setTimeout(()=>controller.abort(),20000);
    try {
      const response=await fetch(target.href,{credentials:'same-origin',signal:controller.signal,cache:'no-store'});
      if(!response.ok||new URL(response.url).origin!==location.origin)return {error:'verification'};
      if((response.headers.get('content-type')||'').includes('text/html'))return {error:'verification'};
      if(Number(response.headers.get('content-length')||0)>10485760)return {error:'large'};
      const reader=response.body.getReader(),chunks=[];let length=0;
      while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>10485760){controller.abort();return {error:'large'}}chunks.push(value)}
      if(chunks.length && new TextDecoder().decode(chunks[0].subarray(0,512)).trimStart().startsWith('<'))return {error:'verification'};
      let binary='';for(const chunk of chunks)for(let i=0;i<chunk.length;i+=16384)binary+=String.fromCharCode(...chunk.subarray(i,i+16384));
      return {base64:btoa(binary)};
    } finally {clearTimeout(timeout);globalThis.uniPlayerTorrentFetch=null}
    """
    let raw = try await web.callAsyncJavaScript(script,arguments:["url":url.absoluteString],in:nil,contentWorld:ChannelTorrentBridge.world)
    guard let result = raw as? [String:Any] else { throw TorrentFailure.invalidMetainfo }
    if result["error"] as? String == "verification" { throw TorrentFailure.needsVerification }
    guard let text = result["base64"] as? String, text.utf8.count <= 14*1024*1024, let bytes = Data(base64Encoded:text), !bytes.isEmpty, bytes.count <= 10*1024*1024 else { throw TorrentFailure.invalidMetainfo }
    return bytes
  }

}

@MainActor
final class TorrentSourceDownload: NSObject, WKDownloadDelegate {
  private weak var web: WKWebView?
  private let source: URL; private let origin: URL
  private var continuation: CheckedContinuation<Data,Error>?
  private var transfer: WKDownload?
  private var timer: Task<Void,Never>?
  private var completed = false
  private var redirects = 0
  private var cancelling = false
  private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UniPlayerTorrent-" + UUID().uuidString,isDirectory:true)
  init(webView: WKWebView,url: URL,origin: URL) { web = webView; source = url; self.origin = origin }
  func run() async throws -> Data {
    try Task.checkCancellation()
    guard !completed else { throw TorrentFailure.cancelled }
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Data,Error>) in
        guard !self.completed else { continuation.resume(throwing:TorrentFailure.cancelled); return }
        self.continuation = continuation
        guard let web else { finish(.failure(TorrentFailure.cancelled)); return }
        var request = URLRequest(url:source); request.timeoutInterval = 20
        if source.host == origin.host { request.setValue(origin.absoluteString,forHTTPHeaderField:"Referer") }
        web.startDownload(using:request) { [weak self] transfer in
          guard let self else { transfer.cancel { _ in }; return }
          guard !self.completed else { transfer.cancel { _ in }; return }
          Logger.log("Torrent source download delegate attached")
          self.transfer = transfer; transfer.delegate = self

        }
        timer = Task { [weak self] in
          for _ in 0..<100 {
            do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
            guard let self, !completed else { return }
            let size = (try? folder.appendingPathComponent("source.torrent").resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if size > 10*1024*1024 { abort(.invalidMetainfo); return }
          }
          self?.abort(.timedOut)
        }
      }
    }, onCancel: { Task { @MainActor in self.cancel() } })
  }
  func cancel() { abort(.cancelled) }
  private func abort(_ error: TorrentFailure) {
    guard !completed, !cancelling else { return }; cancelling = true
    if let transfer { transfer.cancel { [weak self] _ in Task { @MainActor in self?.finish(.failure(error)) } } }
    else { finish(.failure(error)) }
  }
  private func finish(_ result: Result<Data,Error>) {
    guard !completed else { return }; completed = true
    timer?.cancel(); transfer = nil
    continuation?.resume(with:result); continuation = nil
    try? FileManager.default.removeItem(at:folder)
  }
  func download(_ download: WKDownload, decidePlaceholderPolicy completionHandler: @escaping (WKDownload.PlaceholderPolicy,URL?) -> Void) {
    completionHandler(.disable,nil)
  }
  func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
    Logger.log("Torrent source response received: \(response.expectedContentLength) bytes")
    guard !completed, response.expectedContentLength >= 0, response.expectedContentLength <= 10 * 1024 * 1024, response.url?.host == source.host,
          let response = response as? HTTPURLResponse, response.statusCode == 200 else { completionHandler(nil); finish(.failure(TorrentFailure.invalidMetainfo)); return }
    if response.mimeType?.lowercased().contains("html") == true { completionHandler(nil); finish(.failure(TorrentFailure.needsVerification)); return }
    completionHandler(folder.appendingPathComponent("source.torrent"))
  }
  func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
    redirects += 1
    guard redirects <= 5, request.url?.host == source.host, request.url?.scheme == source.scheme else { decisionHandler(.cancel); finish(.failure(TorrentFailure.invalidSource)); return }
    decisionHandler(.allow)
  }
  func downloadDidFinish(_ download: WKDownload) {
    Logger.log("Torrent source download finished")
    do {
      let path = folder.appendingPathComponent("source.torrent")
      let size = try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
      guard size > 0, size <= 10 * 1024 * 1024 else { throw TorrentFailure.invalidMetainfo }
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
      let data = try Data(contentsOf:path); _ = try TorrentMetainfo(data)
      finish(.success(data))
    } catch { finish(.failure(error)) }
  }
  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { finish(.failure(TorrentFailure.unavailable("The torrent download failed. Complete any site verification and retry its original link."))) }
}
