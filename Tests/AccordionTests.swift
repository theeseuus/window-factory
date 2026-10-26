import Foundation
@main enum AccordionTests {
    struct Example: Decodable { let screen: Frame; let anchor: Frame; let expected: [Frame] }
    static func main() throws {
        var assertions = 0
        func check(_ value: Bool,_ message: String) { precondition(value,message); assertions += 1 }
        let cases = try JSONDecoder().decode([Example].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        for example in cases {
            let anchor = AccordionRecord(id:1,frame:example.anchor)
            let others = [AccordionRecord(id:2,frame:Frame(x:200,y:90,w:10,h:10)),AccordionRecord(id:3,frame:Frame(x:100,y:40,w:20,h:20)),AccordionRecord(id:4,frame:Frame(x:100,y:90,w:30,h:30))]
            let plan = AccordionGeometry.plan(anchor:anchor,others:others+[anchor],screen:example.screen)
            check(plan.map(\.id) == [3,4,2],"stable top-to-bottom, left-to-right order; exclude anchor")
            for (index,record) in others.enumerated() {
                check(plan.first{$0.id == record.id}!.frame == example.expected[index],"matches original Lua accordion clamp/offset/size")
            }
            check(AccordionGeometry.raiseOrder(anchor:1,fan:plan) == [2,4,3,1],"raise back-to-front, ending with anchor")
            check(anchor.frame == example.anchor,"anchor remains unchanged")
            check(AccordionGeometry.plan(anchor:anchor,others:[],screen:example.screen).isEmpty,"single window makes no placement")
        }
        let f = Frame(x:20,y:30,w:200,h:100),screen = Frame(x:0,y:0,w:1000,h:800)
        let tied = AccordionGeometry.plan(anchor:AccordionRecord(id:1,frame:f),others:[AccordionRecord(id:8,frame:f),AccordionRecord(id:2,frame:f)],screen:screen)
        check(tied.map(\.id) == [2,8],"exact position ties use identity for repeatability")
        check(tied[0].frame == Frame(x:48,y:52,w:200,h:100),"first step is 28 by 22")
        check(AccordionGeometry.raiseOrder(anchor:1,fan:[]).isEmpty,"single window does not need stacking")
        check(AccordionGeometry.raiseOrder(anchor:1,fan:tied) == [8,2,1],"identity ties retain matching visual stacking")
        print("native accordion: \(assertions) assertions passed, including \(cases.count*3) comparisons against original Lua callback")
    }
}
