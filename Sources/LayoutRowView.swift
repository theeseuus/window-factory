import AppKit

struct LayoutRowApp: Equatable {
    let bundleID: String, name: String, count: Int
    static func apps(in recipe: Recipe) -> [LayoutRowApp] {
        Dictionary(grouping:recipe.windows,by:\.bundleID).map { id,slots in
            LayoutRowApp(bundleID:id,name:slots[0].appName,count:slots.count)
        }.sorted { a,b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.bundleID < b.bundleID : order == .orderedAscending
        }
    }
}

@MainActor
final class LayoutThumbnailView: NSView {
    let recipe: Recipe
    var aspectRatio: Double = 1.6
    init(recipe: Recipe) { self.recipe = recipe; super.init(frame:.zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    func rectangles(in bounds: NSRect) -> [NSRect] {
        let canvas = LibraryPresentation.canvas(in:bounds,inset:4,aspect:aspectRatio)
        guard canvas.width>0,canvas.height>0 else { return [] }
        return recipe.windows.compactMap { slot in
            guard slot.frame.valid else { return nil }
            let f = slot.frame
            let rect = NSRect(x:canvas.minX+f.x*canvas.width,y:canvas.minY+f.y*canvas.height,width:f.w*canvas.width,height:f.h*canvas.height).intersection(canvas)
            return rect.isNull || rect.isEmpty ? nil : rect
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(roundedRect:LibraryPresentation.canvas(in:bounds,inset:0.5,aspect:aspectRatio),xRadius:5,yRadius:5)
        NSColor.controlBackgroundColor.setFill(); border.fill()
        NSColor.separatorColor.setStroke(); border.stroke()
        for rect in rectangles(in:bounds) {
            let shape = NSBezierPath(roundedRect:rect.insetBy(dx:0.7,dy:0.7),xRadius:1.5,yRadius:1.5)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill(); shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke(); shape.lineWidth = 0.8; shape.stroke()
        }
    }
}

@MainActor
final class LayoutRowView: NSTableCellView {
    let thumbnail: LayoutThumbnailView
    let apps: [LayoutRowApp]
    let icons = NSStackView()
    let dragGrip = NSImageView()
    let nameLabel: NSTextField
    static let visibleAppLimit = 4
    init(recipe: Recipe,aspectRatio: Double = 1.6,canReorder: Bool = true,iconForBundle: (String)->NSImage?) {
        apps = LayoutRowApp.apps(in:recipe); thumbnail = LayoutThumbnailView(recipe:recipe)
        thumbnail.aspectRatio = aspectRatio
        nameLabel = NSTextField(labelWithString:recipe.name)
        super.init(frame:.zero)
        dragGrip.image = Self.gripImage()
        dragGrip.contentTintColor = .tertiaryLabelColor; dragGrip.imageScaling = .scaleProportionallyDown
        dragGrip.toolTip = "Drag to reorder"; dragGrip.isHidden = !canReorder; dragGrip.setAccessibilityElement(false)
        nameLabel.font = .systemFont(ofSize:13,weight:.semibold)
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        nameLabel.toolTip = recipe.name; textField = nameLabel
        icons.orientation = .horizontal; icons.alignment = .centerY; icons.spacing = 7
        for app in apps.prefix(Self.visibleAppLimit) {
            let image = NSImageView()
            image.image = iconForBundle(app.bundleID) ?? NSImage(systemSymbolName:"app",accessibilityDescription:"Application")
            image.imageScaling = .scaleProportionallyUpOrDown
            let label = app.name + (app.count>1 ? ", \(app.count) windows" : ", 1 window")
            image.toolTip = label; image.setAccessibilityLabel(label)
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant:20),image.heightAnchor.constraint(equalToConstant:20)])
            let group = NSStackView(views:[image]); group.orientation = .horizontal; group.spacing = 2
            if app.count>1 {
                let count = NSTextField(labelWithString:"×\(app.count)"); count.font = .systemFont(ofSize:10); count.textColor = .secondaryLabelColor
                group.addArrangedSubview(count)
            }
            icons.addArrangedSubview(group)
        }
        if apps.count>Self.visibleAppLimit {
            let overflow = NSTextField(labelWithString:"+\(apps.count-Self.visibleAppLimit)")
            overflow.font = .systemFont(ofSize:11); overflow.textColor = .secondaryLabelColor
            overflow.toolTip = apps.dropFirst(Self.visibleAppLimit).map(\.name).joined(separator:", ")
            overflow.setAccessibilityLabel("Additional apps: " + overflow.toolTip!)
            icons.addArrangedSubview(overflow)
        }
        for view in [thumbnail,nameLabel,icons,dragGrip] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo:leadingAnchor,constant:6),thumbnail.centerYAnchor.constraint(equalTo:centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant:84),thumbnail.heightAnchor.constraint(equalToConstant:52),
            nameLabel.leadingAnchor.constraint(equalTo:thumbnail.trailingAnchor,constant:10),nameLabel.trailingAnchor.constraint(equalTo:dragGrip.leadingAnchor,constant:-8),
            nameLabel.topAnchor.constraint(equalTo:topAnchor,constant:10),
            icons.leadingAnchor.constraint(equalTo:nameLabel.leadingAnchor),icons.topAnchor.constraint(equalTo:nameLabel.bottomAnchor,constant:6),
            icons.trailingAnchor.constraint(lessThanOrEqualTo:dragGrip.leadingAnchor,constant:-8),
            dragGrip.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),dragGrip.centerYAnchor.constraint(equalTo:centerYAnchor),
            dragGrip.widthAnchor.constraint(equalToConstant:10),dragGrip.heightAnchor.constraint(equalToConstant:18)
        ])
        toolTip = recipe.name + "\n" + recipe.summary
    }
    private static func gripImage() -> NSImage {
        let image = NSImage(size:NSSize(width:10,height:18),flipped:false) { _ in
            NSColor.labelColor.setFill()
            for x: CGFloat in [2.5,7.5] { for y: CGFloat in [4,9,14] {
                NSBezierPath(ovalIn:NSRect(x:x-1,y:y-1,width:2,height:2)).fill()
            } }
            return true
        }
        image.isTemplate = true; return image
    }
    func setReorderingAvailable(_ available: Bool) {
        dragGrip.isHidden = !available; window?.invalidateCursorRects(for:self)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !dragGrip.isHidden { addCursorRect(dragGrip.frame,cursor:.openHand) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}
