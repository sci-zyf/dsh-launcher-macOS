// DSH Launcher —— Swift AppKit 版。逻辑全在 launcher.sh,本文件只做窗口与后台调度。
// 非模态扁平单窗口:状态文字 + 操作按钮;spinner 平时隐藏、仅任务时显示;
// 更新用窗口内嵌轨道下拉,不弹 alert。

import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    // 状态文字(可换行)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    // 忙时行:齿轮 + 进行中文字
    private let spinner = NSProgressIndicator()
    private let busyLabel = NSTextField(labelWithString: "")
    // 更新轨道选择行:下拉 + 更新所选 + 取消
    private let trackPop = NSPopUpButton()
    private var trackGoBtn, trackCancelBtn: NSButton!
    // 主按钮
    private var startBtn, stopBtn, restartBtn, updateBtn, quitBtn: NSButton!
    private var busy = false

    // MARK: - launcher.sh 定位

    private func launcherPath() -> String {
        // 1) .app 包内（正式安装）
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("launcher.sh").path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        // 2) 环境变量显式指定（Xcode scheme 或终端可设，指向任意位置，最通用）
        if let env = ProcessInfo.processInfo.environment["DSH_LAUNCHER_SH"],
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        // 3) 源码目录兜底（本地调试默认布局，变更时改这里即可）
        let home = NSHomeDirectory()
        let fallbacks = [
            "Desktop/source/dsh-launcher-macOS/launcher.sh",
            "dsh-launcher-macOS/launcher.sh",
        ]
        for rel in fallbacks {
            let p = (home as NSString).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return (home as NSString).appendingPathComponent(fallbacks[0])
    }

    // MARK: - 调 launcher.sh(同步,须在后台线程调用)

    private func runScript(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launcherPath())
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return "! 无法运行脚本: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseStatus(_ text: String) -> (running: Bool, ver: String, pid: String, url: String) {
        var running = false, ver = "?", pid = "", url = ""
        for ln in text.split(separator: "\n") {
            let s = String(ln)
            if s.hasPrefix("状态:") { running = s.contains("正在运行") }
            else if s.hasPrefix("版本:") { ver = s.replacingOccurrences(of: "版本:", with: "").trimmingCharacters(in: .whitespaces) }
            else if s.hasPrefix("PID:") { pid = s.replacingOccurrences(of: "PID:", with: "").trimmingCharacters(in: .whitespaces) }
            else if s.hasPrefix("网址:") { url = s.replacingOccurrences(of: "网址:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return (running, ver, pid, url)
    }

    // MARK: - UI 刷新(主线程)

    private func renderStatus(_ st: (running: Bool, ver: String, pid: String, url: String)) {
        if st.running {
            statusLabel.stringValue =
                "DSH 正在运行\n" +
                "版本 \(st.ver)  |  PID \(st.pid)\n" +
                "网址 \(st.url)\n\n" +
                "手动终止:kill \(st.pid) 或 pkill -f \"dsh web\""
        } else {
            statusLabel.stringValue =
                "DSH 未运行\n" +
                "已安装版本 \(st.ver)\n\n" +
                "点下方按钮启动、更新或重启 DSH。"
        }
        startBtn.isEnabled = !st.running && !busy
        stopBtn.isEnabled = st.running && !busy
        restartBtn.isEnabled = st.running && !busy
        updateBtn.isEnabled = !busy
    }

    private func refreshStatus() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let out = self.runScript(["status"])
            let st = self.parseStatus(out)
            DispatchQueue.main.async {
                self.renderStatus(st)
            }
        }
    }

    // MARK: - 忙时指示与轨道行互斥共用一行(spinner 平时隐藏)

    private func showBusy(_ text: String) {
        hideTrackRow()
        busyLabel.stringValue = text
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }
    private func hideBusy() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        busyLabel.stringValue = ""
    }
    private func showTrackControl() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        busyLabel.stringValue = ""
        trackPop.isHidden = false
        trackGoBtn.isHidden = false
        trackCancelBtn.isHidden = false
    }
    private func hideTrackRow() {
        trackPop.isHidden = true
        trackGoBtn.isHidden = true
        trackCancelBtn.isHidden = true
    }

    // MARK: - 耗时操作(后台执行,前台进度)

    // 只控制主操作按钮的可用性,不改 busy 标志。
    // busy 仅表示"确有后台任务在跑",选轨/查询态不算 busy。
    private func setMainEnabled(_ on: Bool) {
        startBtn.isEnabled = on
        stopBtn.isEnabled = on
        restartBtn.isEnabled = on
        updateBtn.isEnabled = on
    }

    private func busyTask(_ args: [String], progressText: String, allowDisable: Bool = false) {
        hideTrackRow()
        busy = true
        setMainEnabled(false)
        showBusy(progressText)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let out = self.runScript(args)
            DispatchQueue.main.async {
                self.busy = false
                self.hideBusy()
                // 先放开按钮,status 回来后再按运行态精确设置
                self.enableAllButtons()
                // 命中插件禁用流程时,checkResult 内部已异步完成禁用并刷新状态文字;
                // 此时不再尾随 refreshStatus,以免覆盖禁用结果提示
                if !self.checkResult(out, allowDisable: allowDisable) {
                    self.refreshStatus()
                }
            }
        }
    }

    private func enableAllButtons() {
        startBtn.isEnabled = true
        stopBtn.isEnabled = true
        restartBtn.isEnabled = true
        updateBtn.isEnabled = true
        trackGoBtn.isEnabled = true
        trackCancelBtn.isEnabled = true
    }

    /// 处理 launcher.sh 结果。返回 true 表示命中插件禁用流程(checkResult 已自行接管后续,
    /// 调用方无需再刷新);false 表示按普通结果处理(必要时弹窗)。
    @discardableResult
    private func checkResult(_ out: String, allowDisable: Bool = false) -> Bool {
        // 启动/重启失败且日志给出具体问题插件 → 弹"是否禁用该插件"确认框
        if allowDisable {
            let pkgs = pluginsFromOutcome(out)
            if !pkgs.isEmpty {
                return promptDisable(pkgs, outcome: out)
            }
        }
        if out.contains("启动失败") || out.contains("更新失败") || out.contains("无法获取") {
            alert("操作失败", out)
        }
        return false
    }

    // 从 launcher.sh 失败输出解析全部 "问题插件: <包名>" 行
    private func pluginsFromOutcome(_ out: String) -> [String] {
        var result: [String] = []
        for ln in out.split(separator: "\n") {
            let s = String(ln)
            if s.hasPrefix("问题插件:") {
                let p = s.replacingOccurrences(of: "问题插件:", with: "")
                          .trimmingCharacters(in: .whitespaces)
                if !p.isEmpty && !result.contains(p) { result.append(p) }
            }
        }
        return result
    }

    // 启动失败,定位到问题插件(可多个):给出"禁用这些插件"的选择。返回 true=已进入禁用流程
    private func promptDisable(_ pkgs: [String], outcome: String) -> Bool {
        let names = pkgs.joined(separator: "\n")
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "DSH 启动失败"
        let verb = pkgs.count > 1 ? "这些插件" : "该插件"
        a.informativeText = "以下插件导致启动失败:\n\n\(names)\n\n\(outcome)\n\n是否禁用 \(verb)?\n(禁用后插件保持已装、不再加载;你仍可在 DSH 市场里删除)"
        a.addButton(withTitle: pkgs.count > 1 ? "禁用这些插件" : "禁用该插件")
        a.addButton(withTitle: "取消")
        a.buttons.last?.keyEquivalent = "\u{1b}"  // Esc = 取消
        let resp = a.runModal()
        if resp == .alertFirstButtonReturn {
            disableAndWait(pkgs)
            return true
        }
        return false
    }

    // 禁用指定插件(可多个;不自动重启,回界面由用户点"启动"正常启动)
    private func disableAndWait(_ pkgs: [String]) {
        busy = true
        setMainEnabled(false)
        showBusy("正在禁用插件…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var allOut = ""
            var allOK = true
            for p in pkgs {
                let disableOut = self.runScript(["disable-plugin", p])
                allOut += "\(p):\n\(disableOut)\n\n"
                if !(disableOut.contains("已通过市场禁用") || disableOut.contains("已禁用")) {
                    allOK = false
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.hideBusy()
                if allOK {
                    let list = pkgs.joined(separator: "、")
                    self.statusLabel.stringValue =
                        "已禁用插件 \(list)\n\n" + allOut + "\n请点下方\"启动\"以正常模式启动 DSH。"
                } else {
                    self.alert("禁用未完全成功", allOut)
                }
                self.enableAllButtons()
            }
        }
    }

    private func alert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = msg
        a.addButton(withTitle: "知道了")
        a.runModal()
    }

    // MARK: - 更新:窗口内下拉选轨,不弹 alert

    private func showTrackRow() {
        setMainEnabled(false)
        showBusy("正在查询可更新轨道…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let out = self.runScript(["dist-tags"])
            DispatchQueue.main.async {
                self.hideBusy()
                self.fillTracks(out)
            }
        }
    }

    private func fillTracks(_ out: String) {
        if out.contains("无法获取") {
            alert("无法检查更新", out)
            setMainEnabled(true)
            refreshStatus()
            return
        }
        var cur = "?"
        var items: [(tag: String, ver: String)] = []
        for ln in out.split(separator: "\n") {
            let s = String(ln)
            if s.hasPrefix("当前:") {
                cur = s.replacingOccurrences(of: "当前:", with: "").trimmingCharacters(in: .whitespaces)
            } else if !s.trimmingCharacters(in: .whitespaces).isEmpty {
                let parts = s.split(separator: " ").map(String.init)
                let tag = parts.first ?? ""
                let ver = parts.count > 1 ? parts[1] : ""
                if !tag.isEmpty { items.append((tag, ver)) }
            }
        }
        if items.isEmpty {
            alert("已是最新", "当前版本 \(cur)\n没有可更新的轨道。")
            setMainEnabled(true)
            refreshStatus()
            return
        }
        trackPop.removeAllItems()
        var listText = ""
        for it in items {
            let suffix = (it.ver == cur) ? "   (当前)" : ""
            trackPop.addItem(withTitle: "\(it.tag)  →  \(it.ver)\(suffix)")
            listText += "\(it.tag)  \(it.ver)\(suffix)\n"
        }
        // 默认选到非当前的第一个
        var idx = 0
        for (i, it) in items.enumerated() where it.ver != cur { idx = i; break }
        trackPop.selectItem(at: idx)
        statusLabel.stringValue =
            "当前版本  \(cur)\n\n" +
            listText + "\n" +
            "更新 DSH 到:\n请选择轨道后点\"更新到所选\"。"
        showTrackControl()
        // 选轨态:只放开轨道行按钮,主按钮保持禁用直到取消或更新完成
        trackGoBtn.isEnabled = true
        trackCancelBtn.isEnabled = true
    }

    private func doUpdateSelected() {
        guard let title = trackPop.titleOfSelectedItem else { return }
        // title 形如 "latest  →  0.1.1-rc.2  (当前)"
        let tag = title.split(separator: " ").first.map(String.init) ?? ""
        guard !tag.isEmpty else { return }
        busyTask(["update", tag], progressText: "正在更新到 \(tag)…")
    }

    // MARK: - 按钮动作

    @objc private func onStart() { busyTask(["start"], progressText: "正在启动 DSH…", allowDisable: true) }
    @objc private func onStop() { busyTask(["stop"], progressText: "正在停止 DSH…") }
    @objc private func onRestart() { busyTask(["restart"], progressText: "正在重启 DSH…", allowDisable: true) }
    @objc private func onUpdate() { showTrackRow() }
    @objc private func onTrackGo() { doUpdateSelected() }
    @objc private func onTrackCancel() {
        hideTrackRow()
        setMainEnabled(true)
        refreshStatus()
    }
    @objc private func onQuit() { NSApp.terminate(nil) }

    // MARK: - 窗口搭建

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        refreshStatus()
    }

    // 建主菜单,让 Cmd+W(Close)/Cmd+Q(Quit)等快捷键可用
    private func buildMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 DSH Launcher",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // 窗口菜单:Cmd+W = 关闭窗口(关闭后由 applicationShouldTerminateAfterLastWindowClosed 接管退出)
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu()
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "关闭窗口",
                        action: #selector(NSWindow.performClose(_:)),
                        keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
    }

    // 点窗口左上角关闭 = 彻底退出 Launcher(不是只关窗口)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func makeButton(_ title: String, _ x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.frame = NSRect(x: x, y: y, width: w, height: h)
        b.bezelStyle = .rounded
        return b
    }

    private func buildWindow() {
        let W: CGFloat = 540
        let H: CGFloat = 270

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "DSH Launcher"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // 状态文字(扁平、可换行)
        statusLabel.frame = NSRect(x: 20, y: 88, width: W - 40, height: 158)
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.isEditable = false
        statusLabel.isSelectable = true
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        content.addSubview(statusLabel)

        // 忙时行:齿轮 + 文字(平时隐藏)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 20, y: 62, width: 16, height: 16)
        spinner.isHidden = true
        content.addSubview(spinner)
        busyLabel.font = NSFont.systemFont(ofSize: 12)
        busyLabel.textColor = .secondaryLabelColor
        busyLabel.frame = NSRect(x: 42, y: 62, width: W - 62, height: 20)
        busyLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(busyLabel)

        // 轨道选择行(平时隐藏):下拉 + 更新到所选 + 取消
        trackPop.frame = NSRect(x: 20, y: 56, width: 190, height: 26)
        trackPop.isHidden = true
        content.addSubview(trackPop)
        trackGoBtn = makeButton("更新到所选", 220, y: 54, w: 130, h: 30, action: #selector(onTrackGo))
        trackGoBtn.isHidden = true
        content.addSubview(trackGoBtn)
        trackCancelBtn = makeButton("取消", 360, y: 54, w: 90, h: 30, action: #selector(onTrackCancel))
        trackCancelBtn.isHidden = true
        content.addSubview(trackCancelBtn)

        // 主按钮行:前 4 个窄短名,仅"退出 Launcher"单独加宽
        let y: CGFloat = 14
        let h: CGFloat = 32
        let gap: CGFloat = 8
        let x0: CGFloat = 20
        let shortW: CGFloat = 84
        let quitW: CGFloat = 132
        startBtn = makeButton("启动", x0, y: y, w: shortW, h: h, action: #selector(onStart))
        stopBtn = makeButton("停止", x0 + (shortW + gap) * 1, y: y, w: shortW, h: h, action: #selector(onStop))
        restartBtn = makeButton("重启", x0 + (shortW + gap) * 2, y: y, w: shortW, h: h, action: #selector(onRestart))
        updateBtn = makeButton("更新", x0 + (shortW + gap) * 3, y: y, w: shortW, h: h, action: #selector(onUpdate))
        quitBtn = makeButton("退出 Launcher", x0 + (shortW + gap) * 4, y: y, w: quitW, h: h, action: #selector(onQuit))
        for b in [startBtn!, stopBtn!, restartBtn!, updateBtn!, quitBtn!] { content.addSubview(b) }

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        renderStatus((false, "?", "", ""))
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
