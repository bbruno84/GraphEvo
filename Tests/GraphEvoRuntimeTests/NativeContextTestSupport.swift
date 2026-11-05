import CoreData

extension NSPersistentContainer {
    func testNativeContext<Value>(_ body: (NSManagedObjectContext) throws -> Value) throws -> Value {
        let context = newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}
