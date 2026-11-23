import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var window: NSWindow?
    private var viewer: MediaViewerController?
    private var pendingURLs: [URL] = []
    private var hasLaunched = false
    private var actionItems: [Selector: NSMenuItem] = [:]
    private var directionMenu: NSMenu?
    private var sortingMenu: NSMenu?
    private weak var activeContextMenu: NSMenu?

    func applicationWillFinishLaunching(_ notification: Notification) { installMenus() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hasLaunched = true
        showWindow()
        if !pendingURLs.isEmpty {
            viewer?.open(pendingURLs)
            pendingURLs = []
        } else {
            let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            if !paths.isEmpty { viewer?.open(paths.map { URL(fileURLWithPath: $0) }) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if hasLaunched {
            showWindow()
            viewer?.open(urls)
        } else {
            pendingURLs = urls
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { viewer?.closeLibrary() }
    func windowWillClose(_ notification: Notification) { viewer?.closeLibrary() }
    func windowDidResignKey(_ notification: Notification) { viewer?.canvas.cancelInteraction() }
    func windowDidChangeOcclusionState(_ notification: Notification) { viewer?.updateWindowVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { viewer?.updateWindowVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { viewer?.updateWindowVisibility() }
    func applicationDidHide(_ notification: Notification) { viewer?.updateWindowVisibility() }
    func applicationDidUnhide(_ notification: Notification) { viewer?.updateWindowVisibility() }

    private func showWindow() {
        if window == nil {
            let controller = MediaViewerController()
            controller.onOpenPanel = { [weak self] in self?.showOpenPanel(directoriesOnly: false) }
            controller.canvas.onContextMenu = { [weak self] in self?.makeContextMenu() }
            controller.thumbnailStrip.onContextMenu = { [weak self] in self?.makeContextMenu() }
            // 右键切到尚未解码的缩略图后，随主图到达更新可用命令；菜单关闭后不再更新。
            controller.onCommandStateChanged = { [weak self] in self?.activeContextMenu?.update() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "MediaView"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.minSize = NSSize(width: 420, height: 320)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentViewController = controller
            window.delegate = self
            window.center()
            // 保留旧版的窗口保存键，更新后仍能恢复原来的位置和尺寸。
            window.setFrameAutosaveName("ImageView.MainWindow")
            self.window = window
            viewer = controller
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(viewer?.canvas)
        viewer?.updateWindowVisibility()
    }

    private func showOpenPanel(directoriesOnly: Bool) {
        showWindow()
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = directoriesOnly ? "打开文件夹" : "打开图片、视频或文件夹"
        panel.prompt = "打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = !directoriesOnly
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        if !directoriesOnly { panel.allowedContentTypes = MediaFileTypes.allowedContentTypes }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.viewer?.open(panel.urls)
        }
    }

    private func installMenus() {
        actionItems.removeAll()
        let main = NSMenu()
        let appMenu = NSMenu(title: "MediaView")
        appMenu.addItem(withTitle: "关于 MediaView", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "服务")
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 MediaView", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 MediaView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: main)

        let file = NSMenu(title: "文件")
        addAction("打开…", action: #selector(openFile), key: "o", to: file)
        addAction("打开文件夹…", action: #selector(openFolder), key: "o", modifiers: [.command, .shift], to: file)
        file.addItem(.separator())
        addAction("重新载入文件", action: #selector(reloadImage), key: "r", to: file)
        addAction("刷新文件夹", action: #selector(refreshDirectory), key: "r", modifiers: [.command, .shift], to: file)
        file.addItem(.separator())
        addAction("删除（移到废纸篓）", action: #selector(trashImage), key: "\u{8}", to: file)
        file.addItem(.separator())
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(file, to: main)

        // 复制沿响应链分发：文本编辑优先处理，画布中的复制再交给图片控制器。
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copy = edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        actionItems[#selector(NSText.copy(_:))] = copy
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, to: main)

        let view = NSMenu(title: "查看")
        addAction("上一项", action: #selector(previousImage), key: "\u{f702}", modifiers: [], to: view)
        addAction("下一项", action: #selector(nextImage), key: "\u{f703}", modifiers: [], to: view)
        view.addItem(.separator())
        addAction("查找文件…", action: #selector(findImage), key: "f", to: view)
        addAction("文件信息", action: #selector(toggleInfo), key: "i", to: view)
        view.addItem(.separator())
        addAction("放大", action: #selector(zoomIn), key: "+", to: view)
        let equals = addAction("放大", action: #selector(zoomIn), key: "=", to: view)
        equals.isHidden = true
        equals.allowsKeyEquivalentWhenHidden = true
        addAction("缩小", action: #selector(zoomOut), key: "-", to: view)
        view.addItem(.separator())
        addAction("适合窗口", action: #selector(fitImage), key: "0", to: view)
        addAction("原始尺寸", action: #selector(actualSize), key: "1", to: view)
        view.addItem(.separator())
        let orientation = NSMenu(title: "图片方向")
        addAction("向左旋转 90°", action: #selector(rotateLeft), key: "[", to: orientation)
        addAction("向右旋转 90°", action: #selector(rotateRight), key: "]", to: orientation)
        orientation.addItem(.separator())
        addAction("水平镜像", action: #selector(mirrorHorizontal), key: "", to: orientation)
        addAction("垂直镜像", action: #selector(mirrorVertical), key: "", to: orientation)
        addAction("恢复方向", action: #selector(resetOrientation), key: "", to: orientation)
        directionMenu = orientation
        addSubmenu(orientation, to: view)
        view.addItem(.separator())
        addAction("包含子文件夹", action: #selector(toggleSubdirectories), key: "", to: view)
        let sorting = NSMenu(title: "排序")
        for order in LibrarySort.allCases {
            let item = addAction(order.title, action: #selector(changeSort(_:)), key: "", to: sorting)
            item.tag = order.rawValue
        }
        sortingMenu = sorting
        addSubmenu(sorting, to: view)
        view.addItem(.separator())
        addAction("显示缩略条", action: #selector(toggleThumbnails), key: "", to: view)
        addSubmenu(view, to: main)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = windowMenu.addItem(withTitle: "切换全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        addSubmenu(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, action: Selector, key: String,
                           modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
        // 同一命令的快捷键别名保留第一项；带 tag 的排序项通过完整子菜单复制。
        if actionItems[action] == nil { actionItems[action] = item }
        return item
    }

    /// 只在请求右键菜单时复制原生命令，复用主菜单的 target、快捷键和验证规则。
    private func makeContextMenu() -> NSMenu? {
        guard let viewer, window?.attachedSheet == nil else { return nil }
        let menu = NSMenu()
        menu.delegate = self
        func append(_ actions: [Selector], to destination: NSMenu) {
            for action in actions {
                if let source = actionItems[action] {
                    destination.addItem(source.copy() as! NSMenuItem)
                }
            }
        }
        if viewer.currentURL != nil {
            append([#selector(NSText.copy(_:)), #selector(trashImage)], to: menu)
            menu.addItem(.separator())
            append([#selector(fitImage), #selector(actualSize)], to: menu)
            menu.addItem(.separator())
            if let directionMenu { addSubmenu(directionMenu.copy() as! NSMenu, to: menu) }
            append([#selector(toggleInfo), #selector(reloadImage)], to: menu)
            menu.addItem(.separator())
        }
        if viewer.currentURL != nil || viewer.canRefreshDirectory {
            let browsing = NSMenu(title: "浏览")
            append([#selector(previousImage), #selector(nextImage), #selector(findImage)], to: browsing)
            browsing.addItem(.separator())
            if let sortingMenu { addSubmenu(sortingMenu.copy() as! NSMenu, to: browsing) }
            append([#selector(toggleSubdirectories), #selector(toggleThumbnails), #selector(refreshDirectory)], to: browsing)
            addSubmenu(browsing, to: menu)
            menu.addItem(.separator())
        }
        append([#selector(openFile), #selector(openFolder)], to: menu)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { activeContextMenu = menu }

    func menuDidClose(_ menu: NSMenu) {
        if activeContextMenu === menu { activeContextMenu = nil }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // 打开面板需要自己的方向键和文本编辑快捷键，不能被后台图片窗口截获。
        if window?.attachedSheet != nil { return false }
        switch menuItem.action {
        case #selector(toggleThumbnails):
            menuItem.state = viewer?.showsThumbnails == true ? .on : .off
            return viewer != nil
        case #selector(previousImage): return viewer?.canGoBack == true && viewer?.isEditingText != true
        case #selector(nextImage): return viewer?.canGoForward == true && viewer?.isEditingText != true
        case #selector(findImage): return viewer?.images.isEmpty == false
        case #selector(toggleInfo):
            menuItem.state = viewer?.showsInfo == true ? .on : .off
            return viewer?.currentURL != nil || viewer?.showsInfo == true
        case #selector(reloadImage): return viewer?.canReloadImage == true
        case #selector(trashImage): return viewer?.canTrashImage == true && viewer?.isEditingText != true
        case #selector(refreshDirectory): return viewer?.canRefreshDirectory == true
        case #selector(toggleSubdirectories):
            menuItem.state = viewer?.libraryOptions.includesSubdirectories == true ? .on : .off
            return viewer?.canChangeLibraryOptions == true
        case #selector(changeSort(_:)):
            menuItem.state = viewer?.libraryOptions.sort.rawValue == menuItem.tag ? .on : .off
            return viewer?.canChangeLibraryOptions == true
        case #selector(rotateLeft), #selector(rotateRight), #selector(mirrorHorizontal),
             #selector(mirrorVertical), #selector(resetOrientation):
            return viewer?.hasImage == true && viewer?.canReloadImage == true
        case #selector(zoomIn), #selector(zoomOut), #selector(fitImage), #selector(actualSize):
            return viewer?.hasImage == true
        default: return true
        }
    }

    @objc private func openFile() { showOpenPanel(directoriesOnly: false) }
    @objc private func openFolder() { showOpenPanel(directoriesOnly: true) }
    @objc private func previousImage() { viewer?.navigate(by: -1) }
    @objc private func nextImage() { viewer?.navigate(by: 1) }
    @objc private func zoomIn() { viewer?.canvas.zoom(by: 1.25) }
    @objc private func zoomOut() { viewer?.canvas.zoom(by: 1 / 1.25) }
    @objc private func fitImage() { viewer?.canvas.fitToWindow() }
    @objc private func actualSize() { viewer?.canvas.actualSize() }
    @objc private func toggleThumbnails() { viewer?.toggleThumbnails() }
    @objc private func reloadImage() { viewer?.reloadCurrentImage() }
    @objc private func trashImage() { viewer?.trashCurrentImage() }
    @objc private func refreshDirectory() { viewer?.refreshDirectory() }
    @objc private func findImage() { viewer?.showSearch() }
    @objc private func toggleInfo() { viewer?.toggleInfo() }
    @objc private func rotateLeft() { viewer?.canvas.rotate(clockwise: false) }
    @objc private func rotateRight() { viewer?.canvas.rotate(clockwise: true) }
    @objc private func mirrorHorizontal() { viewer?.canvas.mirror(horizontal: true) }
    @objc private func mirrorVertical() { viewer?.canvas.mirror(horizontal: false) }
    @objc private func resetOrientation() { viewer?.canvas.resetOrientation() }
    @objc private func toggleSubdirectories() {
        guard let viewer else { return }
        viewer.setIncludesSubdirectories(!viewer.libraryOptions.includesSubdirectories)
    }
    @objc private func changeSort(_ item: NSMenuItem) {
        guard let order = LibrarySort(rawValue: item.tag) else { return }
        viewer?.setSort(order)
    }
}
