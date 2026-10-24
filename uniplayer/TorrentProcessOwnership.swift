import Foundation
import Darwin

/// PID plus kernel start time prevents signaling a recycled process identifier.
struct TorrentProcessIdentity: Codable, Equatable {
  let pid:Int32; let seconds:UInt64; let microseconds:UInt64
  static func capture(_ pid:Int32) -> Self? {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size, info.pbi_status != SZOMB else { return nil }
    return Self(pid:pid,seconds:info.pbi_start_tvsec,microseconds:info.pbi_start_tvusec)
  }
  var isRunning:Bool { Self.capture(pid) == self }
  func holdsLock(_ path:URL) -> Bool {
    guard isRunning else { return false }
    var info = vnode_fdinfowithpath()
    guard proc_pidfdinfo(pid,0,PROC_PIDFDVNODEPATHINFO,&info,Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { return false }
    let actual = withUnsafePointer(to:&info.pvip.vip_path) { $0.withMemoryRebound(to:CChar.self,capacity:Int(MAXPATHLEN)) { String(cString:$0) } }
    return URL(fileURLWithPath:actual).resolvingSymlinksInPath() == path.resolvingSymlinksInPath()
  }
  func signal(_ number:Int32) { if isRunning { Darwin.kill(pid,number) } }
  func stop() async { await Task { await self.stopUncancelled() }.value }
  private func stopUncancelled() async {
    signal(SIGTERM)
    for _ in 0..<30 { if !isRunning { return }; try? await Task.sleep(for:.milliseconds(100)) }
    signal(SIGKILL)
    for _ in 0..<10 { if !isRunning { return }; try? await Task.sleep(for:.milliseconds(50)) }
  }
}
struct TorrentProcessOwner: Codable {
  let app:TorrentProcessIdentity; let token:String
  static func daemon(profile:URL,token:String) -> TorrentProcessIdentity? {
    guard let data = try? Data(contentsOf:profile.appendingPathComponent("owner.json")), let owner = try? JSONDecoder().decode(Self.self,from:data),
          !owner.app.isRunning || owner.token == token,
          let text = try? String(contentsOf:profile.appendingPathComponent("daemon.pid"),encoding:.utf8), let pid = Int32(text.trimmingCharacters(in:.whitespacesAndNewlines)),
          let process = TorrentProcessIdentity.capture(pid), process.holdsLock(profile.appendingPathComponent("owner.lock")),
          let latest = try? Data(contentsOf:profile.appendingPathComponent("owner.json")), latest == data else { return nil }
    return process
  }
}
