import Foundation

// A small standalone assertion runner for hosts with Command Line Tools but no XCTest.
// XCTest remains the authoritative CI harness; this runs the same test method bodies locally.
open class XCTestCase {
    public required init() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
}
private var failures = 0
private var cases = 0
private struct UnwrapError: Error {}
private func fail(_ message:String,file:StaticString,line:UInt) {
    failures += 1
    fputs("\(file):\(line): assertion failed: \(message)\n",stderr)
}
public func XCTAssertTrue(_ value:@autoclosure()throws->Bool,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line) {
    do { if try !value() { fail("Expected true. "+message(),file:file,line:line) } }
    catch { fail("Expression threw: \(error)",file:file,line:line) }
}
public func XCTAssertFalse(_ value:@autoclosure()throws->Bool,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line) {
    do { if try value() { fail("Expected false. "+message(),file:file,line:line) } }
    catch { fail("Expression threw: \(error)",file:file,line:line) }
}
public func XCTAssertNil<T>(_ value:@autoclosure()throws->T?,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line) {
    do { if try value() != nil { fail("Expected nil. "+message(),file:file,line:line) } }
    catch { fail("Expression threw: \(error)",file:file,line:line) }
}
public func XCTAssertEqual<T:Equatable>(_ a:@autoclosure()throws->T,_ b:@autoclosure()throws->T,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line) {
    do {
        let x=try a(), y=try b()
        if x != y { fail("\(x) != \(y). "+message(),file:file,line:line) }
    } catch { fail("Expression threw: \(error)",file:file,line:line) }
}
public func XCTAssertEqual(_ a:@autoclosure()throws->Double,_ b:@autoclosure()throws->Double,accuracy:Double,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line) {
    do {
        let x=try a(), y=try b()
        if !x.isFinite || !y.isFinite || abs(x-y)>accuracy { fail("\(x) != \(y) ± \(accuracy). "+message(),file:file,line:line) }
    } catch { fail("Expression threw: \(error)",file:file,line:line) }
}
public func XCTAssertGreaterThan<T:Comparable>(_ a:@autoclosure()->T,_ b:@autoclosure()->T,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line) {
    if !(a()>b()) { fail("Expected greater than. "+message(),file:file,line:line) }
}
public func XCTAssertThrowsError<T>(_ expression:@autoclosure()throws->T,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line,_ handler:((Error)->Void)? = nil) {
    do { _=try expression(); fail("Expected thrown error. "+message(),file:file,line:line) }
    catch { handler?(error) }
}
public func XCTUnwrap<T>(_ value:@autoclosure()throws->T?,_ message:@autoclosure()->String="",file:StaticString=#filePath,line:UInt=#line) throws -> T {
    guard let result=try value() else { fail("Expected non-nil. "+message(),file:file,line:line); throw UnwrapError() }
    return result
}
public func runCase<T:XCTestCase>(_ name:String,_ type:T.Type,_ body:(T)throws->Void) {
    cases += 1
    let before=failures, instance=T()
    do { try instance.setUpWithError(); try body(instance) }
    catch { fail("Uncaught error: \(error)",file:#filePath,line:#line) }
    do { try instance.tearDownWithError() }
    catch { fail("Teardown error: \(error)",file:#filePath,line:#line) }
    print("\(failures == before ? "PASS" : "FAIL") \(name)")
}
public func finishTests() -> Int32 {
    print("Standalone core checks: \(cases) test methods, \(failures) failed assertions")
    return failures == 0 ? 0 : 1
}
