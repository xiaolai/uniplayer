// Native parent-death watchdog. No networking, credentials, or personal profiles.
import Foundation
import Darwin
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3, let parent = Int32(args[0]), parent == getppid() else { exit(64) }
guard flock(STDIN_FILENO, LOCK_EX | LOCK_NB) == 0 else { exit(73) }
umask(0o077)
let process = Process()
process.executableURL = URL(fileURLWithPath: args[1])
process.arguments = ["--foreground", "--paused", "--config-dir", args[2], "--pid-file", URL(fileURLWithPath:args[2]).appendingPathComponent("daemon.pid").path, "--log-level", "critical"]
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
process.environment = ["PATH": "/usr/bin:/bin", "HOME": args[2]]
let lock = NSLock()
var stopping = false
func stop() {
  lock.lock(); guard !stopping else { lock.unlock(); return }; stopping = true; lock.unlock()
  if process.isRunning { process.terminate() }
  DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
}
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
term.setEventHandler { stop() }; term.resume()
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler { stop() }; interrupt.resume()
lock.lock()
guard !stopping else { lock.unlock(); exit(0) }
do { try process.run() } catch { lock.unlock(); exit(70) }
lock.unlock()
let timer = DispatchSource.makeTimerSource(queue: .global())
timer.schedule(deadline: .now(), repeating: 1)
timer.setEventHandler { if getppid() != parent || kill(parent, 0) != 0 { stop() } }; timer.resume()
process.waitUntilExit()
timer.cancel(); term.cancel(); interrupt.cancel()
exit(process.terminationStatus)
