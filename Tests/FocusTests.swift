import Foundation
struct FocusCase: Decodable { let current: FocusRecord; let candidates: [FocusRecord]; let direction: FocusDirection; let expected: UInt32? }
@main enum FocusTests {
 static func main() throws {
    let cases = try JSONDecoder().decode([FocusCase].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    var assertions = 0
    func check(_ condition: Bool,_ label: String) { precondition(condition,label); assertions += 1 }
    for c in cases { check(DirectionalFocus.nearest(c.current,c.candidates,c.direction)?.id == c.expected,"Lua directional selection parity") }
    let source = FocusRecord(id:1,display:1,frame:Frame(x:100,y:100,w:100,h:100))
    let nearby = FocusRecord(id:2,display:2,frame:Frame(x:210,y:100,w:100,h:100))
    let same = FocusRecord(id:3,display:1,frame:Frame(x:400,y:100,w:100,h:100))
    check(DirectionalFocus.nearest(source,[nearby,same],.right)?.id == 3,"Same-display preference")
    check(DirectionalFocus.nearest(source,[nearby],.right)?.id == 2,"Other visible display fallback")
    let diagonal = FocusRecord(id:4,display:1,frame:Frame(x:210,y:0,w:100,h:100))
    check(DirectionalFocus.nearest(source,[diagonal],.right) == nil,"Touching perpendicular edge is not overlap")
    check(DirectionalFocus.nearest(source,[source],.right) == nil,"Exclude source identity")
    check(DirectionalFocus.nearest(source,[same,FocusRecord(id:5,display:1,frame:same.frame)],.right)?.id == 3,"Exact ties retain order")
    print("native directional focus: \(assertions) assertions passed, including \(cases.count) Lua comparisons")
 }
}
