// Synthetic, deterministic diagnostic cases for the production segmenter.
// RecordingEvent is a shim to avoid linking GRDB; all classification rules below
// are compiled from the actual product sources by run-classification-audit.sh.
// The printed behavior is an observation, not an assertion of correctness.
import Foundation
struct RecordingEvent { enum EventType: String { case screenText, keystroke, clipboard, appSwitch, audio, windowBody } }
@main struct Audit {
 static func seg(_ m: Int, _ app: String, _ title: String, _ type: RecordingEvent.EventType = .screenText, _ text: String = "") -> EventSegment { EventSegment(timestamp: Date(timeIntervalSince1970: Double(m*60)), app: app, windowTitle: title, eventType: type, text: text) }
 static func stretch(_ a:Int,_ b:Int,_ app:String,_ title:String)->[EventSegment] { (a...b).map {seg($0,app,title)} }
 static func show(_ name:String,_ ss:[EventSegment]) { let bs=BlockSegmenter.blocks(from:ss,resumeGap:600); print(name); for b in bs { print("app=\(b.app) label=\(b.label) key=\(BlockSegmenter.normalizeTaskKey(b,chrome:[])) seconds=\(b.activeDuration) served=\(String(describing:b.servedBy)) clip=\(b.topClipboard ?? "nil")") } }
 static func main() {
 show("project switch under 3m",stretch(0,10,"Code","a.swift — Alpha") + stretch(11,20,"Code","b.swift — Beta"))
 show("unrelated clipboard",stretch(0,10,"Code","a.swift — Alpha") + [seg(11,"Google Chrome","Bank page",.clipboard,"Unrelated banking details")] + stretch(12,20,"Code","a.swift — Alpha"))
 show("browser project",stretch(0,10,"Google Chrome","Googleの検索ページ — Google"))
 show("sandwich 8h hole",stretch(0,10,"Notion","Roadmap Draft") + stretch(14,20,"Google Chrome","Some video - YouTube") + stretch(500,506,"Firefox","Some video - YouTube") + stretch(510,520,"Notion","Roadmap Draft"))
 show("copy without paste",stretch(0,10,"Google Chrome","Some video - YouTube") + [seg(11,"Google Chrome","Some video - YouTube",.clipboard,"Unrelated personal message")] + stretch(15,25,"Notion","Roadmap Draft"))
 }
}
