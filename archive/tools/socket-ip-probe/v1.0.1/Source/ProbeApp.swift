import AppKit

private let green = NSColor(calibratedRed:0.12,green:0.39,blue:0.32,alpha:1)
private let muted = NSColor(calibratedRed:0.39,green:0.46,blue:0.41,alpha:1)

final class ProbeView: NSView {
    let title = NSTextField(labelWithString:"插座 IP 读取测试器")
    let subtitle = NSTextField(labelWithString:"独立读取工具 · 不用填写波形参数 · 测试成功后再接入绿电实验室")
    let badge = NSTextField(labelWithString:"独立测试版 1.0.1")
    let banner = NSView()
    let status = NSTextField(wrappingLabelWithString:"准备测试")
    let detail = NSTextField(wrappingLabelWithString:"默认只连接并接收，约 5 秒后自动保存结果。")
    let hostLabel = NSTextField(labelWithString:"设备 IP 地址")
    let host = NSTextField(string:"192.168.1.1")
    let portLabel = NSTextField(labelWithString:"TCP 端口")
    let port = NSTextField(string:"8266")
    let modeLabel = NSTextField(labelWithString:"本次测试内容")
    let mode = NSPopUpButton(frame:.zero,pullsDown:false)
    let ys = NSButton(checkboxWithTitle:"已确认本设备使用 YS8000 手册协议，允许发送查询 / 采集命令",target:nil,action:nil)
    let start = NSButton(title:"开始本次测试",target:nil,action:nil)
    let stop = NSButton(title:"停止并保存",target:nil,action:nil)
    let copy = NSButton(title:"复制诊断摘要",target:nil,action:nil)
    let choose = NSButton(title:"更换保存位置",target:nil,action:nil)
    let metricCards = (0..<3).map { _ in NSView() }
    let metricLabels = ["01  TCP 连接", "02  接收字节", "03  数据来源"].map { NSTextField(labelWithString:$0) }
    let metricValues = ["未测试", "0 字节", "设备 IP 测试"].map { NSTextField(labelWithString:$0) }
    let help = NSTextField(wrappingLabelWithString:"操作顺序：先连插座热点 → 做“只连接”测试 → 核对协议后查询或抓包。\n收到字节仅证明该地址返回了内容，尚未确认电压、电流、采样率或设备身份。")
    let logLabel = NSTextField(labelWithString:"通信日志")
    let hexLabel = NSTextField(labelWithString:"原始接收 · HEX（前 1024 字节）")
    let logScroll = NSScrollView(), hexScroll = NSScrollView()
    let logText = NSTextView(), hexText = NSTextView()
    let saveLabel = NSTextField(wrappingLabelWithString:"")
    let folder = NSButton(title:"打开结果目录",target:nil,action:nil)
    let footer = NSTextField(labelWithString:"无需互联网 · 不切换 Wi-Fi · 不操作继电器 · 测试结果只保存在本机")

    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer = true; layer?.backgroundColor = NSColor(calibratedRed:0.95,green:0.97,blue:0.94,alpha:1).cgColor
        title.font = .systemFont(ofSize:26,weight:.semibold); title.textColor = green
        subtitle.font = .systemFont(ofSize:12); subtitle.textColor = muted
        badge.font = .systemFont(ofSize:12,weight:.medium); badge.textColor = green
        banner.wantsLayer = true; banner.layer?.cornerRadius = 12; banner.layer?.backgroundColor = green.cgColor
        status.font = .systemFont(ofSize:23,weight:.semibold); status.textColor = .white
        detail.font = .systemFont(ofSize:12); detail.textColor = NSColor.white.withAlphaComponent(0.85)
        banner.addSubview(status); banner.addSubview(detail)
        [hostLabel,portLabel,modeLabel,logLabel,hexLabel].forEach { $0.font = .systemFont(ofSize:12,weight:.medium); $0.textColor = muted }
        [host,port].forEach { $0.font = .monospacedSystemFont(ofSize:17,weight:.medium); $0.isEditable = true; $0.isSelectable = true; $0.bezelStyle = .roundedBezel; $0.setContentCompressionResistancePriority(.defaultLow,for:.horizontal) }
        host.placeholderString = "192.168.1.1"; host.setAccessibilityLabel("设备 IP 地址"); port.setAccessibilityLabel("TCP 端口")
        [ProbeMode.passive, .query, .capture].forEach { mode.addItem(withTitle:$0.title) }
        mode.font = .systemFont(ofSize:13); mode.setAccessibilityLabel("本次测试内容")
        ys.font = .systemFont(ofSize:12); ys.contentTintColor = green
        [start,stop,copy,choose,folder].forEach { $0.bezelStyle = .rounded; $0.controlSize = .large; $0.font = .systemFont(ofSize:13,weight:.medium) }
        start.bezelColor = green; start.contentTintColor = .white; start.keyEquivalent = "\r"
        stop.isEnabled = false; folder.isEnabled = false; copy.isEnabled = false
        for j in 0..<3 {
            let box = metricCards[j]; box.wantsLayer = true; box.layer?.backgroundColor = NSColor.white.cgColor; box.layer?.cornerRadius = 10
            box.layer?.borderWidth = 1; box.layer?.borderColor = NSColor(calibratedWhite:0.88,alpha:1).cgColor
            metricLabels[j].font = .systemFont(ofSize:11); metricLabels[j].textColor = muted
            metricValues[j].font = .systemFont(ofSize:20,weight:.semibold); metricValues[j].textColor = green
            box.addSubview(metricLabels[j]); box.addSubview(metricValues[j]); addSubview(box)
        }
        help.font = .systemFont(ofSize:12); help.textColor = muted
        for (scroll,text) in [(logScroll,logText),(hexScroll,hexText)] {
            scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.font = .monospacedSystemFont(ofSize:11.5,weight:.regular)
            text.textColor = NSColor(calibratedRed:0.20,green:0.34,blue:0.27,alpha:1); text.backgroundColor = .white
            text.textContainerInset = NSSize(width:10,height:10); text.autoresizingMask = [.width]
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
        }
        logText.setAccessibilityLabel("通信日志"); hexText.setAccessibilityLabel("原始数据 HEX")
        saveLabel.font = .systemFont(ofSize:11); saveLabel.textColor = muted
        footer.font = .systemFont(ofSize:10); footer.textColor = muted
        [title,subtitle,badge,banner,hostLabel,host,portLabel,port,modeLabel,mode,ys,start,stop,copy,choose,help,logLabel,hexLabel,logScroll,hexScroll,saveLabel,folder,footer].forEach { addSubview($0) }
        logText.string = "尚未开始测试。\n每次测试都会自动保存报告，包括连接失败和零字节结果。"
        hexText.string = hexDump(Data())
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, margin: CGFloat = 26, width = w-52
        func put(_ view:NSView,_ x:CGFloat,_ top:CGFloat,_ width:CGFloat,_ height:CGFloat) { view.frame = NSRect(x:x,y:h-top-height,width:width,height:height) }
        put(title,margin,22,width-180,34); put(subtitle,margin,62,width,20); put(badge,w-190,31,165,20)
        put(banner,margin,98,width,106)
        status.frame = NSRect(x:20,y:53,width:width-40,height:34); detail.frame = NSRect(x:20,y:12,width:width-40,height:37)
        put(hostLabel,margin,221,240,18); put(host,margin,244,248,34)
        put(portLabel,margin+264,221,100,18); put(port,margin+264,244,100,34)
        put(modeLabel,margin+382,221,width-382,18); put(mode,margin+382,244,width-382,34)
        put(ys,margin,290,width,24)
        put(start,margin,327,166,36); put(stop,margin+178,327,140,36); put(copy,margin+330,327,152,36); put(choose,w-190,327,164,36)
        let cardWidth = (width-28)/3
        for j in 0..<3 {
            put(metricCards[j],margin+CGFloat(j)*(cardWidth+14),381,cardWidth,83)
            metricLabels[j].frame = NSRect(x:15,y:53,width:cardWidth-30,height:17)
            metricValues[j].frame = NSRect(x:15,y:16,width:cardWidth-30,height:29)
        }
        put(help,margin,479,width,42)
        let left = floor(width*0.48), gap:CGFloat = 16, logHeight = max(125,h-638)
        put(logLabel,margin,537,left,19); put(hexLabel,margin+left+gap,537,width-left-gap,19)
        put(logScroll,margin,561,left,logHeight); put(hexScroll,margin+left+gap,561,width-left-gap,logHeight)
        logText.frame.size.width = logScroll.contentSize.width; hexText.frame.size.width = hexScroll.contentSize.width
        put(saveLabel,margin,h-64,width-180,37); put(folder,w-190,h-64,164,34)
        put(footer,margin,h-22,width,16)
    }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window:NSWindow!
    var content:ProbeView!
    lazy var runner = ProbeRunner(outputRoot:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("测试结果",isDirectory:true))
    var lastLog = "", lastHex = ""

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle:"关于插座 IP 读取测试器",action:#selector(about),keyEquivalent:"").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"退出测试器",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title:"编辑"); editItem.title = "编辑"
        for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:action,keyEquivalent:key) }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        content = ProbeView(frame:NSRect(x:0,y:0,width:1080,height:860))
        window = NSWindow(contentRect:content.frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "插座 IP 读取测试器 · 独立测试版 1.0.1"; window.minSize = NSSize(width:960,height:820); window.contentView = content; window.delegate = self
        window.appearance = NSAppearance(named:.aqua)
        for (button,action) in [(content.start,#selector(start)),(content.stop,#selector(stop)),(content.copy,#selector(copySummary)),(content.choose,#selector(chooseOutput)),(content.folder,#selector(showFolder)),(content.ys,#selector(modeChanged))] { button.target = self; button.action = action }
        content.mode.target = self; content.mode.action = #selector(modeChanged)
        runner.onUpdate = { [weak self] in self?.update() }
        modeChanged(); update(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    @objc func modeChanged() {
        content.ys.isEnabled = !runner.busy && content.mode.indexOfSelectedItem > 0
        if !runner.busy {
            content.detail.stringValue = content.mode.indexOfSelectedItem == 0 ? "只建立 TCP 并等待 5 秒，不发送任何命令。" : content.mode.indexOfSelectedItem == 1 ? "连接后发送一次 ifconfig，接收 3 秒配置回复。" : "连接后发送 #，接收 3 秒原始数据，结束时发送 $。"
        }
    }
    @objc func start() {
        guard runner.saveError.isEmpty else { alert(runner.saveError); return }
        var cfg = ProbeConfig(); cfg.host = content.host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let port = Int(content.port.stringValue) else { alert("端口需要填写数字"); return }; cfg.port = port
        cfg.mode = ProbeMode(rawValue:content.mode.indexOfSelectedItem) ?? .passive; cfg.ysConfirmed = content.ys.state == .on
        do { try runner.start(cfg) } catch { alert(error.localizedDescription) }
    }
    @objc func stop() { runner.stop() }
    @objc func chooseOutput() {
        let panel = NSOpenPanel(); panel.message = "选择测试结果保存目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runner.outputRoot = url
        if runner.phase == "finished" { runner.persist(to:url) }; update()
    }
    @objc func copySummary() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reportSummary(runner.report),forType:.string)
        content.detail.stringValue = "诊断摘要已复制，不包含原始 BIN 内容。"
    }
    @objc func showFolder() { if let folder = runner.savedFolder { NSWorkspace.shared.open(folder) } }
    @objc func about() { alert("插座 IP 读取测试器 1.0.1\n独立 TCP 原始读取工具。收到字节后仍需核对设备协议和波形。不会同步到绿电实验室。") }
    func alert(_ text:String) { let a = NSAlert(); a.messageText = "插座 IP 读取测试器"; a.informativeText = text; a.runModal() }
    func update() {
        guard content != nil else { return }
        content.status.stringValue = runner.status; content.detail.stringValue = runner.detail
        [content.host,content.port].forEach { $0.isEnabled = !runner.busy }; content.mode.isEnabled = !runner.busy
        content.ys.isEnabled = !runner.busy && content.mode.indexOfSelectedItem > 0
        content.start.isEnabled = !runner.busy; content.stop.isEnabled = runner.busy && runner.phase != "stopping"
        content.choose.isEnabled = !runner.busy; content.copy.isEnabled = runner.phase == "finished"; content.folder.isEnabled = runner.savedFolder != nil
        content.metricValues[0].stringValue = runner.report.tcpConnected ? "已连接过" : runner.phase == "connecting" ? "连接中…" : runner.phase == "finished" ? "未建立" : "未测试"
        content.metricValues[1].stringValue = runner.raw.count.formatted()+" 字节"
        content.metricValues[2].stringValue = runner.phase == "idle" ? "尚未测试" : runner.config.isLoopback ? "本机自测 · 非实物" : "设备 IP · 身份待核对"
        let color = runner.phase == "finished" && runner.raw.isEmpty ? NSColor(calibratedRed:0.60,green:0.35,blue:0.15,alpha:1) : green
        content.banner.layer?.backgroundColor = color.cgColor
        let logs = runner.logs.joined(separator:"\n")
        if logs != lastLog { content.logText.string = logs.isEmpty ? "尚未开始测试。每次测试自动保存结果。" : logs; content.logText.scrollToEndOfDocument(nil); lastLog = logs }
        let hex = hexDump(runner.raw)
        if hex != lastHex { content.hexText.string = hex; lastHex = hex }
        if !runner.saveError.isEmpty { content.saveLabel.stringValue = runner.saveError; content.saveLabel.textColor = .systemRed }
        else { content.saveLabel.textColor = muted; content.saveLabel.stringValue = runner.savedFolder.map { "本次结果已保存：\n"+$0.path } ?? "每次测试自动保存到：\n"+runner.outputRoot.path }
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if runner.busy {
            runner.stop()
            DispatchQueue.main.asyncAfter(deadline:.now()+2.5) { [weak self] in
                guard let self = self else { return }
                if !self.runner.saveError.isEmpty { self.alert(self.runner.saveError); NSApp.reply(toApplicationShouldTerminate:false) }
                else { NSApp.reply(toApplicationShouldTerminate:true) }
            }
            return .terminateLater
        }
        if !runner.saveError.isEmpty {
            alert(runner.saveError); return .terminateCancel
        }
        return .terminateNow
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if runner.busy { runner.stop(); return false }
        if !runner.saveError.isEmpty { alert(runner.saveError); return false }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}
