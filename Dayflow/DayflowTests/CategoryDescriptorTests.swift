import XCTest

@testable import Dayflow

/// Pins the engine-owned category descriptor path (CategoryPersistence) after
/// its extraction from CategoryStore: descriptor mapping, defaults, persisted
/// custom categories (via a throwaway UserDefaults suite — never standard),
/// legacy-format decode, the Idle sentinel, and CategoryStore's delegation.
final class CategoryDescriptorTests: XCTestCase {
  private var suite: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "category-descriptor-tests-\(UUID().uuidString)"
    suite = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    suite.removePersistentDomain(forName: suiteName)
    suite = nil
    suiteName = nil
    super.tearDown()
  }

  private func makeCategory(
    name: String,
    details: String = "",
    order: Int,
    isSystem: Bool = false,
    isIdle: Bool = false
  ) -> TimelineCategory {
    TimelineCategory(
      name: name,
      colorHex: "#123456",
      details: details,
      order: order,
      isSystem: isSystem,
      isIdle: isIdle,
      isNew: false,
      createdAt: Date(),
      updatedAt: Date()
    )
  }

  private func persist(_ categories: [TimelineCategory], to defaults: UserDefaults) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try! encoder.encode(categories)
    defaults.set(data, forKey: CategoryPersistence.persistedCategoriesKey)
  }

  func testDescriptorsSortByOrderAndFormatDescriptions() {
    let input = [
      makeCategory(name: "Second", details: "  Second details  ", order: 1),
      makeCategory(name: "First", details: "", order: 0),
      makeCategory(name: "Idle", details: "ignored", order: 2, isSystem: true, isIdle: true),
    ]

    let descriptors = CategoryPersistence.descriptors(from: input)

    XCTAssertEqual(descriptors.map(\.name), ["First", "Second", "Idle"])
    XCTAssertEqual(descriptors[0].description, nil)
    XCTAssertEqual(descriptors[1].description, "Second details")
    // The idle sentinel description is fixed, not the category's details text.
    XCTAssertEqual(
      descriptors[2].description, "Use when the user is idle for more than half of this period.")
    XCTAssertTrue(descriptors[2].isIdle)
    XCTAssertTrue(descriptors[2].isSystem)
    XCTAssertFalse(descriptors[0].isIdle)
  }

  func testDefaultCategoriesProduceExpectedDescriptorShape() {
    let descriptors = CategoryPersistence.descriptors(from: CategoryPersistence.defaultCategories)

    XCTAssertEqual(descriptors.map(\.name), ["Work", "Personal", "Distraction", "Idle"])
    XCTAssertEqual(descriptors.last?.isIdle, true)
    XCTAssertEqual(descriptors.last?.isSystem, true)
    XCTAssertEqual(descriptors.map(\.isIdle).filter { $0 }.count, 1)
  }

  func testPersistedCustomCategoriesLoadThroughDescriptorPath() {
    let custom = [
      makeCategory(name: "Writing", details: "Docs and posts", order: 0),
      makeCategory(name: "Meetings", details: "Calls and syncs", order: 1),
    ]
    persist(custom, to: suite)

    let loaded = CategoryPersistence.loadPersistedCategories(from: suite)
    XCTAssertEqual(loaded.map(\.name), ["Writing", "Meetings", "Idle"])

    let descriptors = CategoryPersistence.descriptors(from: loaded)
    XCTAssertEqual(descriptors.map(\.name), ["Writing", "Meetings", "Idle"])
    XCTAssertEqual(descriptors[0].description, "Docs and posts")
    // ensureIdleCategoryPresent appended the Idle sentinel last.
    XCTAssertEqual(descriptors[2].name, "Idle")
    XCTAssertTrue(descriptors[2].isIdle)
  }

  func testLegacyPersistedFormatStillDecodes() {
    // The pre-migration format: plain JSON array of {id, name, color, details}.
    let legacy = """
      [
        {"id": 1, "name": "Old Work", "color": "#B984FF", "details": "Legacy work"},
        {"id": 2, "name": "Old Play", "color": null, "details": "Legacy play"}
      ]
      """
    suite.set(Data(legacy.utf8), forKey: CategoryPersistence.persistedCategoriesKey)

    let loaded = CategoryPersistence.loadPersistedCategories(from: suite)

    XCTAssertEqual(loaded.map(\.name), ["Old Work", "Old Play", "Idle"])
    XCTAssertEqual(loaded[0].colorHex, "#B984FF")
    XCTAssertEqual(loaded[1].colorHex, "#E5E7EB")
    XCTAssertTrue(loaded[2].isIdle)
  }

  func testEmptyPersistedStorageFallsBackToDefaults() {
    let loaded = CategoryPersistence.loadPersistedCategories(from: suite)
    XCTAssertTrue(loaded.isEmpty)

    let effective = CategoryPersistence.effectiveCategories()
    XCTAssertEqual(effective.map(\.name), CategoryPersistence.defaultCategories.map(\.name))
  }

  func testDescriptorsForLLMAlwaysIncludesIdle() {
    // Read-only against real storage: whichever path (persisted or defaults)
    // applies, an Idle descriptor must always be present.
    let descriptors = CategoryPersistence.descriptorsForLLM()
    XCTAssertTrue(descriptors.contains { $0.isIdle && $0.name == "Idle" })
  }

  func testCategoryStoreDelegatesToCategoryPersistence() {
    // Read-only: both entry points read the same storage. IDs are minted
    // per call when defaults or the synthesized Idle sentinel apply, so the
    // stable, prompt-relevant fields are compared.
    let viaStore = CategoryStore.descriptorsForLLM()
    let viaPersistence = CategoryPersistence.descriptorsForLLM()

    XCTAssertEqual(viaStore.map(\.name), viaPersistence.map(\.name))
    XCTAssertEqual(viaStore.map(\.colorHex), viaPersistence.map(\.colorHex))
    XCTAssertEqual(viaStore.map(\.description), viaPersistence.map(\.description))
    XCTAssertEqual(viaStore.map(\.isSystem), viaPersistence.map(\.isSystem))
    XCTAssertEqual(viaStore.map(\.isIdle), viaPersistence.map(\.isIdle))
  }
}
