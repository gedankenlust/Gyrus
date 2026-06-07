import XCTest
@testable import Gyrus

/// Pure unit tests for the folder-tree manipulation that powers drag & drop,
/// and the AI-Brain root helper.
final class CollectionTreeTests: XCTestCase {

    private func col(_ id: String, _ children: [Collection] = []) -> Collection {
        Collection(id: id, name: id, children: children)
    }

    func testRemoveNodeFindsNested() {
        var tree = [col("a", [col("b"), col("c")])]
        let removed = CollectionStore.removeNode("b", from: &tree)
        XCTAssertEqual(removed?.id, "b")
        XCTAssertEqual(tree[0].children.map(\.id), ["c"])
    }

    func testInsertBeforeAndAfter() {
        var tree = [col("a"), col("b"), col("c")]
        CollectionStore.insert(col("x"), target: "b", after: false, parentId: nil, in: &tree)
        XCTAssertEqual(tree.map(\.id), ["a", "x", "b", "c"])
        CollectionStore.insert(col("y"), target: "c", after: true, parentId: nil, in: &tree)
        XCTAssertEqual(tree.map(\.id), ["a", "x", "b", "c", "y"])
    }

    func testInsertNodeAtIndexInChild() {
        var tree = [col("p", [col("a"), col("b")])]
        CollectionStore.insertNode(col("x"), intoParent: "p", at: 1, in: &tree)
        XCTAssertEqual(tree[0].children.map(\.id), ["a", "x", "b"])
        CollectionStore.insertNode(col("z"), intoParent: "p", at: -1, in: &tree)  // -1 = append
        XCTAssertEqual(tree[0].children.map(\.id), ["a", "x", "b", "z"])
    }

    func testChildIds() {
        let tree = [col("a"), col("p", [col("x"), col("y")])]
        XCTAssertEqual(CollectionStore.childIds(of: nil, in: tree), ["a", "p"])
        XCTAssertEqual(CollectionStore.childIds(of: "p", in: tree), ["x", "y"])
    }

    func testBrainRootWrapsInSubfolder() {
        let docs = URL(fileURLWithPath: "/Users/x/Documents")
        XCTAssertEqual(AppSettings.brainRoot(forChosenDirectory: docs), "/Users/x/Documents/Gyrus Brain")
        // Idempotent: don't double-nest if it's already a Gyrus Brain folder.
        let already = URL(fileURLWithPath: "/Users/x/Gyrus Brain")
        XCTAssertEqual(AppSettings.brainRoot(forChosenDirectory: already), "/Users/x/Gyrus Brain")
    }
}
