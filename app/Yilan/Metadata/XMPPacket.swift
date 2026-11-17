import Foundation

/// 一份 XMP（文件内嵌的 XMP 包或 .xmp 小文件）。
/// 用 XMLDocument 定点修改 xmp:Rating，其他节点原样保留（技术方案 3.1：ImageIO 重新序列化会改写语义，不用）
final class XMPPacket {
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let metaNS = "adobe:ns:meta/"
    /// 一览新建时写在 x:xmptk 里的标记（spec S-11）
    static let toolkitPrefix = "Yilan"

    let document: XMLDocument
    /// 原数据外面有没有 <?xpacket?> 包裹（小文件改写时保持原样）
    let hadPacketWrapper: Bool

    enum ParseError: Error { case invalid }

    init(data: Data) throws {
        guard let doc = try? XMLDocument(data: data, options: [.nodePreserveAll]), doc.rootElement() != nil else {
            throw ParseError.invalid
        }
        document = doc
        hadPacketWrapper = data.range(of: Data("<?xpacket begin".utf8)) != nil
    }

    private init(document: XMLDocument) {
        self.document = document
        hadPacketWrapper = false
    }

    /// 新建一份只有空 Description 的 XMP，带“由一览创建”的标记
    static func makeNew(version: String = AppInfo.version) -> XMPPacket {
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="\(toolkitPrefix) \(version)"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>
        """
        // 固定文本，一定能解析
        return XMPPacket(document: try! XMLDocument(xmlString: text, options: [.nodePreserveAll]))
    }

    private var root: XMLElement { document.rootElement()! }

    /// 所有 rdf:Description（多段的 XMP 也算）
    private var descriptions: [XMLElement] {
        var result: [XMLElement] = []
        func walk(_ e: XMLElement) {
            if e.localName == "Description", e.uri == Self.rdfNS { result.append(e) }
            for child in e.children ?? [] { if let c = child as? XMLElement { walk(c) } }
        }
        walk(root)
        return result
    }

    // MARK: 星级

    /// xmp:Rating 的原始文字（属性或元素写法，兼容旧前缀 xap:，按命名空间找）
    var ratingText: String? {
        for d in descriptions {
            if let a = d.attribute(forLocalName: "Rating", uri: Self.xmpNS) { return a.stringValue }
            if let e = d.elements(forLocalName: "Rating", uri: Self.xmpNS).first { return e.stringValue }
        }
        return nil
    }

    var rating: Int? { RatingValue.parse(ratingText) }

    /// 设置星级（原始值，可以是 0）；nil = 删掉这一项
    func setRating(_ value: Int?) {
        var found = false
        for d in descriptions {
            if let a = d.attribute(forLocalName: "Rating", uri: Self.xmpNS), let name = a.name {
                if let value { a.stringValue = String(value) } else { d.removeAttribute(forName: name) }
                found = true
            }
            for e in d.elements(forLocalName: "Rating", uri: Self.xmpNS) {
                if let value { e.stringValue = String(value) } else { e.detach() }
                found = true
            }
        }
        guard !found, let value else { return }
        let target = descriptions.first ?? makeDescription()
        // 找一个指向 xmp 命名空间的前缀；“xmp”被别的命名空间占用时换一个
        var prefix = "xmp"
        var n = 1
        while let bound = target.resolveNamespace(forName: "\(prefix):Rating")?.stringValue, bound != Self.xmpNS {
            prefix = "xmp\(n)"
            n += 1
        }
        if target.resolveNamespace(forName: "\(prefix):Rating")?.stringValue != Self.xmpNS,
           let ns = XMLNode.namespace(withName: prefix, stringValue: Self.xmpNS) as? XMLNode {
            target.addNamespace(ns)
        }
        if let attr = XMLNode.attribute(withName: "\(prefix):Rating", uri: Self.xmpNS, stringValue: String(value)) as? XMLNode {
            target.addAttribute(attr)
        }
    }

    private func makeDescription() -> XMLElement {
        let rdf: XMLElement
        if let existing = root.elements(forLocalName: "RDF", uri: Self.rdfNS).first {
            rdf = existing
        } else if root.localName == "RDF" {
            rdf = root
        } else {
            rdf = XMLElement(name: "rdf:RDF", uri: Self.rdfNS)
            if let ns = XMLNode.namespace(withName: "rdf", stringValue: Self.rdfNS) as? XMLNode { rdf.addNamespace(ns) }
            root.addChild(rdf)
        }
        let d = XMLElement(name: "rdf:Description", uri: Self.rdfNS)
        if let about = XMLNode.attribute(withName: "rdf:about", uri: Self.rdfNS, stringValue: "") as? XMLNode {
            d.addAttribute(about)
        }
        rdf.addChild(d)
        return d
    }

    // MARK: 判断

    /// x:xmptk 以“Yilan”开头：一览新建的
    var isCreatedByYilan: Bool {
        guard root.localName == "xmpmeta" else { return false }
        let tk = root.attribute(forLocalName: "xmptk", uri: Self.metaNS)?.stringValue
            ?? root.attribute(forName: "x:xmptk")?.stringValue
        return tk?.hasPrefix(Self.toolkitPrefix) ?? false
    }

    /// 除了星级还有没有任何别的属性
    var hasPropertiesOtherThanRating: Bool {
        !flattened().filter { !$0.hasPrefix("/\(Self.xmpNS)|Rating") }.isEmpty
    }

    /// 拍平成“命名空间|名字[路径] = 值”的集合，用来比较改写前后有没有丢东西（属性写法和元素写法等价）
    func flattened() -> Set<String> {
        var out = Set<String>()
        func isMarkup(_ a: XMLNode) -> Bool {
            a.uri == Self.rdfNS || a.uri == Self.metaNS || a.name == "xml:lang" || a.name?.hasPrefix("xmlns") == true
        }
        func walk(_ el: XMLElement, _ path: String) {
            for a in el.attributes ?? [] where !isMarkup(a) {
                out.insert("\(path)/\(a.uri ?? "")|\(a.localName ?? "")=\(a.stringValue ?? "")")
            }
            var li = 0
            for k in el.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                let kids = k.children?.compactMap { $0 as? XMLElement } ?? []
                let plain = kids.isEmpty && (k.attributes ?? []).allSatisfy(isMarkup)
                if k.uri == Self.rdfNS {
                    if k.localName == "li" {
                        li += 1
                        let lang = k.attribute(forName: "xml:lang")?.stringValue.map { "@\($0)" } ?? ""
                        let p = path + "[\(li)\(lang)]"
                        if plain { out.insert("\(p)=\(k.stringValue ?? "")") }
                        walk(k, p)
                    } else {
                        walk(k, path)   // Description / Seq / Bag / Alt / RDF
                    }
                } else {
                    let p = path + "/\(k.uri ?? "")|\(k.localName ?? "")"
                    if plain { out.insert("\(p)=\(k.stringValue ?? "")") } else { walk(k, p) }
                }
            }
        }
        walk(root, "")
        return out
    }

    /// 改写前后比较：除星级外，原来有的每一项都还在
    static func keepsEverything(old: XMPPacket, new: XMPPacket) -> Bool {
        let drop: (String) -> Bool = { $0.hasPrefix("/\(xmpNS)|Rating=") }
        return old.flattened().filter { !drop($0) }.isSubset(of: new.flattened())
    }

    // MARK: 输出

    /// 只有 x:xmpmeta（或 rdf:RDF）本身
    func bodyData() -> Data {
        Data(root.xmlString(options: [.nodePreserveAll]).utf8)
    }

    /// 内嵌用的 XMP 包：xpacket 包裹 + 空白填充（方便别的软件原地修改）
    func packetData(padding: Int) -> Data {
        var d = Data("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n".utf8)
        d.append(bodyData())
        if padding > 0 {
            var pad = "\n"
            var remaining = padding
            while remaining > 0 {
                let n = min(99, remaining)
                pad += String(repeating: " ", count: n) + "\n"
                remaining -= n
            }
            d.append(Data(pad.utf8))
        } else {
            d.append(Data("\n".utf8))
        }
        d.append(Data("<?xpacket end=\"w\"?>".utf8))
        return d
    }

    /// 小文件的内容：原来有 xpacket 包裹就保留，没有就只写 x:xmpmeta
    func sidecarData() -> Data {
        if hadPacketWrapper { return packetData(padding: 0) }
        var d = bodyData()
        d.append(Data("\n".utf8))
        return d
    }
}

/// 应用版本号（写进 x:xmptk、更新检查用）
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
